//
//  CapabilitySearchEvaluator.swift
//  osaurus
//
//  Public facade over the index-search portion of `CapabilitySearch`.
//  Decode-friendly `Codable` result type under an `@MainActor`
//  constraint, scoped to the recall layer (no LLM call, no agent state).
//  Used by the `OsaurusEvals` `capability_search` domain runner to score
//  raw vs threshold-accepted hits in one pass — it measures the BM25 +
//  embedder + RRF + threshold path that backs `capabilities_discover`.
//

import Foundation

// MARK: - Result type

/// Decode-friendly snapshot of one capability-search invocation.
///
/// **Tools lane is hybrid (BM25 + embed via RRF)** — each tool hit
/// carries optional per-component scores plus the fused score and the
/// acceptance bit. **Methods + skills lanes are pure embedding** —
/// only `embedScore` is populated for those (BM25 mirror not yet built
/// for those indices; tracked as a follow-up).
///
/// JSON-stable on purpose so the eval CLI can write machine-readable
/// reports and the `--report-forensics` block can render H1/H2/H3/H4/H5
/// labels off the score nullability pattern.
public struct CapabilitySearchEvaluation: Sendable, Codable {
    public let query: String
    public let toolHits: [Hit]
    public let methodHits: [Hit]
    public let skillHits: [Hit]
    /// Number of tools the capability-search path would consider in
    /// the live registry (enabled, non-runtime-managed,
    /// non-capability-infrastructure). Mirrors
    /// `CapabilitySearchHealth.registryToolCount`.
    public let registrySize: Int
    /// Number of tools currently in `tool_index`. A wide gap between
    /// `registrySize` and `indexSize` is the H2 smoking gun.
    public let indexSize: Int
    /// RRF cutoff applied to the **tools** lane. Echoes the caller's
    /// `threshold:` argument when set, otherwise the production
    /// `CapabilitySearch.minimumFusedScore`.
    public let appliedMinFusedScore: Float
    /// Embed-cosine acceptance floor applied to the **methods** lane.
    /// Echoes `CapabilitySearch.minimumRelevanceScoreMethods`. The
    /// per-case `thresholdOverride` and CLI `--threshold` flag drive
    /// the **tools** lane only (RRF scale, ~0.033 max), so this lane
    /// always uses the production constant — sweeping a fused-score
    /// value into the cosine lane would silently disable the
    /// methods quality gate.
    public let appliedMethodsThreshold: Float
    /// Embed-cosine acceptance floor applied to the **skills** lane.
    /// Held independent of the methods cutoff so a future eval pass
    /// can move one without the other.
    public let appliedSkillsThreshold: Float
    public let latencyMs: Double

    /// One per (raw OR accepted) candidate for the case's query. The
    /// nullability pattern of `bm25Score` / `embedScore` is the
    /// forensic signal:
    ///   - both populated → fused candidate
    ///   - only `bm25Score` → embed missed it (lexical-only)
    ///   - only `embedScore` → BM25 missed it (semantic-only)
    ///   - both nil → impossible (would not appear in the list)
    public struct Hit: Sendable, Codable {
        public let name: String
        public let bm25Score: Float?
        public let embedScore: Float?
        public let fusedScore: Float
        public let acceptedByThreshold: Bool

        public init(
            name: String,
            bm25Score: Float?,
            embedScore: Float?,
            fusedScore: Float,
            acceptedByThreshold: Bool
        ) {
            self.name = name
            self.bm25Score = bm25Score
            self.embedScore = embedScore
            self.fusedScore = fusedScore
            self.acceptedByThreshold = acceptedByThreshold
        }
    }

    public init(
        query: String,
        toolHits: [Hit],
        methodHits: [Hit],
        skillHits: [Hit],
        registrySize: Int,
        indexSize: Int,
        appliedMinFusedScore: Float,
        appliedMethodsThreshold: Float,
        appliedSkillsThreshold: Float,
        latencyMs: Double
    ) {
        self.query = query
        self.toolHits = toolHits
        self.methodHits = methodHits
        self.skillHits = skillHits
        self.registrySize = registrySize
        self.indexSize = indexSize
        self.appliedMinFusedScore = appliedMinFusedScore
        self.appliedMethodsThreshold = appliedMethodsThreshold
        self.appliedSkillsThreshold = appliedSkillsThreshold
        self.latencyMs = latencyMs
    }
}

// MARK: - Evaluator

/// Public entry point for capability-search recall evals. Lives on the
/// main actor because the underlying registry / index reads are. No LLM
/// call, no agent fixture — pure index-path measurement, safe to run in
/// CI and to invoke at any threshold.
@MainActor
public enum CapabilitySearchEvaluator {

    /// Run capability search against the live indices and report
    /// hybrid (tools) + pure-embedding (methods/skills) hits with
    /// per-component scores.
    ///
    /// `threshold` is **scoped to the tools lane**. When non-nil it
    /// overrides `CapabilitySearch.minimumFusedScore` (the RRF cutoff
    /// for the BM25+embed hybrid). When nil, the production default
    /// is used. The methods + skills lanes always use their own
    /// production constants (`minimumRelevanceScoreMethods` and
    /// `…Skills`, both embed-cosine, scale ~0.0–1.0) regardless of
    /// `threshold`. Reason: fused-score values (RRF k=60 max ≈ 0.033)
    /// and embed-cosine values live on completely different scales —
    /// applying the sweep value to both lanes silently disables the
    /// methods/skills quality gate when sweeping low fused values
    /// like 0.005. Sweeping the embed cutoffs is a separate concern;
    /// expose its own flag if/when needed.
    /// `embedCosineFloor` is the **tools-lane** embed-cosine quality gate
    /// applied INSIDE the RRF fusion (`ToolSearchService.searchHybrid`,
    /// `minEmbedCosine:`). When nil the production constant
    /// `CapabilitySearch.minimumEmbedCosineForTools` is used so the eval
    /// measures exactly what `capabilities_discover` does in the chat
    /// path. A non-nil value (the CLI `--embed-cosine-floor` sweep) lets
    /// the calibration sweep map abstain/recall accepted-counts to the
    /// floor without rebuilding — `0` disables the gate to record raw
    /// pre-gate cosines. Independent of `threshold` (the RRF fused cutoff)
    /// because the two operate at different stages (per-candidate cosine
    /// gate vs final fused-score cutoff) and on different scales.
    public static func evaluate(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil,
        embedCosineFloor: Float? = nil
    ) async -> CapabilitySearchEvaluation {
        let appliedFused = threshold ?? CapabilitySearch.minimumFusedScore
        let appliedEmbedFloor = embedCosineFloor ?? CapabilitySearch.minimumEmbedCosineForTools
        let appliedMethodsThreshold = CapabilitySearch.minimumRelevanceScoreMethods
        let appliedSkillsThreshold = CapabilitySearch.minimumRelevanceScoreSkills
        let started = Date()

        // Mirror the production query-intent abstain gate
        // (`CapabilitySearch.search`): a pure chit-chat query yields no
        // candidates, so the eval measures EXACTLY what
        // `capabilities_discover` does — not a divergent lane-only path.
        // Health is still snapshotted so registry/index forensics stay
        // meaningful on an abstained row.
        if CapabilityQueryIntent.isConversationalAbstain(query) {
            let health = await CapabilitySearchDiagnostics.snapshot(mode: .full)
            return CapabilitySearchEvaluation(
                query: query,
                toolHits: [],
                methodHits: [],
                skillHits: [],
                registrySize: health.registryToolCount,
                indexSize: health.indexedToolCount,
                appliedMinFusedScore: appliedFused,
                appliedMethodsThreshold: appliedMethodsThreshold,
                appliedSkillsThreshold: appliedSkillsThreshold,
                latencyMs: Date().timeIntervalSince(started) * 1000
            )
        }

        async let toolPair = ToolSearchService.shared.searchHybridWithDiagnostic(
            query: query,
            topK: topK,
            minFusedScore: appliedFused,
            minEmbedCosine: appliedEmbedFloor
        )
        async let methodPair = MethodSearchService.shared.searchWithDiagnostic(
            query: query,
            topK: topK,
            threshold: appliedMethodsThreshold
        )
        async let skillPair = SkillSearchService.shared.searchWithDiagnostic(
            query: query,
            topK: topK,
            threshold: appliedSkillsThreshold
        )
        async let healthSnapshot = CapabilitySearchDiagnostics.snapshot(mode: .full)

        let (_, toolDiag) = await toolPair
        let (_, methodDiag) = await methodPair
        let (_, skillDiag) = await skillPair
        let health = await healthSnapshot
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        return CapabilitySearchEvaluation(
            query: query,
            toolHits: makeToolHits(diagnostic: toolDiag),
            methodHits: makeEmbeddingOnlyHits(
                raw: methodDiag.rawHits,
                accepted: methodDiag.acceptedHits
            ),
            skillHits: makeEmbeddingOnlyHits(
                raw: skillDiag.rawHits,
                accepted: skillDiag.acceptedHits
            ),
            registrySize: health.registryToolCount,
            indexSize: health.indexedToolCount,
            appliedMinFusedScore: appliedFused,
            appliedMethodsThreshold: appliedMethodsThreshold,
            appliedSkillsThreshold: appliedSkillsThreshold,
            latencyMs: elapsedMs
        )
    }

    /// Build the hybrid `[Hit]` for the tools lane. The diagnostic
    /// already carries every candidate (`allHits`) with full
    /// per-component nullability and the threshold-accepted subset
    /// (`acceptedHits`); we just project them into the public
    /// `Codable` shape and tag membership.
    private static func makeToolHits(
        diagnostic: ToolSearchHybridDiagnostic
    ) -> [CapabilitySearchEvaluation.Hit] {
        let acceptedNames = Set(diagnostic.acceptedHits.map(\.name))
        return diagnostic.allHits.map { hit in
            CapabilitySearchEvaluation.Hit(
                name: hit.name,
                bm25Score: hit.bm25Score,
                embedScore: hit.embedScore,
                fusedScore: hit.fusedScore,
                acceptedByThreshold: acceptedNames.contains(hit.name)
            )
        }
    }

    /// Build `[Hit]` from a pure-embedding diagnostic (methods,
    /// skills). `bm25Score` is `nil` for every entry — those lanes
    /// don't have an FTS5 mirror today. `fusedScore` is the
    /// embedding score itself so a single-source lane still has a
    /// usable composite for downstream ranking display.
    private static func makeEmbeddingOnlyHits<H: SearchDiagnosticHit>(
        raw: [H],
        accepted: [H]
    ) -> [CapabilitySearchEvaluation.Hit] {
        let acceptedNames = Set(accepted.map(\.name))
        return raw.map { hit in
            CapabilitySearchEvaluation.Hit(
                name: hit.name,
                bm25Score: nil,
                embedScore: hit.score,
                fusedScore: hit.score,
                acceptedByThreshold: acceptedNames.contains(hit.name)
            )
        }
    }
}

// MARK: - Cross-service hit shape

/// Internal protocol unifying the three `*SearchDiagnostic.Hit` types
/// so `makeEmbeddingOnlyHits` can be written once across the methods
/// and skills lanes. Mirror of the fileprivate `DiagnosticHit` in
/// `CapabilitySearch.swift`; kept separate (and at module-internal
/// visibility) because `CapabilitySearchEvaluator` needs the constraint
/// at API boundaries while the env-flag log block is private to its file.
internal protocol SearchDiagnosticHit {
    var name: String { get }
    var score: Float { get }
}

extension ToolSearchDiagnostic.Hit: SearchDiagnosticHit {}
extension MethodSearchDiagnostic.Hit: SearchDiagnosticHit {}
extension SkillSearchDiagnostic.Hit: SearchDiagnosticHit {}
