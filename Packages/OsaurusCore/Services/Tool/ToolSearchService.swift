//
//  ToolSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search over the unified tool index.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public enum ToolIndexLogger {
    static let search = Logger(subsystem: "ai.osaurus", category: "toolindex.search")
    static let service = Logger(subsystem: "ai.osaurus", category: "toolindex.service")
}

public struct ToolSearchResult: Sendable {
    public let entry: ToolIndexEntry
    public let searchScore: Float

    public init(entry: ToolIndexEntry, searchScore: Float) {
        self.entry = entry
        self.searchScore = searchScore
    }
}

/// Diagnostic snapshot of one hybrid search invocation. Carries enough
/// per-hit information to drive both the env-flag log block and the
/// offline `CapabilitySearchEvaluator` forensics:
///   - `bm25Rank` / `bm25Score`: nil when BM25 returned no hit for this
///     name (or when the FTS5 sanitiser rejected the query — see
///     `bm25Available`).
///   - `embedRank` / `embedScore`: nil when the embedding side returned
///     no hit for this name.
///   - `fusedScore`: the sum of the two RRF terms with k=60. Items present
///     on only one side contribute zero from the missing side.
public struct ToolSearchHybridDiagnostic: Sendable {
    public struct Hit: Sendable {
        public let name: String
        public let bm25Rank: Int?
        public let bm25Score: Float?
        public let embedRank: Int?
        public let embedScore: Float?
        public let fusedScore: Float

        public init(
            name: String,
            bm25Rank: Int?,
            bm25Score: Float?,
            embedRank: Int?,
            embedScore: Float?,
            fusedScore: Float
        ) {
            self.name = name
            self.bm25Rank = bm25Rank
            self.bm25Score = bm25Score
            self.embedRank = embedRank
            self.embedScore = embedScore
            self.fusedScore = fusedScore
        }
    }

    public let indexedToolCount: Int
    /// `false` when the FTS5 sanitiser produced no usable tokens for
    /// this query (e.g. all-punctuation). Fused scores in that case
    /// come entirely from the embed side; `bm25Rank` / `bm25Score`
    /// are `nil` on every hit. The `hybridDegradesToEmbeddingWhenBM25Empty`
    /// test asserts both this flag and result-set equality with
    /// embed-only `search()` — so callers can detect "BM25 deliberately
    /// stayed silent" vs "BM25 happened to converge".
    public let bm25Available: Bool
    /// Pre-threshold candidate set: every name returned by either
    /// source. Sorted by `fusedScore` descending.
    public let allHits: [Hit]
    /// `allHits` filtered to `fusedScore >= minFusedScore`, capped at
    /// `topK`. `minFusedScore` is the effective cutoff after any
    /// single-source fallback; `requestedMinFusedScore` preserves the
    /// caller's configured cutoff for diagnostics.
    public let acceptedHits: [Hit]
    public let requestedMinFusedScore: Float
    public let minFusedScore: Float
    /// Names that passed score/enabled checks but were suppressed by
    /// the active agent's enabled-tool allowlist. This separates "not
    /// indexed" from "not granted" during #823/#789-style triage.
    public let filteredByAllowlist: [String]

    public init(
        indexedToolCount: Int,
        bm25Available: Bool,
        allHits: [Hit],
        acceptedHits: [Hit],
        minFusedScore: Float,
        requestedMinFusedScore: Float? = nil,
        filteredByAllowlist: [String] = []
    ) {
        self.indexedToolCount = indexedToolCount
        self.bm25Available = bm25Available
        self.allHits = allHits
        self.acceptedHits = acceptedHits
        self.requestedMinFusedScore = requestedMinFusedScore ?? minFusedScore
        self.minFusedScore = minFusedScore
        self.filteredByAllowlist = filteredByAllowlist
    }
}

/// Diagnostic snapshot of one `searchWithDiagnostic` invocation. Used by the
/// `OSAURUS_DEBUG_CAPABILITY_SEARCH=1` log path in `CapabilitySearch.search`
/// and by `CapabilitySearchEvaluator` to surface raw vs threshold-accepted
/// hits in the same call. Production search (`search(...)`) does NOT
/// populate this — keeps the hot path single-call.
public struct ToolSearchDiagnostic: Sendable {
    public struct Hit: Sendable {
        public let name: String
        public let score: Float
        public init(name: String, score: Float) {
            self.name = name
            self.score = score
        }
    }

    public let indexedToolCount: Int
    public let rawHits: [Hit]
    public let acceptedHits: [Hit]
    public let threshold: Float

    public init(indexedToolCount: Int, rawHits: [Hit], acceptedHits: [Hit], threshold: Float) {
        self.indexedToolCount = indexedToolCount
        self.rawHits = rawHits
        self.acceptedHits = acceptedHits
        self.threshold = threshold
    }
}

public actor ToolSearchService {
    public static let shared = ToolSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false
    private var reverseIdMap: [String: String] = [:]

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.toolIndex().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                // Pure embedding only — BM25 now lives in `tool_index_fts`
                // and `searchHybrid` fuses the two via RRF. Letting
                // VecturaKit also mix BM25 in (as the previous
                // `hybridWeight: 0.5` did) double-counted the lexical
                // signal once we added the FTS5 layer, and made the
                // per-component scores in forensics dishonest. The
                // BM25 hyperparameters (`k1`, `b`) are unused at
                // `hybridWeight: 1.0` but kept inline so the next
                // contributor sees what the legacy hybrid was tuned to.
                let config = try VecturaConfig(
                    name: "osaurus-tools",
                    directoryURL: storageDir,
                    dimension: EmbeddingService.embeddingDimension,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.0,
                        hybridWeight: 1.0,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                rehydrateReverseIdMap()
                ToolIndexLogger.search.info("VecturaKit initialized successfully for tools")
                break
            } catch {
                if attempt == 1 {
                    ToolIndexLogger.search.warning(
                        "VecturaKit init failed for tools, deleting storage to recover: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    ToolIndexLogger.search.error("VecturaKit init failed for tools (search unavailable): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    /// Populate `reverseIdMap` from the SQL source of truth. Without
    /// this, a fresh launch opens the persistent VecturaKit dir but
    /// the in-memory `UUID → toolId` map is empty until the next
    /// `rebuildIndex()` runs. Search calls in that window get hits
    /// from VecturaKit, fail to map them back to tool IDs, and
    /// return `[]` — which then leaves `capabilities_discover` unable
    /// to surface installed tools until the index repopulates.
    ///
    /// Cheap: just iterates `ToolDatabase.loadAllEntries()` and
    /// derives the deterministic UUID for each entry. No network,
    /// no embeds, no VecturaKit calls.
    private func rehydrateReverseIdMap() {
        guard let entries = try? ToolDatabase.shared.loadAllEntries() else { return }
        for entry in entries {
            _ = deterministicUUID(for: entry.id)
        }
        ToolIndexLogger.search.info("Tool reverse-id map rehydrated with \(entries.count) entries")
    }

    // MARK: - Indexing

    public func indexEntry(_ entry: ToolIndexEntry, parameters: JSONValue? = nil) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: entry.id)
            let text = buildIndexText(name: entry.name, description: entry.description, parameters: parameters)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            ToolIndexLogger.search.error("Failed to index tool \(entry.id): \(error)")
        }
    }

    public func removeEntry(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            ToolIndexLogger.search.error("Failed to remove tool \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [ToolSearchResult] {
        guard topK > 0 else { return [] }
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Float($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let toolIds = results.compactMap { reverseIdMap[$0.id.uuidString] }
            guard !toolIds.isEmpty else { return [] }

            let enabledNames = await MainActor.run {
                Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
            }

            let toolIdSet = Set(toolIds)
            let entries = try ToolDatabase.shared.loadAllEntries()
                .filter { toolIdSet.contains($0.id) && enabledNames.contains($0.name) }
            let entryById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            return Array(
                toolIds.compactMap { toolId -> ToolSearchResult? in
                    guard let entry = entryById[toolId] else { return nil }
                    let uuid = deterministicUUID(for: toolId)
                    guard let score = scoreMap[uuid.uuidString] else { return nil }
                    return ToolSearchResult(entry: entry, searchScore: score)
                }
                .sorted { $0.searchScore > $1.searchScore }
                .prefix(topK)
            )
        } catch {
            ToolIndexLogger.search.error("Tool search failed: \(error)")
            return []
        }
    }

    /// Diagnostic-capturing search. Runs the underlying query twice — once
    /// at threshold 0.0 to capture every candidate the embedder produced
    /// (the "raw" set), and once at the requested threshold (the "accepted"
    /// set). Doubles the embed cost on purpose; only invoked from the
    /// env-flag-gated trace path and from the offline eval harness. The
    /// production `search(...)` is byte-for-byte unchanged.
    public func searchWithDiagnostic(
        query: String,
        topK: Int,
        threshold: Float
    ) async -> (results: [ToolSearchResult], diagnostic: ToolSearchDiagnostic) {
        let indexedCount = (try? ToolDatabase.shared.entryCount()) ?? 0
        let raw = await search(query: query, topK: topK, threshold: 0.0)
        let accepted = await search(query: query, topK: topK, threshold: threshold)
        let diagnostic = ToolSearchDiagnostic(
            indexedToolCount: indexedCount,
            rawHits: raw.map { ToolSearchDiagnostic.Hit(name: $0.entry.name, score: $0.searchScore) },
            acceptedHits: accepted.map { ToolSearchDiagnostic.Hit(name: $0.entry.name, score: $0.searchScore) },
            threshold: threshold
        )
        return (accepted, diagnostic)
    }

    // MARK: - Hybrid search (BM25 + embedding via RRF)

    /// Runtime k for Reciprocal Rank Fusion. 60 is the canonical value
    /// from the original RRF paper (Cormack, Clarke, Buettcher 2009)
    /// — large enough that the top 1-2 hits don't completely
    /// dominate, small enough that mid-rank items still matter. We
    /// don't expose this; if a future caller needs to tune it, push
    /// it through the call sites rather than parametrising the actor.
    private static let rrfK: Float = 60

    /// Hybrid search: BM25 (via `ToolDatabase.searchBM25` / FTS5)
    /// fused with pure embedding (via the existing `search(...)`)
    /// using Reciprocal Rank Fusion. Items in only one source still
    /// score (the missing source contributes 0). Filters to
    /// `fusedScore >= minFusedScore` and truncates to `topK`.
    ///
    /// Used by the runtime `CapabilitySearch.search` tools-lane.
    public func searchHybrid(
        query: String,
        topK: Int = 10,
        minFusedScore: Float = 0.01,
        minEmbedCosine: Float = 0,
        allowedNames: Set<String>? = nil
    ) async -> [ToolSearchResult] {
        let (results, _) = await searchHybridWithDiagnostic(
            query: query,
            topK: topK,
            minFusedScore: minFusedScore,
            minEmbedCosine: minEmbedCosine,
            allowedNames: allowedNames
        )
        return results
    }

    /// Diagnostic-capturing variant. Returns the same `[ToolSearchResult]`
    /// the runtime would receive plus a `ToolSearchHybridDiagnostic`
    /// carrying per-component rank/score for every candidate (`allHits`)
    /// and the threshold-accepted subset (`acceptedHits`).
    ///
    /// Implementation note: BM25 runs synchronously inline (sub-ms on
    /// realistic indices, see `ToolDatabase.searchBM25`); the slow path
    /// is the embedding call. No `Task.detached` — adding a thread hop
    /// for a sub-ms SQLite read would buy nothing and obscure the
    /// sync-vs-async boundary. We don't `async let` the embed call
    /// either: BM25 has already returned, so the embed runs sequentially
    /// and only the slow side actually awaits.
    public func searchHybridWithDiagnostic(
        query: String,
        topK: Int,
        minFusedScore: Float,
        minEmbedCosine: Float = 0,
        allowedNames: Set<String>? = nil
    ) async -> (results: [ToolSearchResult], diagnostic: ToolSearchHybridDiagnostic) {
        guard topK > 0 else {
            let diagnostic = ToolSearchHybridDiagnostic(
                indexedToolCount: (try? ToolDatabase.shared.entryCount()) ?? 0,
                bm25Available: ToolDatabase.sanitizeFTS5Query(query) != nil,
                allHits: [],
                acceptedHits: [],
                minFusedScore: minFusedScore
            )
            return ([], diagnostic)
        }

        if !ToolDatabase.shared.isOpen {
            return await searchRegistryFallbackWithDiagnostic(
                query: query,
                topK: topK,
                minFusedScore: minFusedScore,
                allowedNames: allowedNames,
                reason: "tool database closed"
            )
        }

        let indexedCount = (try? ToolDatabase.shared.entryCount()) ?? 0
        let bm25Available = ToolDatabase.sanitizeFTS5Query(query) != nil

        let bm25 = (try? ToolDatabase.shared.searchBM25(query: query, topK: topK * 2)) ?? []
        let embed = await search(query: query, topK: topK * 2, threshold: 0.0)

        // Per-name rank + score lookups, keyed on tool name (the unit
        // the eval / forensics layers compare on). `tool_index.id` ==
        // `tool.name` everywhere in the registry today, so the BM25
        // result's `id` IS the name; the embed result carries
        // `entry.name` which is the same string.
        let bm25RankByName = Dictionary(
            uniqueKeysWithValues: bm25.enumerated().map { ($1.id, $0 + 1) }
        )
        let bm25ScoreByName = Dictionary(uniqueKeysWithValues: bm25.map { ($0.id, $0.score) })
        let embedRankByName = Dictionary(
            uniqueKeysWithValues: embed.enumerated().map { ($1.entry.name, $0 + 1) }
        )
        let embedScoreByName = Dictionary(
            uniqueKeysWithValues: embed.map { ($0.entry.name, $0.searchScore) }
        )

        let allNames = Set(bm25.map(\.id)).union(embed.map(\.entry.name))
        let k = Self.rrfK

        // Compute fused score per name. Items missing from one source
        // contribute zero from that side — RRF treats absence as
        // "infinite rank", which equals zero contribution.
        //
        // Score-aware embed gate: when `minEmbedCosine > 0`, an embedding
        // candidate whose raw cosine is below that quality floor
        // contributes ZERO to fusion (as if it weren't an embed hit at
        // all). Pure rank-based RRF saturates near `2/(k+1)`, so without
        // this an abstain-noise tool that merely RANKS in the embed top-K
        // (regardless of how low its cosine is) fuses its way past the
        // cutoff; gating by cosine quality lets abstain queries reach zero
        // accepted while real recall (cosine ≥ floor) keeps its normal RRF
        // contribution. `minEmbedCosine == 0` disables the gate so legacy
        // callers are byte-for-byte unchanged.
        let fused: [(name: String, score: Float)] =
            allNames
            .map { name -> (String, Float) in
                let s1 = bm25RankByName[name].map { 1.0 / (k + Float($0)) } ?? 0
                let embedQualifies =
                    minEmbedCosine <= 0 || (embedScoreByName[name] ?? 0) >= minEmbedCosine
                let s2 =
                    embedQualifies
                    ? (embedRankByName[name].map { 1.0 / (k + Float($0)) } ?? 0)
                    : 0
                return (name, s1 + s2)
            }
            .sorted { $0.score > $1.score }

        // Map names back to live `ToolIndexEntry` rows + apply the
        // enabled-name filter (mirrors `search(...)` lines 153–159).
        let enabledNames = await MainActor.run {
            Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
        }
        let entriesByName: [String: ToolIndexEntry]
        do {
            let all = try ToolDatabase.shared.loadAllEntries()
            entriesByName = Dictionary(
                all.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            ToolIndexLogger.search.error("Hybrid search failed loading entries: \(error)")
            entriesByName = [:]
        }

        // Single Hit factory shared by `allHits` (every candidate,
        // forensics-facing) and `acceptedHits` (filtered subset,
        // runtime-facing). Keeps the per-name field lookups in one
        // place — easy to extend (e.g., add a `tokenCount` column)
        // without drift between the two views.
        func makeHit(name: String, score: Float) -> ToolSearchHybridDiagnostic.Hit {
            ToolSearchHybridDiagnostic.Hit(
                name: name,
                bm25Rank: bm25RankByName[name],
                bm25Score: bm25ScoreByName[name],
                embedRank: embedRankByName[name],
                embedScore: embedScoreByName[name],
                fusedScore: score
            )
        }

        // `allHits`: every candidate sorted by fusedScore desc, before
        // the threshold and topK cuts — forensics needs to see what
        // the embedder + BM25 surfaced even when nothing was accepted.
        let allHits = fused.map { makeHit(name: $0.name, score: $0.score) }

        let effectiveMinFusedScore = Self.effectiveMinFusedScore(
            requested: minFusedScore,
            topK: topK,
            bm25Available: bm25Available,
            bm25HitCount: bm25.count,
            embedHitCount: embed.count
        )

        // `acceptedHits`: enabled + above the effective fused cutoff + capped at
        // topK. Eager loop so the slice → [Hit] type stays simple
        // (lazy `prefix` over a compactMap chain confused the type
        // checker on first attempt).
        var acceptedResults: [ToolSearchResult] = []
        var acceptedHits: [ToolSearchHybridDiagnostic.Hit] = []
        var filteredByAllowlist: [String] = []
        for (name, score) in fused {
            if acceptedResults.count >= topK { break }
            guard score >= effectiveMinFusedScore else { continue }
            guard let entry = entriesByName[name], enabledNames.contains(name) else { continue }
            if let allowedNames, !allowedNames.contains(name) {
                filteredByAllowlist.append(name)
                continue
            }
            acceptedResults.append(ToolSearchResult(entry: entry, searchScore: score))
            acceptedHits.append(makeHit(name: name, score: score))
        }

        let diagnostic = ToolSearchHybridDiagnostic(
            indexedToolCount: indexedCount,
            bm25Available: bm25Available,
            allHits: allHits,
            acceptedHits: acceptedHits,
            minFusedScore: effectiveMinFusedScore,
            requestedMinFusedScore: minFusedScore,
            filteredByAllowlist: filteredByAllowlist
        )
        return (acceptedResults, diagnostic)
    }

    /// Registry fallback for local chat when encrypted tool storage is closed
    /// by design. Built-in capability discovery must not require a storage-key
    /// unlock or trigger Keychain UI; the live registry already has the usable
    /// tool catalog in memory.
    private func searchRegistryFallbackWithDiagnostic(
        query: String,
        topK: Int,
        minFusedScore: Float,
        allowedNames: Set<String>?,
        reason: String
    ) async -> (results: [ToolSearchResult], diagnostic: ToolSearchHybridDiagnostic) {
        let indexedCount = (try? ToolDatabase.shared.entryCount()) ?? 0
        let bm25Available = ToolDatabase.sanitizeFTS5Query(query) != nil
        let entries = await registryEntries()

        let scored: [(entry: ToolIndexEntry, score: Float)] =
            entries
            .compactMap { entry in
                let score = Self.registryLexicalScore(
                    query: query,
                    name: entry.name,
                    description: entry.description,
                    toolsJSON: entry.toolsJSON
                )
                guard score > 0 else { return nil }
                return (entry, score)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
                }
                return $0.score > $1.score
            }

        let allHits = scored.map {
            ToolSearchHybridDiagnostic.Hit(
                name: $0.entry.name,
                bm25Rank: nil,
                bm25Score: nil,
                embedRank: nil,
                embedScore: nil,
                fusedScore: $0.score
            )
        }

        var acceptedResults: [ToolSearchResult] = []
        var acceptedHits: [ToolSearchHybridDiagnostic.Hit] = []
        var filteredByAllowlist: [String] = []

        for item in scored {
            if acceptedResults.count >= topK { break }
            guard item.score >= minFusedScore else { continue }
            if let allowedNames, !allowedNames.contains(item.entry.name) {
                filteredByAllowlist.append(item.entry.name)
                continue
            }
            let hit = ToolSearchHybridDiagnostic.Hit(
                name: item.entry.name,
                bm25Rank: nil,
                bm25Score: nil,
                embedRank: nil,
                embedScore: nil,
                fusedScore: item.score
            )
            acceptedResults.append(ToolSearchResult(entry: item.entry, searchScore: item.score))
            acceptedHits.append(hit)
        }

        ToolIndexLogger.search.notice(
            "Hybrid search using registry fallback: \(reason, privacy: .public); results=\(acceptedResults.count, privacy: .public)"
        )

        let diagnostic = ToolSearchHybridDiagnostic(
            indexedToolCount: indexedCount,
            bm25Available: bm25Available,
            allHits: allHits,
            acceptedHits: acceptedHits,
            minFusedScore: minFusedScore,
            filteredByAllowlist: filteredByAllowlist
        )
        return (acceptedResults, diagnostic)
    }

    private func registryEntries() async -> [ToolIndexEntry] {
        await MainActor.run {
            let excluded = ToolRegistry.capabilityToolNames
                .union(ToolRegistry.shared.runtimeManagedToolNames)
            return ToolRegistry.shared.listTools()
                .filter { $0.enabled && !excluded.contains($0.name) }
                .map { tool -> ToolIndexEntry in
                    let runtime: ToolRuntime
                    if ToolRegistry.shared.isSandboxTool(tool.name) {
                        runtime = .sandbox
                    } else if ToolRegistry.shared.isMCPTool(tool.name) {
                        runtime = .mcp
                    } else if ToolRegistry.shared.builtInToolNames.contains(tool.name) {
                        runtime = .builtin
                    } else {
                        runtime = .native
                    }
                    return ToolIndexEntry(
                        id: tool.name,
                        name: tool.name,
                        description: tool.description,
                        runtime: runtime,
                        toolsJSON: Self.registryParameterText(tool.parameters),
                        source: .system,
                        tokenCount: tool.estimatedTokens
                    )
                }
        }
    }

    private static func registryLexicalScore(
        query: String,
        name: String,
        description: String,
        toolsJSON: String
    ) -> Float {
        let tokens = lexicalTokens(query)
        guard !tokens.isEmpty else { return 0 }

        let nameLower = name.lowercased()
        let descriptionLower = description.lowercased()
        let paramsLower = toolsJSON.lowercased()
        let combined = "\(nameLower) \(descriptionLower) \(paramsLower)"

        var score: Float = 0
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !queryLower.isEmpty, combined.contains(queryLower) {
            score += 0.08
        }

        for token in tokens {
            if nameLower == token { score += 0.08 }
            if nameLower.contains(token) { score += 0.04 }
            if descriptionLower.contains(token) { score += 0.03 }
            if paramsLower.contains(token) { score += 0.02 }
        }
        return score
    }

    private static func lexicalTokens(_ text: String) -> [String] {
        let raw =
            text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
        var seen = Set<String>()
        return raw.filter { token in
            token.count >= 2 && seen.insert(token).inserted
        }
    }

    private static func registryParameterText(_ parameters: JSONValue?) -> String {
        guard case .object(let schema) = parameters,
            case .object(let properties) = schema["properties"]
        else { return "" }

        var parts: [String] = []
        for (key, value) in properties {
            parts.append(key)
            if case .object(let propSchema) = value,
                case .string(let desc) = propSchema["description"]
            {
                parts.append(desc)
            }
        }
        return parts.joined(separator: " ")
    }

    /// The production `CapabilitySearch` cutoff was tuned for fused
    /// BM25+embedding scores. When the embedding side is silent or the
    /// FTS5 sanitiser rejects the query, a rank-1 hit from the surviving
    /// source only scores `1 / (60 + 1)`, which sits below that fused cutoff.
    /// Lower the cutoff just enough to keep the requested top-K from that
    /// source instead of reporting "no tools found" while one source is
    /// unavailable. A normal lexical miss (`bm25Available == true` with
    /// zero BM25 hits) keeps the requested cutoff, so semantic-only noise
    /// does not get re-admitted just because BM25 found nothing.
    private static func effectiveMinFusedScore(
        requested: Float,
        topK: Int,
        bm25Available: Bool,
        bm25HitCount: Int,
        embedHitCount: Int
    ) -> Float {
        guard requested > 0 else { return requested }
        let bm25Only = bm25HitCount > 0 && embedHitCount == 0
        let embedOnlyBecauseBM25Unavailable = !bm25Available && bm25HitCount == 0 && embedHitCount > 0
        guard bm25Only || embedOnlyBecauseBM25Unavailable else { return requested }
        let cappedRank = max(1, topK)
        let singleSourceTopKFloor = 1.0 / (rrfK + Float(cappedRank))
        return min(requested, singleSourceTopKFloor)
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let toolParams: [String: JSONValue] = await MainActor.run {
                var result = [String: JSONValue]()
                for tool in ToolRegistry.shared.listTools() {
                    if let params = tool.parameters { result[tool.name] = params }
                }
                return result
            }

            let entries = try ToolDatabase.shared.loadAllEntries()
            var texts: [String] = []
            var ids: [UUID] = []
            texts.reserveCapacity(entries.count)
            ids.reserveCapacity(entries.count)
            for entry in entries {
                let id = deterministicUUID(for: entry.id)
                texts.append(
                    buildIndexText(
                        name: entry.name,
                        description: entry.description,
                        parameters: toolParams[entry.name]
                    )
                )
                ids.append(id)
            }
            if !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }
            ToolIndexLogger.search.info("Tool index rebuilt with \(entries.count) entries")
        } catch {
            ToolIndexLogger.search.error("Failed to rebuild tool index: \(error)")
        }
    }

    // MARK: - Helpers

    private func buildIndexText(name: String, description: String, parameters: JSONValue?) -> String {
        let paramText = extractParameterText(from: parameters)
        if paramText.isEmpty {
            return "\(name) \(description)"
        }
        return "\(name) \(description) \(paramText)"
    }

    private func extractParameterText(from params: JSONValue?) -> String {
        guard case .object(let schema) = params,
            case .object(let properties) = schema["properties"]
        else { return "" }
        var parts: [String] = []
        for (key, value) in properties {
            parts.append(key)
            if case .object(let propSchema) = value,
                case .string(let desc) = propSchema["description"]
            {
                parts.append(desc)
            }
        }
        return parts.joined(separator: " ")
    }

    private func deterministicUUID(for toolId: String) -> UUID {
        let hash = SHA256.hash(data: Data("tool:\(toolId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = toolId
        return uuid
    }
}
