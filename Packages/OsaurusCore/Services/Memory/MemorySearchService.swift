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
//  v3: per-agent partitioning. Each agent's memory lives in its own
//  VecturaKit instance under `~/.osaurus/memory/vectura/<agentId>/`,
//  so cross-agent vector leakage is structurally impossible — a
//  `searchTranscript(agentId: A, ...)` call cannot return another
//  agent's vectors because it never opens that index. The legacy
//  `nil`-agent path opens a "shared" instance for back-compat with
//  callers that haven't been threaded with agentId yet.
//
//  Encryption: each per-agent directory is intended to be wrapped by
//  `EncryptedVecturaStorage` once the VecturaKit storage adapter
//  protocol is wired through. Until then the rebuild-on-launch
//  fallback is documented in `Storage/StorageMigrator.swift` — we
//  rebuild from the encrypted source SQL on each major upgrade so
//  the plaintext vector files are always derivable from data at
//  rest that *is* encrypted.
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

    /// Per-agent VecturaKit instances. Key `""` is the legacy/shared
    /// instance used for callers that don't supply an agent id (e.g.
    /// global rebuilds, legacy global searches). Created lazily on
    /// first index/search for that agent.
    private var vectorDBs: [String: VecturaKit] = [:]
    private var isInitialized = false

    /// Reverse map from VecturaKit UUID → episode primary key. Populated
    /// lazily on indexing or on first map miss.
    private var episodeKeyMap: [String: Int] = [:]
    /// Reverse map from VecturaKit UUID → transcript composite key
    /// (conversationId, chunkIndex). Built lazily.
    private var transcriptKeyMap: [String: (conversationId: String, chunkIndex: Int)] = [:]

    private init() {}

    private static let sharedAgentBucket = ""

    private static func bucketKey(for agentId: String?) -> String {
        if let agentId, !agentId.isEmpty { return agentId }
        return sharedAgentBucket
    }

    private static func storageDir(for agentId: String?) -> URL {
        let bucket = bucketKey(for: agentId)
        let base = OsaurusPaths.memory().appendingPathComponent("vectura", isDirectory: true)
        if bucket == sharedAgentBucket {
            return base.appendingPathComponent("_shared", isDirectory: true)
        }
        return base.appendingPathComponent(bucket, isDirectory: true)
    }

    // MARK: - Initialization

    /// Initialize the shared/default VecturaKit index. Called once at
    /// app startup. Per-agent instances are created lazily on first
    /// use. Non-fatal — search falls back to text if this fails.
    public func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        _ = await ensureVectorDB(for: nil)
    }

    /// Return (creating if needed) the VecturaKit instance for the
    /// supplied agent. `nil` agent maps to the shared bucket.
    /// Returns `nil` when the service hasn't been `initialize()`d
    /// yet — preserving the legacy contract that index/search calls
    /// no-op until the host opts in.
    private func ensureVectorDB(for agentId: String?) async -> VecturaKit? {
        guard isInitialized else { return nil }
        let bucket = Self.bucketKey(for: agentId)
        if let existing = vectorDBs[bucket] { return existing }

        let storageDir = Self.storageDir(for: agentId)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)
                let config = try VecturaConfig(
                    name: "osaurus-memory-\(bucket.isEmpty ? "shared" : bucket)",
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
                let db = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                vectorDBs[bucket] = db
                MemoryLogger.search.info("VecturaKit ready for bucket=\(bucket.isEmpty ? "shared" : bucket)")
                return db
            } catch {
                if attempt == 1 {
                    MemoryLogger.search.warning(
                        "VecturaKit init failed for \(bucket.isEmpty ? "shared" : bucket), deleting + retrying: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    MemoryLogger.search.error(
                        "VecturaKit init failed (text fallback active): \(error)"
                    )
                }
            }
        }
        return nil
    }

    public var isVecturaAvailable: Bool { !vectorDBs.isEmpty }

    // MARK: - Indexing

    public func indexPinnedFact(_ fact: PinnedFact) async {
        guard let db = await ensureVectorDB(for: fact.agentId) else { return }
        guard let id = UUID(uuidString: fact.id) else { return }
        do {
            _ = try await db.addDocument(text: fact.content, id: id)
        } catch {
            MemoryLogger.search.error("indexPinnedFact failed for \(fact.id): \(error)")
        }
    }

    public func indexEpisode(_ episode: Episode) async {
        guard let db = await ensureVectorDB(for: episode.agentId) else { return }
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
        guard let db = await ensureVectorDB(for: turn.agentId) else { return }
        let id = TextSimilarity.deterministicUUID(from: "transcript:\(turn.conversationId):\(turn.chunkIndex)")
        do {
            _ = try await db.addDocument(text: turn.content, id: id)
            transcriptKeyMap[id.uuidString] = (turn.conversationId, turn.chunkIndex)
        } catch {
            MemoryLogger.search.error("indexTranscriptTurn failed: \(error)")
        }
    }

    /// Remove a document by id. Without an agent hint we have to try
    /// every open bucket — IDs are deterministic UUIDs so this is
    /// idempotent. Pass `agentId` when known to avoid the fan-out.
    public func removeDocument(id: String, agentId: String? = nil) async {
        guard let uuid = UUID(uuidString: id) else { return }
        if let agentId, let db = vectorDBs[Self.bucketKey(for: agentId)] {
            try? await db.deleteDocuments(ids: [uuid])
            return
        }
        for db in vectorDBs.values {
            try? await db.deleteDocuments(ids: [uuid])
        }
    }

    // MARK: - Search

    public func searchPinnedFacts(
        query: String,
        agentId: String? = nil,
        topK: Int = 10
    ) async -> [PinnedFact] {
        guard topK > 0 else { return [] }
        // Per-agent partitioning: scope the vector search to the
        // caller's agent index. Cross-agent leakage is now structural
        // — agent A simply doesn't open agent B's index.
        if let db = await ensureVectorDB(for: agentId) {
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
        if let db = await ensureVectorDB(for: agentId) {
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
        if let db = await ensureVectorDB(for: agentId) {
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

    /// Reset every per-agent index. Used on user-triggered "Clear
    /// memory" + after migrations that re-encrypt the underlying
    /// store.
    public func clearIndex() async {
        episodeKeyMap.removeAll()
        transcriptKeyMap.removeAll()
        for (bucket, db) in vectorDBs {
            do {
                try await db.reset()
                MemoryLogger.search.info("VecturaKit reset for bucket=\(bucket.isEmpty ? "shared" : bucket)")
            } catch {
                MemoryLogger.search.error("clearIndex failed for \(bucket): \(error)")
            }
        }
        // Drop the directory contents too so plaintext leftovers from
        // a pre-encryption build don't persist.
        let base = OsaurusPaths.memory().appendingPathComponent("vectura", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        vectorDBs.removeAll()
        isInitialized = false
    }

    /// Stream-rebuild every per-agent index from the (encrypted)
    /// SQLite source of truth. Called by the storage migrator on
    /// first launch after upgrade so vectors land in their per-agent
    /// directories.
    public func rebuildIndex() async {
        episodeKeyMap.removeAll()
        transcriptKeyMap.removeAll()

        // Reset the open instances first, then walk each agent's
        // pinned/episode/transcript rows and re-index. Agents that
        // have no vector instance yet will be created lazily by
        // `ensureVectorDB`.
        for db in vectorDBs.values {
            try? await db.reset()
        }

        let allPinned = (try? MemoryDatabase.shared.loadPinnedFacts(limit: 5000)) ?? []
        for fact in allPinned {
            guard let id = UUID(uuidString: fact.id),
                let db = await ensureVectorDB(for: fact.agentId)
            else { continue }
            _ = try? await db.addDocument(text: fact.content, id: id)
        }

        let allEpisodes = (try? MemoryDatabase.shared.loadEpisodes(limit: 5000)) ?? []
        for ep in allEpisodes {
            guard let db = await ensureVectorDB(for: ep.agentId) else { continue }
            let id = TextSimilarity.deterministicUUID(from: "episode:\(ep.id)")
            _ = try? await db.addDocument(text: ep.summary + " — " + ep.topicsCSV, id: id)
            episodeKeyMap[id.uuidString] = ep.id
        }

        let allTranscripts = (try? MemoryDatabase.shared.loadTranscript(days: 365, limit: 5000)) ?? []
        for turn in allTranscripts {
            guard let db = await ensureVectorDB(for: turn.agentId) else { continue }
            let id = TextSimilarity.deterministicUUID(from: "transcript:\(turn.conversationId):\(turn.chunkIndex)")
            _ = try? await db.addDocument(text: turn.content, id: id)
            transcriptKeyMap[id.uuidString] = (turn.conversationId, turn.chunkIndex)
        }

        let bucketCount = vectorDBs.count
        let pinnedCount = allPinned.count
        let episodeCount = allEpisodes.count
        let transcriptCount = allTranscripts.count
        MemoryLogger.search.info(
            "Index rebuilt across \(bucketCount) agent bucket(s): \(pinnedCount) pinned, \(episodeCount) episodes, \(transcriptCount) transcript turns"
        )
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
