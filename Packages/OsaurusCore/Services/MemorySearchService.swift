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

    private var vectorDB: VecturaKit?
    private var isInitialized = false

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
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? 2.0))
                let results = try await db.search(query: .text(query), numResults: fetchCount, threshold: 0.3)

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

                return mmrRerank(results: scored, lambda: lambda ?? 0.7, topK: topK)
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
            let results = try await db.search(query: .text(query), numResults: topK, threshold: 0.3)

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
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? 2.0))
                let results = try await db.search(query: .text(query), numResults: fetchCount, threshold: 0.3)

                let scoreMap = Dictionary(
                    results.map { ($0.id, (score: Double($0.score), text: $0.text)) },
                    uniquingKeysWith: { first, _ in first }
                )

                let allChunks = try MemoryDatabase.shared.loadAllChunks(agentId: agentId, days: days)
                let scored: [(item: ConversationChunk, score: Double, content: String)] = allChunks.compactMap {
                    chunk in
                    let chunkUUID = deterministicUUID(from: "chunk:\(chunk.conversationId):\(chunk.chunkIndex)")
                    guard let match = scoreMap[chunkUUID] else { return nil }
                    return (item: chunk, score: match.score, content: chunk.content)
                }

                if !scored.isEmpty {
                    return mmrRerank(results: scored, lambda: lambda ?? 0.7, topK: topK)
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
                let fetchCount = Int(Double(topK) * (fetchMultiplier ?? 2.0))
                let results = try await db.search(query: .text(query), numResults: fetchCount, threshold: 0.3)

                let scoreMap = Dictionary(
                    results.map { ($0.id, (score: Double($0.score), text: $0.text)) },
                    uniquingKeysWith: { first, _ in first }
                )

                let allSummaries = try MemoryDatabase.shared.loadAllSummaries(days: days)
                let scored: [(item: ConversationSummary, score: Double, content: String)] = allSummaries.compactMap {
                    summary in
                    let summaryUUID = deterministicUUID(
                        from: "summary:\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)"
                    )
                    guard let match = scoreMap[summaryUUID],
                        agentId == nil || summary.agentId == agentId
                    else { return nil }
                    return (item: summary, score: match.score, content: summary.summary)
                }

                if !scored.isEmpty {
                    return mmrRerank(results: scored, lambda: lambda ?? 0.7, topK: topK)
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

    /// Rebuild the entire VecturaKit index from SQLite data.
    public func rebuildIndex() async {
        guard let db = vectorDB else { return }

        do {
            try await db.reset()

            let entries = try MemoryDatabase.shared.loadAllActiveEntries()
            let texts = entries.map { "[\($0.type.rawValue)] \($0.content)" }
            let ids = entries.compactMap { UUID(uuidString: $0.id) }
            if texts.count == ids.count && !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }

            MemoryLogger.search.info("Index rebuilt with \(entries.count) entries")
        } catch {
            MemoryLogger.search.error("Index rebuild failed: \(error)")
        }
    }

    public var isVecturaAvailable: Bool {
        vectorDB != nil
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
