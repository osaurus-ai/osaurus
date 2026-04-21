//
//  MemorySearchService.swift
//  osaurus
//
//  Hybrid search (BM25 + vector) over pinned facts, episodes, and the
//  transcript. Falls back to SQLite text matching when VecturaKit is
//  unavailable.
//
//  v2 simplifications:
//    - No eager startup scan of every chunk/summary key. Reverse lookup
//      maps are built lazily on first cache miss.
//    - Pinned-fact UUIDs are persisted as their primary key (already a
//      UUID string), so the entry-search path needs no map at all.
//    - Episode and transcript IDs are integers; we map by deterministic
//      UUID derived from a stable composite key.
//    - MMR uses cheap content-hash dedup at the candidate stage instead
//      of O(K²) Jaccard over long strings.
//

import Foundation
import VecturaKit
import os

public actor MemorySearchService {
    public static let shared = MemorySearchService()

    private static let defaultSearchThreshold: Float = 0.10
    private static let defaultTranscriptThreshold: Float = 0.01
    private static let defaultMMRLambda: Double = 0.85
    private static let defaultFetchMultiplier: Double = 2.0

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    /// Reverse map from VecturaKit UUID → episode primary key. Populated
    /// lazily on indexing or on first map miss.
    private var episodeKeyMap: [String: Int] = [:]
    /// Reverse map from VecturaKit UUID → transcript composite key
    /// (conversationId, chunkIndex). Built lazily.
    private var transcriptKeyMap: [String: (conversationId: String, chunkIndex: Int)] = [:]

    private init() {}

    // MARK: - Initialization

    /// Initialize the VecturaKit index. Called once at app startup.
    /// Non-fatal — search falls back to text if this fails.
    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.memory().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try VecturaConfig(
                    name: "osaurus-memory",
                    directoryURL: storageDir,
                    dimension: EmbeddingService.embeddingDimension,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.3,
                        hybridWeight: 0.5,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                MemoryLogger.search.info("VecturaKit initialized")
                break
            } catch {
                if attempt == 1 {
                    MemoryLogger.search.warning("VecturaKit init failed, deleting storage to recover: \(error)")
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    MemoryLogger.search.error("VecturaKit init failed (text fallback active): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    public var isVecturaAvailable: Bool { vectorDB != nil }

    // MARK: - Indexing

    public func indexPinnedFact(_ fact: PinnedFact) async {
        guard let db = vectorDB else { return }
        guard let id = UUID(uuidString: fact.id) else { return }
        do {
            _ = try await db.addDocument(text: fact.content, id: id)
        } catch {
            MemoryLogger.search.error("indexPinnedFact failed for \(fact.id): \(error)")
        }
    }

    public func indexEpisode(_ episode: Episode) async {
        guard let db = vectorDB else { return }
        let id = TextSimilarity.deterministicUUID(from: "episode:\(episode.id)")
        do {
            let text = episode.summary + " — " + episode.topicsCSV
            _ = try await db.addDocument(text: text, id: id)
            episodeKeyMap[id.uuidString] = episode.id
        } catch {
            MemoryLogger.search.error("indexEpisode failed for #\(episode.id): \(error)")
        }
    }

    public func indexTranscriptTurn(_ turn: TranscriptTurn) async {
        guard let db = vectorDB else { return }
        let id = TextSimilarity.deterministicUUID(from: "transcript:\(turn.conversationId):\(turn.chunkIndex)")
        do {
            _ = try await db.addDocument(text: turn.content, id: id)
            transcriptKeyMap[id.uuidString] = (turn.conversationId, turn.chunkIndex)
        } catch {
            MemoryLogger.search.error("indexTranscriptTurn failed: \(error)")
        }
    }

    public func removeDocument(id: String) async {
        guard let db = vectorDB, let uuid = UUID(uuidString: id) else { return }
        do { try await db.deleteDocuments(ids: [uuid]) } catch {
            MemoryLogger.search.error("removeDocument failed: \(error)")
        }
    }

    // MARK: - Search

    public func searchPinnedFacts(
        query: String,
        agentId: String? = nil,
        topK: Int = 10
    ) async -> [PinnedFact] {
        guard topK > 0 else { return [] }
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * Self.defaultFetchMultiplier)
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultSearchThreshold
                )
                let scoreMap = Dictionary(
                    results.map { ($0.id.uuidString, Double($0.score)) },
                    uniquingKeysWith: { first, _ in first }
                )
                let ids = results.map { $0.id.uuidString }
                let facts = try MemoryDatabase.shared.loadPinnedFactsByIds(ids).filter { fact in
                    agentId == nil || fact.agentId == agentId
                }
                let scored = facts.compactMap { fact -> (item: PinnedFact, score: Double, content: String)? in
                    guard let s = scoreMap[fact.id] else { return nil }
                    return (fact, s, fact.content)
                }
                return mmrRerank(results: scored, lambda: Self.defaultMMRLambda, topK: topK)
            } catch {
                MemoryLogger.search.error("vector search (pinned) failed: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchPinnedFactsText(query: query, agentId: agentId, limit: topK)
        } catch {
            MemoryLogger.search.error("text fallback (pinned) failed: \(error)")
            return []
        }
    }

    public func searchEpisodes(
        query: String,
        agentId: String? = nil,
        topK: Int = 10
    ) async -> [Episode] {
        guard topK > 0 else { return [] }
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * Self.defaultFetchMultiplier)
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultSearchThreshold
                )

                var matchedIds: [Int] = []
                var scores: [Int: Double] = [:]
                for r in results {
                    if let epId = episodeKeyMap[r.id.uuidString] {
                        matchedIds.append(epId)
                        scores[epId] = Double(r.score)
                    }
                }

                // Lazy fill: if our reverse map didn't know about a returned
                // UUID, rebuild from current episodes. Cheap because episodes
                // are small in number relative to transcript turns.
                if matchedIds.count < results.count {
                    rebuildEpisodeKeyMapIfNeeded()
                    matchedIds.removeAll()
                    scores.removeAll()
                    for r in results {
                        if let epId = episodeKeyMap[r.id.uuidString] {
                            matchedIds.append(epId)
                            scores[epId] = Double(r.score)
                        }
                    }
                }

                if !matchedIds.isEmpty {
                    let episodes = try MemoryDatabase.shared.loadEpisodesByIds(matchedIds).filter {
                        agentId == nil || $0.agentId == agentId
                    }
                    let scored = episodes.compactMap { ep -> (item: Episode, score: Double, content: String)? in
                        guard let s = scores[ep.id] else { return nil }
                        return (ep, s, ep.summary)
                    }
                    return mmrRerank(results: scored, lambda: Self.defaultMMRLambda, topK: topK)
                }
            } catch {
                MemoryLogger.search.error("vector search (episodes) failed: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchEpisodesText(query: query, agentId: agentId, limit: topK)
        } catch {
            MemoryLogger.search.error("text fallback (episodes) failed: \(error)")
            return []
        }
    }

    public func searchTranscript(
        query: String,
        agentId: String? = nil,
        days: Int = 365,
        topK: Int = 10
    ) async -> [TranscriptTurn] {
        guard topK > 0 else { return [] }
        if let db = vectorDB {
            do {
                let fetchCount = Int(Double(topK) * Self.defaultFetchMultiplier)
                let results = try await db.search(
                    query: .text(query),
                    numResults: fetchCount,
                    threshold: Self.defaultTranscriptThreshold
                )

                var hits: [(conversationId: String, chunkIndex: Int, score: Double)] = []
                for r in results {
                    if let key = transcriptKeyMap[r.id.uuidString] {
                        hits.append((key.conversationId, key.chunkIndex, Double(r.score)))
                    }
                }
                if hits.count < results.count {
                    rebuildTranscriptKeyMapIfNeeded(days: days)
                    hits.removeAll()
                    for r in results {
                        if let key = transcriptKeyMap[r.id.uuidString] {
                            hits.append((key.conversationId, key.chunkIndex, Double(r.score)))
                        }
                    }
                }

                if !hits.isEmpty {
                    // Single composite-key load instead of N per-conversation scans.
                    let keys = hits.map { (conversationId: $0.conversationId, chunkIndex: $0.chunkIndex) }
                    var scoreLookup: [String: Double] = [:]
                    for hit in hits {
                        scoreLookup["\(hit.conversationId):\(hit.chunkIndex)"] = hit.score
                    }
                    let turns = (try? MemoryDatabase.shared.loadTranscriptByCompositeKeys(keys)) ?? []
                    let ranked = turns.compactMap { turn -> (item: TranscriptTurn, score: Double, content: String)? in
                        guard agentId == nil || turn.agentId == agentId else { return nil }
                        guard let score = scoreLookup["\(turn.conversationId):\(turn.chunkIndex)"] else {
                            return nil
                        }
                        return (turn, score, turn.content)
                    }
                    if !ranked.isEmpty {
                        return mmrRerank(results: ranked, lambda: Self.defaultMMRLambda, topK: topK)
                    }
                }
            } catch {
                MemoryLogger.search.error("vector search (transcript) failed: \(error)")
            }
        }

        do {
            return try MemoryDatabase.shared.searchTranscriptText(
                query: query,
                agentId: agentId,
                days: days,
                limit: topK
            )
        } catch {
            MemoryLogger.search.error("text fallback (transcript) failed: \(error)")
            return []
        }
    }

    // MARK: - Lazy reverse-map building

    private func rebuildEpisodeKeyMapIfNeeded() {
        do {
            let keys = try MemoryDatabase.shared.loadAllEpisodeKeys()
            for key in keys {
                let uuid = TextSimilarity.deterministicUUID(from: "episode:\(key.id)")
                episodeKeyMap[uuid.uuidString] = key.id
            }
        } catch {
            MemoryLogger.search.warning("rebuild episode key map failed: \(error)")
        }
    }

    private func rebuildTranscriptKeyMapIfNeeded(days: Int) {
        do {
            let keys = try MemoryDatabase.shared.loadAllTranscriptKeys(days: days)
            for key in keys {
                let uuid = TextSimilarity.deterministicUUID(from: "transcript:\(key.conversationId):\(key.chunkIndex)")
                transcriptKeyMap[uuid.uuidString] = (key.conversationId, key.chunkIndex)
            }
        } catch {
            MemoryLogger.search.warning("rebuild transcript key map failed: \(error)")
        }
    }

    // MARK: - Index management

    public func clearIndex() async {
        episodeKeyMap.removeAll()
        transcriptKeyMap.removeAll()
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            MemoryLogger.search.info("VecturaKit index cleared")
        } catch {
            MemoryLogger.search.error("Failed to clear VecturaKit index: \(error)")
        }
    }

    /// Stream-rebuild the entire index in batches of 200 to avoid OOM on
    /// large databases.
    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        episodeKeyMap.removeAll()
        transcriptKeyMap.removeAll()

        do {
            try await db.reset()

            let pinned = (try? MemoryDatabase.shared.loadPinnedFacts(limit: 5000)) ?? []
            for fact in pinned {
                if let id = UUID(uuidString: fact.id) {
                    _ = try? await db.addDocument(text: fact.content, id: id)
                }
            }

            let episodes = (try? MemoryDatabase.shared.loadEpisodes(limit: 5000)) ?? []
            for ep in episodes {
                let id = TextSimilarity.deterministicUUID(from: "episode:\(ep.id)")
                _ = try? await db.addDocument(text: ep.summary + " — " + ep.topicsCSV, id: id)
                episodeKeyMap[id.uuidString] = ep.id
            }

            let transcripts = (try? MemoryDatabase.shared.loadTranscript(days: 365, limit: 5000)) ?? []
            for turn in transcripts {
                let id = TextSimilarity.deterministicUUID(from: "transcript:\(turn.conversationId):\(turn.chunkIndex)")
                _ = try? await db.addDocument(text: turn.content, id: id)
                transcriptKeyMap[id.uuidString] = (turn.conversationId, turn.chunkIndex)
            }

            MemoryLogger.search.info(
                "Index rebuilt: \(pinned.count) pinned, \(episodes.count) episodes, \(transcripts.count) transcript turns"
            )
        } catch {
            MemoryLogger.search.error("rebuildIndex failed: \(error)")
        }
    }

    // MARK: - MMR Reranking

    /// MMR with cheap content-hash dedup. Avoids the O(K²) Jaccard over long
    /// strings that the v1 path used.
    nonisolated func mmrRerank<T>(
        results: [(item: T, score: Double, content: String)],
        lambda: Double,
        topK: Int
    ) -> [T] {
        guard !results.isEmpty else { return [] }

        // Score-normalize for MMR.
        guard let maxScore = results.map(\.score).max(),
            let minScore = results.map(\.score).min()
        else { return results.map(\.item) }
        let range = maxScore - minScore
        let normalized = results.map { r in
            (item: r.item, score: range > 0 ? (r.score - minScore) / range : 1.0, content: r.content)
        }

        // Pre-shingle each result for cheap Jaccard-ish overlap.
        let shingled = normalized.map {
            (item: $0.item, score: $0.score, shingles: TextSimilarity.shingleSet($0.content))
        }

        var selected: [(item: T, score: Double, shingles: Set<String>)] = []
        var remaining = shingled
        let k = min(topK, shingled.count)

        for _ in 0 ..< k {
            var bestIdx = 0
            var bestMMR = -Double.infinity

            for (i, candidate) in remaining.enumerated() {
                let maxSim: Double
                if selected.isEmpty {
                    maxSim = 0
                } else {
                    maxSim =
                        selected.map { TextSimilarity.jaccardTokenized(candidate.shingles, $0.shingles) }.max() ?? 0
                }
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
}
