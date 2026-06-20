//
//  CapabilitySearch.swift
//  osaurus
//
//  Hybrid (BM25 + vector) search across indexed methods, tools, and skills.
//  Backs the `capabilities_discover` tool so the agent can find capabilities
//  it isn't currently holding in its schema and load them via
//  `capabilities_load`.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "CapabilitySearch")

// MARK: - Result Types

struct CapabilitySearchResults {
    let methods: [MethodSearchResult]
    let tools: [ToolSearchResult]
    let skills: [SkillSearchResult]

    var isEmpty: Bool {
        methods.isEmpty && tools.isEmpty && skills.isEmpty
    }
}

// MARK: - Capability Search (used by capabilities_discover tool)

enum CapabilitySearch {
    /// Embed-cosine acceptance floor for the **methods** lane.
    /// Calibrated against `Suites/CapabilitySearch/method-*.json`
    /// (PR-A baseline, 2026-05-07): lowest expected-hit was
    /// `plot_data` at 0.281; highest abstain noise was 0.179.
    /// 0.25 sits 40% above abstain noise and 12% below the
    /// tightest recall hit — the only band that flips every
    /// PR-A method case to PASS without re-admitting abstain.
    /// Was a single global `0.7` until PR-A showed that value
    /// dropped every method/skill true positive (top hits land
    /// at 0.28-0.59 on `potion-base-4M`, not 0.7+).
    static let minimumRelevanceScoreMethods: Float = 0.25

    /// Embed-cosine acceptance floor for the **skills** lane.
    /// Held identical to `…Methods` because the embedder is
    /// shared (`potion-base-4M`) and PR-A surfaced no signal
    /// arguing for a different floor. Kept as a separate
    /// constant so a future eval pass can move one lane
    /// without the other.
    static let minimumRelevanceScoreSkills: Float = 0.25

    /// RRF cutoff for the tools lane (BM25 + embed fusion). Baked in
    /// as `let` to avoid a mutable global — component scores in
    /// forensics are only meaningful against a fixed cutoff. Future
    /// tunability surfaces through a `CapabilitySearchSettings` type
    /// (out of scope this PR), which reads its own copy and never
    /// mutates this constant.
    ///
    /// Sweep result (T ∈ {0.005, 0.010, 0.015, 0.020, 0.025, 0.030}):
    /// `0.020` is the empirical sweet spot — `browser-prefix` matches
    /// 9/5 expected, `extract-webpage-natural` matches 2/1 expected,
    /// and `abstain-greeting` accepted-count drops from 10 → 3 (vs
    /// 10 at lower thresholds). Higher T (0.025, 0.030) doesn't help
    /// abstain materially (3 → 2) but starts costing recall on
    /// browser at T=0.030 (9 → 7).
    ///
    /// **Known limitation:** abstain never reaches 0 accepted hits at
    /// any tested T because RRF with k=60 caps the max fused score at
    /// `2 × 1/(60+1) ≈ 0.0328`, which compresses the gap between
    /// abstain noise (top 0.032) and legitimate recall (top 0.033) to
    /// a 0.001 window. No single `minFusedScore` separates them. The
    /// abstain case is moved to tracking-only in `recall_floors.json`
    /// alongside `shell-execution`. A proper abstain mechanism — pre-
    /// filter quality gate before RRF, score-based fusion instead of
    /// rank-based, or a query-intent classifier — is a follow-up.
    ///
    /// Future tunability surfaces through a `CapabilitySearchSettings`
    /// type (out of scope this PR), which reads its own copy and
    /// never mutates this constant.
    static let minimumFusedScore: Float = 0.020

    /// Embed-cosine quality floor for the **tools** lane, applied INSIDE
    /// the hybrid fusion (`ToolSearchService.searchHybrid`): an embedding
    /// candidate scoring below this cosine contributes ZERO to its RRF
    /// fused score, so a low-similarity abstain-noise tool can no longer
    /// rank-fuse its way past `minimumFusedScore`. This is the real abstain
    /// mechanism the `minimumFusedScore` note flagged as a follow-up —
    /// pure rank-based RRF saturates near `2/(60+1) ≈ 0.0328` and cannot
    /// separate abstain from recall on rank alone, but gating the embed
    /// contribution by cosine quality does (BM25-only rank-1 already sits
    /// below the fused cutoff). Held at the shared-embedder value the
    /// methods/skills lanes use (`potion-base-4M`, floors 0.25 — same
    /// cosine scale, abstain noise tops ≈0.18, real recall ≈0.28+).
    /// Calibrated/verified by the CapabilitySearch sweep recorded in
    /// `Packages/OsaurusEvals/Config/capability-search-sweep.md`.
    static let minimumEmbedCosineForTools: Float = 0.25

    /// Env var that swaps the inner per-lane search calls for their
    /// diagnostic variants (`searchHybridWithDiagnostic` for tools,
    /// `searchWithDiagnostic` for methods + skills) and emits a single
    /// multi-line `Logger.notice` block per call with per-component
    /// BM25 + embed scores. Doubles the embed cost of
    /// `capabilities_discover` while set — only flip it during a manual
    /// recall repro.
    private static let debugTraceEnvVar = "OSAURUS_DEBUG_CAPABILITY_SEARCH"

    /// Tools-only fast path. Skips the methods + skills lanes entirely
    /// for callers that have already restricted themselves to the tools
    /// universe (default-agent configure surface today). Avoids burning
    /// embedder / BM25 work on hits we'd discard anyway.
    static func searchToolsOnly(
        query: String,
        topK: Int,
        allowedToolNames: Set<String>? = nil
    ) async -> CapabilitySearchResults {
        // Query-intent abstain: a pure greeting/closing pleasantry has no
        // capability to discover, so skip the lanes entirely (see
        // CapabilityQueryIntent — the pre-RRF gate the cosine-floor sweep
        // flagged as the correct fix for the abstain class).
        if CapabilityQueryIntent.isConversationalAbstain(query) {
            return CapabilitySearchResults(methods: [], tools: [], skills: [])
        }
        await CapabilitySearchDiagnostics.logSnapshotOnce(
            reason: "CapabilitySearch.searchToolsOnly"
        )
        let tools = await ToolSearchService.shared.searchHybrid(
            query: query,
            topK: topK,
            minFusedScore: minimumFusedScore,
            minEmbedCosine: minimumEmbedCosineForTools,
            allowedNames: allowedToolNames
        )
        return CapabilitySearchResults(methods: [], tools: tools, skills: [])
    }

    static func search(
        query: String,
        topK: (methods: Int, tools: Int, skills: Int),
        allowedToolNames: Set<String>? = nil
    ) async -> CapabilitySearchResults {
        let methodsThreshold = minimumRelevanceScoreMethods
        let skillsThreshold = minimumRelevanceScoreSkills
        let fusedCutoff = minimumFusedScore

        // Query-intent abstain: short-circuit pure chit-chat before any
        // BM25/embed work (see CapabilityQueryIntent). Returns empty so
        // `capabilities_discover` doesn't surface RRF-saturation noise for
        // a greeting/thank-you with no capability intent.
        if CapabilityQueryIntent.isConversationalAbstain(query) {
            return CapabilitySearchResults(methods: [], tools: [], skills: [])
        }

        // Per-process cheap-path snapshot. First call from this site
        // emits one `CapabilitySearchHealth` line; subsequent calls
        // are dropped. Cheap mode is sub-millisecond — `entryCount()`
        // + an in-memory `ToolRegistry.listTools()` walk.
        await CapabilitySearchDiagnostics.logSnapshotOnce(reason: "CapabilitySearch.search")

        if ProcessInfo.processInfo.environment[Self.debugTraceEnvVar] == "1" {
            return await searchWithVerboseTrace(
                query: query,
                topK: topK,
                allowedToolNames: allowedToolNames,
                methodsThreshold: methodsThreshold,
                skillsThreshold: skillsThreshold,
                fusedCutoff: fusedCutoff
            )
        }

        async let methodHits = MethodSearchService.shared.search(
            query: query,
            topK: topK.methods,
            threshold: methodsThreshold
        )
        async let toolHits = ToolSearchService.shared.searchHybrid(
            query: query,
            topK: topK.tools,
            minFusedScore: fusedCutoff,
            minEmbedCosine: minimumEmbedCosineForTools,
            allowedNames: allowedToolNames
        )
        async let skillHits = SkillSearchService.shared.search(
            query: query,
            topK: topK.skills,
            threshold: skillsThreshold
        )

        // Methods + skills double-filter mirrors the in-actor cutoff
        // (kept from the diagnostics PR — collapsing it crosses the
        // Phase 1 instrumentation boundary; tracked as an out-of-scope
        // tidy). Tools come from `searchHybrid` which has already
        // applied `minFusedScore` — no outer filter needed.
        return CapabilitySearchResults(
            methods: (await methodHits).filter { $0.searchScore >= methodsThreshold },
            tools: await toolHits,
            skills: (await skillHits).filter { $0.searchScore >= skillsThreshold }
        )
    }

    /// Env-flag branch. Identical I/O contract to the production path
    /// (same `CapabilitySearchResults`) plus a multi-line structured
    /// log capturing every raw + accepted hit, the current
    /// `CapabilitySearchHealth` (full mode), and per-component BM25
    /// + embed scores for the tools lane. Doubles the embed cost;
    /// only fires when `OSAURUS_DEBUG_CAPABILITY_SEARCH=1`.
    private static func searchWithVerboseTrace(
        query: String,
        topK: (methods: Int, tools: Int, skills: Int),
        allowedToolNames: Set<String>?,
        methodsThreshold: Float,
        skillsThreshold: Float,
        fusedCutoff: Float
    ) async -> CapabilitySearchResults {
        async let methodPair = MethodSearchService.shared.searchWithDiagnostic(
            query: query,
            topK: topK.methods,
            threshold: methodsThreshold
        )
        async let toolPair = ToolSearchService.shared.searchHybridWithDiagnostic(
            query: query,
            topK: topK.tools,
            minFusedScore: fusedCutoff,
            minEmbedCosine: minimumEmbedCosineForTools,
            allowedNames: allowedToolNames
        )
        async let skillPair = SkillSearchService.shared.searchWithDiagnostic(
            query: query,
            topK: topK.skills,
            threshold: skillsThreshold
        )
        async let healthSnapshot = CapabilitySearchDiagnostics.snapshot(mode: .full)

        let (methodResults, methodDiag) = await methodPair
        let (toolResults, toolDiag) = await toolPair
        let (skillResults, skillDiag) = await skillPair
        let health = await healthSnapshot
        let healthSummary = CapabilitySearchDiagnostics.formatSummary(health)

        logger.notice(
            """
            CapabilitySearch query=\(query, privacy: .private(mask: .hash))
            methodsThreshold=\(methodsThreshold, privacy: .public) skillsThreshold=\(skillsThreshold, privacy: .public) fusedCutoff=\(fusedCutoff, privacy: .public)
            health=\(healthSummary, privacy: .public)
            methods raw=\(formatHits(methodDiag.rawHits), privacy: .public)
            methods accepted=\(formatHits(methodDiag.acceptedHits), privacy: .public)
            tools bm25Available=\(toolDiag.bm25Available, privacy: .public) all=\(formatHybridHits(toolDiag.allHits), privacy: .public)
            tools accepted=\(formatHybridHits(toolDiag.acceptedHits), privacy: .public)
            tools filteredByAllowlist=\(formatNames(toolDiag.filteredByAllowlist), privacy: .public)
            skills raw=\(formatHits(skillDiag.rawHits), privacy: .public)
            skills accepted=\(formatHits(skillDiag.acceptedHits), privacy: .public)
            """
        )

        return CapabilitySearchResults(
            methods: methodResults.filter { $0.searchScore >= methodsThreshold },
            tools: toolResults,
            skills: skillResults.filter { $0.searchScore >= skillsThreshold }
        )
    }

    static func canCreatePlugins(agentId: UUID) async -> Bool {
        await MainActor.run {
            guard let config = AgentManager.shared.effectiveAutonomousExec(for: agentId) else { return false }
            return config.enabled && config.pluginCreate
        }
    }
}

// MARK: - Diagnostic helpers (fileprivate)

/// Marker protocol so the env-flag log path can format hits from any
/// of the three `*SearchDiagnostic.Hit` types with one helper.
fileprivate protocol DiagnosticHit {
    var name: String { get }
    var score: Float { get }
}

extension ToolSearchDiagnostic.Hit: DiagnosticHit {}
extension MethodSearchDiagnostic.Hit: DiagnosticHit {}
extension SkillSearchDiagnostic.Hit: DiagnosticHit {}

fileprivate func formatHits<H: DiagnosticHit>(_ hits: [H]) -> String {
    if hits.isEmpty { return "[]" }
    return
        hits
        .map { "\($0.name)=\(String(format: "%.3f", $0.score))" }
        .joined(separator: ",")
}

/// Per-hit format for the tools-lane hybrid trace block. Each hit
/// renders as `name(bm25=X.XXX|n/a, embed=Y.YYY|n/a, fused=Z.ZZZ)`
/// so an engineer reading Console can see at a glance which source
/// surfaced the candidate (the `n/a` markers carry the H4/H5 signal).
fileprivate func formatHybridHits(_ hits: [ToolSearchHybridDiagnostic.Hit]) -> String {
    if hits.isEmpty { return "[]" }
    return
        hits
        .map { hit -> String in
            let bm25 = hit.bm25Score.map { String(format: "%.3f", $0) } ?? "n/a"
            let embed = hit.embedScore.map { String(format: "%.3f", $0) } ?? "n/a"
            let fused = String(format: "%.3f", hit.fusedScore)
            return "\(hit.name)(bm25=\(bm25),embed=\(embed),fused=\(fused))"
        }
        .joined(separator: ",")
}

fileprivate func formatNames(_ names: [String]) -> String {
    names.isEmpty ? "[]" : "[\(names.joined(separator: ","))]"
}
