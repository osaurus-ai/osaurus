//
//  MemorySearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search (BM25 + vector) over the memory database.
//  Falls back to SQLite LIKE-based search when VecturaKit is unavailable.
//  The VecturaKit index is derived from SQLite data and can be rebuilt at any time.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public actor MemorySearchService {
    public static let shared = MemorySearchService()

    private static let defaultSearchThreshold: Float = 0.10
    private static let defaultChunkSearchThreshold: Float = 0.05
    private static let dedupSearchThreshold: Float = 0.30
    private static let defaultMMRLambda: Double = 0.85
    private static let defaultFetchMultiplier: Double = 3.0

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private var chunkKeyMap: [String: (conversationId: String, chunkIndex: Int)] = [:]
    private var summaryKeyMap: [String: (agentId: String, conversationId: String, conversationAt: String)] = [:]

    private init() {}

    // MARK: - Initialization

    /// Initialize the VecturaKit index. Called once at app startup.
    /// Non-fatal — search falls back to text if this fails.
    public func initialize() async {
        guard !isInitialized else { return }

        do {
            let storageDir = OsaurusPaths.memory().appendingPathComponent("vectura", isDirectory: true)
            OsaurusPaths.ensureExistsSilent(storageDir)

            let config = try VecturaConfig(
                name: "osaurus-memory",
                directoryURL: storageDir,
                searchOptions: VecturaConfig.SearchOptions(
                    defaultNumResults: 10,
                    minThreshold: 0.3,
                    hybridWeight: 0.5,
                    k1: 1.2,
                    b: 0.75
                )
            )

            let embedder = SwiftEmbedder(modelSource: .default)
            vectorDB = try await VecturaKit(config: config, embedder: embedder)
            isInitialized = true
            MemoryLogger.search.info("VecturaKit initialized successfully")
        } catch {
            MemoryLogger.search.error("VecturaKit initialization failed (text search fallback active): \(error)")
            vectorDB = nil
        }

        buildReverseMaps()
    }

    /// Build reverse lookup maps from SQLite data so VecturaKit UUIDs can be
    /// mapped back to chunk/summary composite keys without loading full rows.
    private func buildReverseMaps() {
        do {
            let chunkKeys = try MemoryDatabase.shared.loadAllChunkKeys()
            for key in chunkKeys {
                let uuid = deterministicUUID(from: "chunk:\(key.conversationId):\(key.chunkIndex)")
                chunkKeyMap[uuid.uuidString] = (key.conversationId, key.chunkIndex)
            }

            let summaryKeys = try MemoryDatabase.shared.loadAllSummaryKeys()
            for key in summaryKeys {
                let uuid = deterministicUUID(
                    from: "summary:\(key.agentId):\(key.conversationId):\(key.conversationAt)"
                )
                summaryKeyMap[uuid.uuidString] = (key.agentId, key.conversationId, key.conversationAt)
            }

            MemoryLogger.search.info(
                "Reverse maps built: \(self.chunkKeyMap.count) chunks, \(self.summaryKeyMap.count) summaries"
            )
        } catch {
            MemoryLogger.search.warning("Failed to build reverse maps: \(error)")
        }
    }

    // MARK: - Indexing

    /// Index a memory entry for hybrid search.
    public func indexMemoryEntry(_ entry: MemoryEntry) async {
        guard let db = vectorDB else { return }
        do {
            let id = UUID(uuidString: entry.id) ?? UUID()
            _ = try await db.addDocument(text: "[\(entry.type.rawValue)] \(entry.content)", id: id)
        } catch {
            MemoryLogger.search.error("Failed to index entry \(entry.id): \(error)")
        }
    }

    /// Index a conversation chunk for hybrid search.
    public func indexConversationChunk(_ chunk: ConversationChunk) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(from: "chunk:\(chunk.conversationId):\(chunk.chunkIndex)")
            _ = try await db.addDocument(text: chunk.content, id: id)
            chunkKeyMap[id.uuidString] = (chunk.conversationId, chunk.chunkIndex)
        } catch {
            MemoryLogger.search.error("Failed to index chunk: \(error)")
        }
    }

    /// Index a conversation summary for hybrid search.
    public func indexSummary(_ summary: ConversationSummary) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(
                from: "summary:\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)"
            )
            _ = try await db.addDocument(text: summary.summary, id: id)
            summaryKeyMap[id.uuidString] = (summary.agentId, summary.conversationId, summary.conversationAt)
        } catch {
            MemoryLogger.search.error("Failed to index summary: \(error)")
        }
    }

    /// Remove a document from the index.
    public func removeDocument(id: String) async {
        guard let db = vectorDB, let uuid = UUID(uuidString: id) else { return }
        do {
            try await db.deleteDocuments(ids: [uuid])
        } catch {
            MemoryLogger.search.error("Failed to remove document \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    /// Search memory entries using hybrid search (vector + BM25) with MMR reranking.
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchMemoryEntries(
        query: String,
        agentId: String? = nil,
        topK: Int = 10,
        lambda: Double? = nil,
        fetchMultiplier: Double? = nil
    ) async -> [MemoryEntry] {
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? Self.defaultFetchMultiplier))
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultSearchThreshold
                )

                let scoreMap = Dictionary(
                    results.map { ($0.id.uuidString, (score: Double($0.score), text: $0.text)) },
                    uniquingKeysWith: { first, _ in first }
                )

                let idStrings = results.map { $0.id.uuidString }
                let entries = try MemoryDatabase.shared.loadEntriesByIds(idStrings, agentId: agentId)
                let scored: [(item: MemoryEntry, score: Double, content: String)] = entries.compactMap { entry in
                    guard let match = scoreMap[entry.id] else { return nil }
                    return (item: entry, score: match.score, content: entry.content)
                }

                return mmrRerank(results: scored, lambda: lambda ?? Self.defaultMMRLambda, topK: topK)
            } catch {
                MemoryLogger.search.error("Vector search failed, falling back to text: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchMemoryEntries(query: query, agentId: agentId)
        } catch {
            MemoryLogger.search.error("Text fallback search failed: \(error)")
            return []
        }
    }

    /// Search memory entries returning raw similarity scores (no MMR reranking).
    /// Used by the verification pipeline for Layer 3 semantic deduplication.
    public func searchMemoryEntriesWithScores(
        query: String,
        agentId: String? = nil,
        topK: Int = 1
    ) async -> [(entry: MemoryEntry, score: Double)] {
        guard let db = vectorDB else { return [] }
        do {
            let results = try await db.search(
                query: .text(query),
                numResults: topK,
                threshold: Self.dedupSearchThreshold
            )

            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Double($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let idStrings = results.map { $0.id.uuidString }
            let entries = try MemoryDatabase.shared.loadEntriesByIds(idStrings, agentId: agentId)

            return entries.compactMap { entry in
                guard let score = scoreMap[entry.id] else { return nil }
                return (entry: entry, score: score)
            }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
        } catch {
            MemoryLogger.search.error("Vector search (with scores) failed: \(error)")
            return []
        }
    }

    /// Search conversation chunks using hybrid search (vector + BM25) with MMR reranking.
    /// Uses reverse-map lookups for targeted DB queries instead of loading all rows.
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchConversations(
        query: String,
        agentId: String? = nil,
        days: Int = 30,
        topK: Int = 10,
        lambda: Double? = nil,
        fetchMultiplier: Double? = nil
    ) async -> [ConversationChunk] {
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? Self.defaultFetchMultiplier))
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultChunkSearchThreshold
                )

                var scoreByKey: [String: Double] = [:]
                var keys: [(conversationId: String, chunkIndex: Int)] = []
                for result in results {
                    guard let key = chunkKeyMap[result.id.uuidString] else { continue }
                    let compositeKey = "\(key.conversationId):\(key.chunkIndex)"
                    scoreByKey[compositeKey] = Double(result.score)
                    keys.append(key)
                }

                if !keys.isEmpty {
                    let chunks = try MemoryDatabase.shared.loadChunksByKeys(keys)
                    let scored: [(item: ConversationChunk, score: Double, content: String)] = chunks.compactMap {
                        chunk in
                        let compositeKey = "\(chunk.conversationId):\(chunk.chunkIndex)"
                        guard let score = scoreByKey[compositeKey],
                            agentId == nil || chunk.agentId == agentId
                        else { return nil }
                        return (item: chunk, score: score, content: chunk.content)
                    }

                    if !scored.isEmpty {
                        return mmrRerank(results: scored, lambda: lambda ?? Self.defaultMMRLambda, topK: topK)
                    }
                }
            } catch {
                MemoryLogger.search.error("Vector search for chunks failed, falling back to text: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchChunks(query: query, agentId: agentId, days: days)
        } catch {
            MemoryLogger.search.error("Text fallback chunk search failed: \(error)")
            return []
        }
    }

    /// Search conversation summaries using hybrid search (vector + BM25) with MMR reranking.
    /// Uses reverse-map lookups for targeted DB queries instead of loading all rows.
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchSummaries(
        query: String,
        agentId: String? = nil,
        days: Int = 30,
        topK: Int = 10,
        lambda: Double? = nil,
        fetchMultiplier: Double? = nil
    ) async -> [ConversationSummary] {
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? Self.defaultFetchMultiplier))
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultSearchThreshold
                )

                var scoreByKey: [String: Double] = [:]
                var compositeKeys: [(agentId: String, conversationId: String, conversationAt: String)] = []
                for result in results {
                    guard let key = summaryKeyMap[result.id.uuidString] else { continue }
                    let compositeKey = "\(key.agentId):\(key.conversationId):\(key.conversationAt)"
                    scoreByKey[compositeKey] = Double(result.score)
                    compositeKeys.append(key)
                }

                if !compositeKeys.isEmpty {
                    let summaries = try MemoryDatabase.shared.loadSummariesByCompositeKeys(
                        compositeKeys,
                        filterAgentId: agentId
                    )
                    let scored: [(item: ConversationSummary, score: Double, content: String)] =
                        summaries.compactMap { summary in
                            let compositeKey = "\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)"
                            guard let score = scoreByKey[compositeKey] else { return nil }
                            return (item: summary, score: score, content: summary.summary)
                        }

                    if !scored.isEmpty {
                        return mmrRerank(results: scored, lambda: lambda ?? Self.defaultMMRLambda, topK: topK)
                    }
                }
            } catch {
                MemoryLogger.search.error("Vector search for summaries failed, falling back to text: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchSummaries(query: query, agentId: agentId, days: days)
        } catch {
            MemoryLogger.search.error("Text fallback summary search failed: \(error)")
            return []
        }
    }

    // MARK: - Graph Search

    /// Search the knowledge graph by entity name or relation type.
    /// Pure SQL — no VecturaKit needed for graph traversal.
    public func searchGraph(
        entityName: String? = nil,
        relation: String? = nil,
        depth: Int = 2
    ) async -> [GraphResult] {
        guard MemoryDatabase.shared.isOpen else { return [] }
        if let entityName {
            do {
                return try MemoryDatabase.shared.queryEntityGraph(
                    name: entityName,
                    depth: min(depth, 4)
                )
            } catch {
                MemoryLogger.search.error("Graph entity search failed: \(error)")
                return []
            }
        } else if let relation {
            do {
                return try MemoryDatabase.shared.queryRelationships(relation: relation)
            } catch {
                MemoryLogger.search.error("Graph relationship search failed: \(error)")
                return []
            }
        }
        return []
    }

    // MARK: - Index Management

    /// Rebuild the entire VecturaKit index from SQLite data (entries, summaries, and chunks).
    public func rebuildIndex() async {
        guard let db = vectorDB else { return }

        chunkKeyMap.removeAll()
        summaryKeyMap.removeAll()

        do {
            try await db.reset()

            let entries = try MemoryDatabase.shared.loadAllActiveEntries()
            let entryTexts = entries.map { "[\($0.type.rawValue)] \($0.content)" }
            let entryIds = entries.compactMap { UUID(uuidString: $0.id) }
            if entryTexts.count == entryIds.count && !entryTexts.isEmpty {
                _ = try await db.addDocuments(texts: entryTexts, ids: entryIds)
            }

            let summaries = try MemoryDatabase.shared.loadAllSummaries()
            for summary in summaries {
                let id = deterministicUUID(
                    from: "summary:\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)"
                )
                _ = try await db.addDocument(text: summary.summary, id: id)
                summaryKeyMap[id.uuidString] = (summary.agentId, summary.conversationId, summary.conversationAt)
            }

            let chunks = try MemoryDatabase.shared.loadAllChunks()
            for chunk in chunks {
                let id = deterministicUUID(from: "chunk:\(chunk.conversationId):\(chunk.chunkIndex)")
                _ = try await db.addDocument(text: chunk.content, id: id)
                chunkKeyMap[id.uuidString] = (chunk.conversationId, chunk.chunkIndex)
            }

            MemoryLogger.search.info(
                "Index rebuilt with \(entries.count) entries, \(summaries.count) summaries, \(chunks.count) chunks"
            )
        } catch {
            MemoryLogger.search.error("Index rebuild failed: \(error)")
        }
    }

    public var isVecturaAvailable: Bool {
        vectorDB != nil
    }

    /// Clear the entire VecturaKit index and reverse maps without rebuilding.
    public func clearIndex() async {
        chunkKeyMap.removeAll()
        summaryKeyMap.removeAll()
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            MemoryLogger.search.info("VecturaKit index cleared")
        } catch {
            MemoryLogger.search.error("Failed to clear VecturaKit index: \(error)")
        }
    }

    // MARK: - MMR Reranking

    /// Reranks results using Maximal Marginal Relevance.
    /// Balances relevance (from search score) with diversity (penalizes redundancy).
    private nonisolated func mmrRerank<T>(
        results: [(item: T, score: Double, content: String)],
        lambda: Double,
        topK: Int
    ) -> [T] {
        guard !results.isEmpty else { return [] }

        let maxScore = results.map(\.score).max()!
        let minScore = results.map(\.score).min()!
        let scoreRange = maxScore - minScore
        let normalized = results.map { r in
            (item: r.item, score: scoreRange > 0 ? (r.score - minScore) / scoreRange : 1.0, content: r.content)
        }

        var selected: [(item: T, score: Double, content: String)] = []
        var remaining = normalized

        for _ in 0 ..< min(topK, normalized.count) {
            var bestIdx = 0
            var bestMMR = -Double.infinity

            for (i, candidate) in remaining.enumerated() {
                let maxSim =
                    selected.isEmpty
                    ? 0.0
                    : selected.map { TextSimilarity.jaccard(candidate.content, $0.content) }.max()!

                let mmrScore = lambda * candidate.score - (1.0 - lambda) * maxSim

                if mmrScore > bestMMR {
                    bestMMR = mmrScore
                    bestIdx = i
                }
            }

            selected.append(remaining[bestIdx])
            remaining.remove(at: bestIdx)
        }

        return selected.map(\.item)
    }

    // MARK: - Helpers

    /// Generate a deterministic UUID from a string using SHA-256.
    private func deterministicUUID(from string: String) -> UUID {
        let hash = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
