//
//  PreflightCapabilitySearch.swift
//  osaurus
//
//  Selects dynamic tools to inject before the agent loop starts.
//  Uses a single LLM call to pick relevant tools from the full catalog.
//  Methods and skills remain accessible via capabilities_search / capabilities_load.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "PreflightSearch")

// MARK: - Search Mode

public enum PreflightSearchMode: String, Codable, CaseIterable, Sendable {
    case off, narrow, balanced, wide

    public var displayName: String {
        switch self {
        case .off: return L("Off")
        case .narrow: return L("Narrow")
        case .balanced: return L("Balanced")
        case .wide: return L("Wide")
        }
    }

    var toolCap: Int {
        switch self {
        case .off: return 0
        case .narrow: return 2
        case .balanced: return 5
        case .wide: return 15
        }
    }

    /// Number of catalog candidates pre-ranked by embedding similarity
    /// and shown to the LLM. Smaller than the full catalog by design —
    /// Apple Foundation Models has a 4K-token context window and a
    /// 77-tool catalog tokenises to ~4.3K, blowing the budget before
    /// the LLM sees the request. The LLM still does the final pick;
    /// this just narrows its candidate pool. `0` means "show every
    /// dynamic tool" (legacy behaviour, useful if the embedder breaks).
    var catalogTopK: Int {
        switch self {
        case .off: return 0
        case .narrow: return 6
        case .balanced: return 12
        case .wide: return 24
        }
    }

    public var helpText: String {
        switch self {
        case .off: return L("Disable pre-flight search. Only explicit tool calls are used.")
        case .narrow: return L("Minimal tool injection. Up to 2 tools loaded.")
        case .balanced: return L("Default. Up to 5 relevant tools loaded.")
        case .wide: return L("Aggressive search. Up to 15 tools loaded, may increase prompt size.")
        }
    }
}

// MARK: - Result Types

struct PreflightCapabilityItem: Equatable, Sendable {
    enum CapabilityType: String, Equatable, Sendable {
        case method, tool, skill

        var icon: String {
            switch self {
            case .method: return "doc.text"
            case .tool: return "wrench"
            case .skill: return "lightbulb"
            }
        }
    }

    let type: CapabilityType
    let name: String
    let description: String
}

struct PreflightResult: Sendable {
    let toolSpecs: [Tool]
    let items: [PreflightCapabilityItem]
    /// Phase-2 "teaser" capabilities the model can pull in via
    /// `capabilities_load`. Derived from `toolSpecs` by grouping picks back
    /// to their plugin and surfacing the plugin's enabled sibling tools and
    /// bundled skill. Empty when no pick belongs to a plugin or the plugin
    /// has no other enabled tools / skill. Cached on `SessionToolState` so
    /// the rendered "Plugin Companions" prompt section is byte-stable
    /// across turns (KV-cache friendly).
    let companions: [PluginCompanion]

    static let empty = PreflightResult(toolSpecs: [], items: [])

    init(
        toolSpecs: [Tool],
        items: [PreflightCapabilityItem],
        companions: [PluginCompanion] = []
    ) {
        self.toolSpecs = toolSpecs
        self.items = items
        self.companions = companions
    }
}

/// Full diagnostic capture from one preflight invocation. Surfaced only
/// to the eval path (via `PreflightCapabilitySearch.searchWithDiagnostic`)
/// — the production chat / HTTP path uses the bare `search(...)` which
/// drops this so the per-session preflight cache stays small.
///
/// The point: when a small model (Foundation, etc.) returns no picks,
/// engineers need to see WHY — `NONE`, malformed picks, prose, an empty
/// catalog (config issue), etc. Every short-circuit branch populates a
/// diagnostic so "no picks" never reads as "no information".
struct PreflightDiagnostic: Sendable {
    /// The exact system prompt sent to the LLM. `nil` when preflight
    /// short-circuited before rendering it (empty query / mode .off /
    /// empty catalog).
    let systemPrompt: String?
    /// Raw text the LLM returned. `nil` when the LLM threw or was
    /// never called (short-circuit branches above).
    let rawResponse: String?
    /// Picks the parser extracted, BEFORE the embedding guardrail
    /// dropped any. Lets evals tell apart "model picked nothing" from
    /// "model picked but guardrail rejected".
    let llmPicks: [String]
    /// Number of dynamic tools (MCP / plugin / sandbox-plugin) the LLM
    /// would see in the catalog. Zero means the eval-CLI process has
    /// no enabled plugin tools — usually a config-dir mismatch with
    /// the host app, not a preflight bug.
    let catalogSize: Int
    /// String description of the error the LLM bridge threw, if any.
    /// `nil` means the LLM call succeeded (or was never made). Captured
    /// so verbose eval output can distinguish "model returned NONE"
    /// from "model bridge threw timeout / circuit-breaker / network".
    let llmError: String?
}

/// Per-session record of the initial preflight selection plus every tool the
/// agent has loaded mid-session via `capabilities_load`. Stored on the chat
/// window state (per `sessionId`) and on the work session (per `issue.id`)
/// so subsequent compose calls can skip the LLM preflight call and feed the
/// model the same tool union — keeping the rendered system prompt + `<tools>`
/// block byte-stable across turns and maximizing KV-cache reuse.
struct SessionToolState: Sendable {
    var initialPreflight: PreflightResult
    var loadedToolNames: LoadedTools
    /// Snapshot of always-loaded tool names from the FIRST compose of this
    /// session. On subsequent composes the resolver intersects the live
    /// always-loaded set against this snapshot so a tool that registers
    /// mid-session (e.g. sandbox_exec coming online a few seconds late)
    /// does NOT silently appear in turn 2's schema. Toolsets must stay
    /// stable mid-conversation — changing them breaks prompt caching and
    /// disorients the model. New tools only enter via the explicit
    /// `capabilities_load` path (which writes loadedToolNames).
    /// `nil` means "no snapshot yet" — the next compose will record one.
    var initialAlwaysLoadedNames: LoadedTools?
    /// Compact signature of the (executionMode, toolSelectionMode) that
    /// captured this state. The send path compares the live signature on
    /// every turn and invalidates on a flip, so dynamically-loaded tools
    /// from one mode cannot leak into another and an empty manual-mode
    /// preflight cache cannot survive a flip back to auto. `nil` only for
    /// legacy entries created before this field existed.
    var sessionFingerprint: String?

    init(
        initialPreflight: PreflightResult,
        loadedToolNames: LoadedTools = [],
        initialAlwaysLoadedNames: LoadedTools? = nil,
        sessionFingerprint: String? = nil
    ) {
        self.initialPreflight = initialPreflight
        self.loadedToolNames = loadedToolNames
        self.initialAlwaysLoadedNames = initialAlwaysLoadedNames
        self.sessionFingerprint = sessionFingerprint
    }

    /// Canonical fingerprint string for a (mode, toolSelectionMode) pair.
    /// Centralised so the read and write sides cannot drift in shape.
    static func fingerprint(executionMode: ExecutionMode, toolMode: ToolSelectionMode) -> String {
        let modeTag: String
        switch executionMode {
        case .hostFolder: modeTag = "host"
        case .sandbox: modeTag = "sandbox"
        case .none: modeTag = "none"
        }
        return "\(modeTag)/\(toolMode.rawValue)"
    }
}

// MARK: - Capability Search (used by capabilities_search tool)

struct CapabilitySearchResults {
    let methods: [MethodSearchResult]
    let tools: [ToolSearchResult]
    let skills: [SkillSearchResult]

    var isEmpty: Bool {
        methods.isEmpty && tools.isEmpty && skills.isEmpty
    }
}

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

    /// Env var that swaps the inner per-lane search calls for their
    /// diagnostic variants (`searchHybridWithDiagnostic` for tools,
    /// `searchWithDiagnostic` for methods + skills) and emits a single
    /// multi-line `Logger.notice` block per call with per-component
    /// BM25 + embed scores. Doubles the embed cost of
    /// `capabilities_search` while set — only flip it during a manual
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
        await CapabilitySearchDiagnostics.logSnapshotOnce(
            reason: "CapabilitySearch.searchToolsOnly"
        )
        let tools = await ToolSearchService.shared.searchHybrid(
            query: query,
            topK: topK,
            minFusedScore: minimumFusedScore,
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

// MARK: - Preflight Tool Selection

enum PreflightCapabilitySearch {

    private static let selectionTimeout: TimeInterval = 8

    /// High-volume salutations and acknowledgements are not capability
    /// requests. Short-circuiting them here protects every entry point
    /// (chat, HTTP, plugin host, eval probes) from spending an LLM call and
    /// a dynamic prompt block before the user has asked the agent to do work.
    static func isTrivialUserInput(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }

        let keptScalars = trimmed.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return Character(String(scalar))
            }
            return " "
        }
        let normalized = String(keptScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let trivialInputs: Set<String> = [
            "hi", "hello", "hey", "yo", "hiya", "howdy",
            "good morning", "good afternoon", "good evening",
            "thanks", "thank you", "thx", "ty",
            "ok", "okay", "cool", "nice", "great",
        ]
        return trivialInputs.contains(normalized)
    }

    /// Test seam for the LLM call. Production calls go through
    /// `CoreModelService.shared.generate`; tests inject canned responses.
    typealias LLMGenerator = @Sendable (_ prompt: String, _ systemPrompt: String) async throws -> String

    /// Test seam for the embedding guardrail. Returns embeddings for the
    /// supplied texts. Production calls go through `EmbeddingService.shared`;
    /// tests inject deterministic vectors (or throw to exercise the
    /// graceful-degrade path).
    typealias Embedder = @Sendable (_ texts: [String]) async throws -> [[Float]]

    /// Picks below this cosine similarity to the query are treated as
    /// egregious mismatches and dropped. Far below
    /// `ToolSearchService.defaultSearchThreshold` (0.10) on purpose — this
    /// is a *floor* on individual LLM picks, not a candidate gate, so
    /// embedder recall failure cannot remove a true positive.
    static let guardrailMinSimilarity: Float = 0.05

    // MARK: Search

    /// Public entry point. Wires the agent's enabled-tool allowlist into the
    /// pre-flight catalog so Auto-discover only ever picks from tools the user
    /// has explicitly enabled in the capability picker. A `nil` allowlist
    /// (un-seeded legacy agent) preserves the historical behaviour of
    /// considering every dynamic tool in the registry.
    ///
    /// `model` is the active conversation model, threaded into the LLM call
    /// as a chat-model fallback when no core model is configured (or when the
    /// configured one is `modelUnavailable`). See
    /// `CoreModelService.generate(...)` and GitHub issue #823.
    static func search(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID,
        model: String? = nil
    ) async -> PreflightResult {
        // Per-process cheap-path snapshot, mirroring the gate inside
        // `CapabilitySearch.search`. Different `reason` keys so both
        // sites can fire once each — independently helpful when one
        // path runs early-boot and the other doesn't.
        await CapabilitySearchDiagnostics.logSnapshotOnce(reason: "PreflightCapabilitySearch.search")

        let allowed = await MainActor.run {
            AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init)
        }
        return await search(
            query: query,
            mode: mode,
            allowedNames: allowed,
            llm: defaultLLM(fallbackModel: model),
            embedder: defaultEmbedder
        )
    }

    /// Internal entry point with injectable LLM + embedder seams. Tests call
    /// this directly with canned closures; production goes through
    /// `search(query:mode:agentId:)` which wires the real services.
    static func search(
        query: String,
        mode: PreflightSearchMode,
        allowedNames: Set<String>? = nil,
        llm: LLMGenerator,
        embedder: Embedder?
    ) async -> PreflightResult {
        let (result, _) = await searchWithDiagnostic(
            query: query,
            mode: mode,
            allowedNames: allowedNames,
            llm: llm,
            embedder: embedder
        )
        return result
    }

    /// Diagnostic-capturing entry point. Wires the production LLM +
    /// embedder so callers (the eval CLI, future scoreboards) get the
    /// exact same one-shot generation contract the chat path uses.
    /// Threads the same agent allowlist and chat-model fallback as
    /// `search(query:mode:agentId:model:)`.
    static func searchWithDiagnostic(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID,
        model: String? = nil
    ) async -> (PreflightResult, PreflightDiagnostic?) {
        let allowed = await MainActor.run {
            AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init)
        }
        return await searchWithDiagnostic(
            query: query,
            mode: mode,
            allowedNames: allowed,
            llm: defaultLLM(fallbackModel: model),
            embedder: defaultEmbedder
        )
    }

    /// Diagnostic-capturing variant with injectable seams. Returns the
    /// same `PreflightResult` as `search(...)` plus a
    /// `PreflightDiagnostic?` carrying the system prompt + raw LLM
    /// response + pre-guardrail picks + catalog stats + LLM error.
    /// The diagnostic is `nil` only for the truly nothing-to-say
    /// short-circuits (empty query, mode .off); the empty-catalog
    /// branch still emits one so verbose eval output can pinpoint a
    /// config-dir mismatch instead of a model failure.
    ///
    /// Only the OsaurusEvals path uses the diagnostic. The chat / HTTP
    /// path uses the bare `search(...)` so the diagnostic doesn't ride
    /// along on the per-session `SessionToolState.initialPreflight`
    /// cache and inflate it.
    ///
    /// `allowedNames` (when non-nil) restricts the dynamic catalog to the
    /// user's enabled set so the per-item Enabled toggles in the agent
    /// capability picker are the single source of truth in both Auto and
    /// Manual modes. `nil` keeps the legacy registry-wide behaviour for
    /// callers that don't have an agent context.
    static func searchWithDiagnostic(
        query: String,
        mode: PreflightSearchMode,
        allowedNames: Set<String>? = nil,
        llm: LLMGenerator,
        embedder: Embedder?
    ) async -> (PreflightResult, PreflightDiagnostic?) {
        // Truly nothing-to-say short-circuits — no diagnostic at all.
        guard mode != .off,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.empty, nil) }
        guard !isTrivialUserInput(query) else { return (.empty, nil) }

        let (catalog, groups) = await MainActor.run {
            loadDynamicCatalog(allowedNames: allowedNames)
        }

        // Empty-catalog short-circuit: still emit a diagnostic so verbose
        // eval output tells the operator "the LLM was never called
        // because there are no plugin tools enabled" instead of leaving
        // them guessing.
        guard !catalog.isEmpty else {
            return (
                .empty,
                PreflightDiagnostic(
                    systemPrompt: nil,
                    rawResponse: nil,
                    llmPicks: [],
                    catalogSize: 0,
                    llmError: nil
                )
            )
        }

        // Folder-driven plugin tools. Filtered through `catalog`, so the
        // agent's allowlist + enabled flag + plugin-installed-state are
        // already respected — we only ever inject tools the user could
        // pick manually. Computed once and reused on both the LLM-NONE
        // path and the post-guardrail merge.
        let folderSuggestedNames = await MainActor.run {
            folderInjectedToolNames(catalog: catalog, groups: groups)
        }

        let nameToDesc = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.description) })

        InferenceProgressManager.shared.preflightWillStartAsync()
        defer { InferenceProgressManager.shared.preflightDidFinishAsync() }

        // Pre-rank the catalog by embedding similarity and show the LLM
        // only the top-K — small models (Apple Foundation, 4K window)
        // can't take a 70+ tool dump otherwise. Full catalog still
        // backs `validationCatalog` below so the parser accepts any
        // valid tool name, and the post-pick embedding guardrail
        // gates relevance regardless. `rankCatalog` falls back to the
        // full catalog when the index is unavailable.
        let displayCatalog = await rankCatalog(
            query: query,
            catalog: catalog,
            topK: mode.catalogTopK
        )

        let (llmPicks, rawResponse, systemPrompt, llmError) = await selectTools(
            query: query,
            displayCatalog: displayCatalog,
            validationCatalog: catalog,
            groups: groups,
            cap: mode.toolCap,
            llm: llm
        )
        let diagnostic = PreflightDiagnostic(
            systemPrompt: systemPrompt,
            rawResponse: rawResponse,
            llmPicks: llmPicks,
            catalogSize: displayCatalog.count,
            llmError: llmError
        )

        // Skip the guardrail when the LLM picked nothing — there's
        // nothing to guard, and we'd otherwise pay an embed call to
        // filter an empty list. The folder-suggested set carries the
        // turn on its own when the LLM abstains.
        let llmGuardedNames: [String]
        if llmPicks.isEmpty {
            llmGuardedNames = []
        } else {
            llmGuardedNames = await applyEmbeddingGuardrail(
                query: query,
                picks: llmPicks,
                nameToDesc: nameToDesc,
                embedder: embedder
            )
        }

        // Merge LLM picks (post-guardrail) with folder-suggested tools.
        // Order: LLM picks first (they reflect user intent for THIS
        // turn), then folder tools that weren't already picked. Dedupe
        // so a tool that the LLM happened to surface from the same
        // plugin doesn't appear twice. When the LLM picked nothing the
        // folder names carry through unchanged.
        let selectedNames = mergeUnique(llmGuardedNames, folderSuggestedNames)
        guard !selectedNames.isEmpty else { return (.empty, diagnostic) }

        let result = await buildPreflightResult(
            selectedNames: selectedNames,
            nameToDesc: nameToDesc,
            query: query
        )
        return (result, diagnostic)
    }

    // MARK: Folder Injection

    /// Resolve the live `FolderContext` (if any) into the set of dynamic
    /// tool names that should be unconditionally merged into preflight
    /// this turn. The returned names are guaranteed to be a subset of
    /// `catalog`, so the agent's allowlist + the tool's enabled flag are
    /// respected for free.
    ///
    /// Returns `[]` when:
    /// - no folder context is active
    /// - the folder has no files matching `FolderPluginHints.watchedExtensions`
    /// - the matching plugins aren't installed
    /// - the matching plugins' tools aren't in the supplied catalog
    ///   (e.g. the agent's capability picker has them disabled)
    @MainActor
    private static func folderInjectedToolNames(
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String]
    ) -> [String] {
        guard let folderContext = FolderContextService.shared.currentContext else {
            return []
        }
        let installed = Set(PluginManager.shared.plugins.map { $0.plugin.id })
        return folderInjectedToolNames(
            catalog: catalog,
            groups: groups,
            folderExtensions: folderContext.detectedFileExtensions,
            installedPluginIds: installed
        )
    }

    /// Pure form. Same return contract as the singleton-reading variant
    /// above, but the folder extensions + installed-plugin set are
    /// passed in. Lets unit tests assert the lookup + ordering rules
    /// without standing up `FolderContextService` or `PluginManager`.
    static func folderInjectedToolNames(
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        folderExtensions: Set<String>,
        installedPluginIds: Set<String>
    ) -> [String] {
        let suggested = Set(
            FolderPluginHints.suggestedPluginIds(
                extensions: folderExtensions,
                installedPluginIds: installedPluginIds
            )
        )
        guard !suggested.isEmpty else { return [] }

        return
            catalog
            .compactMap { entry -> String? in
                guard let group = groups[entry.name],
                    suggested.contains(group)
                else { return nil }
                return entry.name
            }
            .sorted()
    }

    /// Append `additions` to `base`, preserving order and dropping any
    /// names already present in `base`. Used to merge LLM picks with
    /// folder-suggested tool names without disturbing the LLM-pick order
    /// (which is what the agent surface ranks against for "this turn's
    /// intent").
    private static func mergeUnique(_ base: [String], _ additions: [String]) -> [String] {
        guard !additions.isEmpty else { return base }
        var seen = Set(base)
        var result = base
        result.reserveCapacity(base.count + additions.count)
        for name in additions where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    /// Resolve `selectedNames` to a fully-populated `PreflightResult` —
    /// `Tool` specs + capability items + plugin companions. Single
    /// MainActor hop; pulled out of `searchWithDiagnostic` so the LLM
    /// path and the folder-only path share the same construction code.
    private static func buildPreflightResult(
        selectedNames: [String],
        nameToDesc: [String: String],
        query: String
    ) async -> PreflightResult {
        let (toolSpecs, items, companions) = await MainActor.run {
            let specs = ToolRegistry.shared.specs(forTools: selectedNames)
            let items = selectedNames.compactMap { name -> PreflightCapabilityItem? in
                guard let desc = nameToDesc[name] else { return nil }
                return .init(type: .tool, name: name, description: desc)
            }
            // Phase 2: derive plugin companions (sibling tools + plugin
            // skill) for any pick that belongs to a plugin/provider. The
            // model pulls these in on demand via `capabilities_load`,
            // so they don't inflate the schema this turn.
            let companions = PreflightCompanions.derive(
                selectedNames: selectedNames,
                query: query
            )
            return (specs, items, companions)
        }

        logger.info(
            "Pre-flight loaded \(toolSpecs.count) tools, \(companions.count) companion plugin(s)"
        )
        return PreflightResult(toolSpecs: toolSpecs, items: items, companions: companions)
    }

    /// Pre-rank `catalog` by embedding similarity to the query and keep
    /// the top `topK`. The LLM-visible catalog gets compressed from
    /// "every dynamic tool" to "the K most semantically relevant",
    /// which is the only way Apple Foundation Models (4K context) can
    /// preflight against a real plugin install — a 77-tool dump
    /// tokenises to ~4.3K and overflows the window before the LLM
    /// sees the prompt.
    ///
    /// Implementation reuses `ToolSearchService` (already maintained
    /// for the `capabilities_search` tool path) so we don't pay a
    /// second embed cost per call. Threshold zero so the LLM is the
    /// floor — embedding rank gates *order*, not *eligibility*.
    /// Returns the full catalog when:
    ///   - `topK` is zero or negative (legacy / disabled)
    ///   - the catalog already fits (no point ranking N down to N)
    ///
    /// When the index is unavailable (still warming up after launch,
    /// embedder threw, `reverseIdMap` not yet rehydrated, etc.) we
    /// fall back to a deterministic top-K **alphabetical slice** of
    /// the catalog — emphatically NOT the full catalog. The previous
    /// "fall back to full catalog" behaviour silently overflowed
    /// Apple Foundation Models' 4K window, throwing every preflight
    /// call until the circuit breaker opened and stuck. A truncated
    /// alphabetical slice gives the model SOMETHING to choose from
    /// while the index settles; semantic quality recovers as soon
    /// as `ToolSearchService.rebuildIndex()` finishes.
    static func rankCatalog(
        query: String,
        catalog: [ToolRegistry.ToolEntry],
        topK: Int
    ) async -> [ToolRegistry.ToolEntry] {
        guard topK > 0, catalog.count > topK else { return catalog }

        // Hybrid (BM25 + embed via RRF) with `minFusedScore: 0.0` —
        // catalog narrowing is rank-only, never an acceptance gate.
        // The LLM is the actual filter at this stage; we just want
        // the catalog ordered by relevance before truncation.
        let hits = await ToolSearchService.shared.searchHybrid(
            query: query,
            topK: topK,
            minFusedScore: 0.0
        )
        guard !hits.isEmpty else {
            let fallback = safeFallbackSlice(catalog: catalog, topK: topK)
            let sliceNames = fallback.map(\.name)
            logger.notice(
                "rankCatalog fallback: query=\(query, privacy: .private(mask: .hash)) catalogSize=\(catalog.count) topK=\(topK) sliceNames=\(sliceNames.joined(separator: ","), privacy: .public) reason=empty-hits"
            )
            return fallback
        }

        // Map ranked names back to the input catalog entries (preserves
        // each entry's parameters / enabled state untouched). Keep
        // search-score order so the LLM sees the strongest match first.
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
        var ranked: [ToolRegistry.ToolEntry] = []
        ranked.reserveCapacity(min(topK, hits.count))
        var seen: Set<String> = []
        for hit in hits {
            guard let entry = byName[hit.entry.name],
                seen.insert(entry.name).inserted
            else { continue }
            ranked.append(entry)
            if ranked.count >= topK { break }
        }
        // Last-resort safety net: same reasoning as the empty-hits
        // branch above — never return a catalog larger than `topK`,
        // even when the index hits don't map back to live entries
        // (stale index, MCP re-registration race, etc.).
        if ranked.isEmpty {
            let fallback = safeFallbackSlice(catalog: catalog, topK: topK)
            let sliceNames = fallback.map(\.name)
            logger.notice(
                "rankCatalog fallback: query=\(query, privacy: .private(mask: .hash)) catalogSize=\(catalog.count) topK=\(topK) sliceNames=\(sliceNames.joined(separator: ","), privacy: .public) reason=no-mappable-hits"
            )
            return fallback
        }
        return ranked
    }

    /// Deterministic top-K slice used when the embedding index can't
    /// rank. Sorts by name to keep the slice stable across calls so
    /// preflight isn't randomly seeing different tool subsets per
    /// query while the index warms up.
    private static func safeFallbackSlice(
        catalog: [ToolRegistry.ToolEntry],
        topK: Int
    ) -> [ToolRegistry.ToolEntry] {
        Array(catalog.sorted { $0.name < $1.name }.prefix(topK))
    }

    /// Snapshot the dynamic-tool catalog and its `tool → group` map from the
    /// registry, sorted by group so `formatCatalog` can emit deterministic
    /// section order. Must run on the main actor.
    ///
    /// When `allowedNames` is non-nil, only tools in that set survive — the
    /// user's enabled allowlist from the agent capability picker scopes the
    /// catalog so Auto-discover never sees a tool the user has disabled.
    /// `nil` returns the full dynamic registry (legacy behaviour for callers
    /// that don't have an agent context).
    @MainActor
    private static func loadDynamicCatalog(
        allowedNames: Set<String>? = nil
    ) -> (catalog: [ToolRegistry.ToolEntry], groups: [String: String]) {
        var tools = ToolRegistry.shared.listDynamicTools()
        if let allowedNames {
            tools = tools.filter { allowedNames.contains($0.name) }
        }
        let groupMap = Dictionary(
            uniqueKeysWithValues: tools.compactMap { tool in
                ToolRegistry.shared.groupName(for: tool.name).map { (tool.name, $0) }
            }
        )
        let sorted = tools.sorted { (groupMap[$0.name] ?? "") < (groupMap[$1.name] ?? "") }
        return (sorted, groupMap)
    }

    // MARK: LLM Tool Selection

    /// Default production LLM bridge — kept as a typed closure so the
    /// signature matches `LLMGenerator` and tests can swap it without
    /// touching `CoreModelService`. Factored as a factory so the closure
    /// can capture the per-request chat model and forward it as
    /// `CoreModelService.generate`'s `fallbackModel:`. See GitHub issue
    /// #823 for why preflight needs the fallback.
    private static func defaultLLM(fallbackModel: String?) -> LLMGenerator {
        { prompt, systemPrompt in
            try await CoreModelService.shared.generate(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: 0.0,
                maxTokens: 256,
                timeout: selectionTimeout,
                fallbackModel: fallbackModel
            )
        }
    }

    /// Default production embedder. The internal `search` seam takes
    /// `Embedder?` so tests can pass `nil` to disable the guardrail; in
    /// production the embedder is always wired and degrades gracefully on
    /// throw inside `applyEmbeddingGuardrail`.
    private static let defaultEmbedder: Embedder = { texts in
        try await EmbeddingService.shared.embed(texts: texts)
    }

    /// Returns picks + the raw LLM response + the exact system prompt sent
    /// + a string description of any LLM error. The raw text, prompt, and
    /// error feed `PreflightDiagnostic` for the eval path; the chat path
    /// discards them. `rawResponse == nil` means the LLM call threw —
    /// `error` then carries the reason.
    ///
    /// `displayCatalog` is what the LLM sees in the prompt (post-rerank,
    /// usually 12 tools). `validationCatalog` is the full dynamic
    /// registry — we parse picks against the full set so the model can
    /// reference a tool by name even if rerank didn't surface it
    /// (small models often know popular tool names from training and
    /// fill in `browser_navigate` even when it wasn't in the top-K).
    /// The post-pick embedding guardrail still gates relevance, so
    /// false-positive picks from outside the displayed window get
    /// dropped before reaching the agent.
    private static func selectTools(
        query: String,
        displayCatalog: [ToolRegistry.ToolEntry],
        validationCatalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        cap: Int,
        llm: LLMGenerator
    ) async -> (picks: [String], rawResponse: String?, systemPrompt: String, error: String?) {
        // Prompt design — three deliberate shifts that landed when we
        // started running the eval suite against Apple Foundation:
        //   1. Lead with a one-sentence "what is the user trying to
        //      do?" scaffold so small models leave pure pattern-match
        //      mode before they pick.
        //   2. Three positive examples covering distinct shapes
        //      (lookup / browser / sandbox) + two NONE examples —
        //      keeps the abstain signal without letting it dominate.
        //   3. Dropped "Prefer NONE over guessing" — the examples
        //      teach the abstain boundary better than a rule does.
        let systemPrompt = """
            You are a tool selector for a chat agent.

            Step 1 — In one short sentence, name what the user is trying to do.
            Step 2 — Pick the tool whose purpose serves that intent. Prefer fewer; up to \(cap).
            Step 3 — Output one pick per line as: tool_name | one short reason
                     The bare tool name on its own line is also accepted.
                     Do not wrap the name in angle brackets, backticks, or quotes.
                     If nothing in the catalog fits, output exactly: NONE

            Examples
            --------
            "what's the weather in Tokyo?"      -> get_weather | current weather for a city
            "check my orders on amazon"         -> browser_navigate | open the orders page in a browser
            "convert this csv to json"          -> sandbox_exec | run a script to convert formats
            "thanks, that's perfect"            -> NONE
            "write me a haiku about cats"       -> NONE

            Rules
            -----
            - Use exact tool names from the `tool:` lines below.
            - Skip the bracketed `[provider]` labels — those are NOT tools.
            - Pick a tool when its purpose plausibly serves the user's intent, even if the description doesn't lexically match.

            Catalog
            -------
            \(formatCatalog(displayCatalog, groups: groups))
            """

        do {
            let response = try await llm(query, systemPrompt)
            let picks = parseJustifiedPicks(
                from: response,
                catalog: validationCatalog,
                cap: cap
            )
            return (picks, response, systemPrompt, nil)
        } catch {
            // Log `localizedDescription` rather than the raw error
            // so the message is human-readable in Console; bump the
            // log to .notice for the unavailable-with-no-fallback
            // case so #823-style reports surface without enabling
            // debug logs.
            if let coreErr = error as? CoreModelError, case .modelUnavailable = coreErr {
                logger.notice(
                    "Pre-flight tool selection skipped: \(coreErr.localizedDescription) — no chat-model fallback was supplied; plugin tools will not be auto-selected this turn"
                )
            } else {
                logger.info("Pre-flight tool selection skipped: \(error.localizedDescription)")
            }
            return ([], nil, systemPrompt, String(describing: error))
        }
    }

    // MARK: Catalog Formatting

    /// Render `catalog` as a model-friendly listing. Each tool line includes
    /// the provider tag (when present) and a `params:` line listing the
    /// top-level parameter property names — both add cheap signal beyond
    /// the bare name + description so the model can match user phrasing
    /// like "play jazz on **spotify**" or "send to **channel** X".
    /// (An earlier `# group / - tool:` format caused models to pick group
    /// names like `osaurus.pptx` as if they were tools, which is why each
    /// tool is still explicitly prefixed with `tool:`.)
    private static func formatCatalog(
        _ catalog: [ToolRegistry.ToolEntry],
        groups: [String: String]
    ) -> String {
        // Single pass: bucket by group while preserving first-seen order so
        // the rendered listing is deterministic across runs (KV-cache stable).
        var sectionOrder: [String] = []
        var bySection: [String: [ToolRegistry.ToolEntry]] = [:]
        for entry in catalog {
            let group = groups[entry.name] ?? ""
            if bySection[group] == nil {
                sectionOrder.append(group)
                bySection[group] = []
            }
            bySection[group]?.append(entry)
        }

        return sectionOrder.map { group in
            let header = group.isEmpty ? "" : "[provider: \(group)]\n"
            let providerTag = group.isEmpty ? "" : "  [\(group)]"
            let lines = (bySection[group] ?? []).map { entry -> String in
                var line = "tool: \(entry.name)\(providerTag) — \(entry.description)"
                let paramKeys = parameterKeyNames(entry.parameters)
                if !paramKeys.isEmpty {
                    line += "\n  params: \(paramKeys.joined(separator: ", "))"
                }
                return line
            }
            return header + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Extract the top-level property names from an OpenAI-style JSON Schema.
    /// Mirrors the keys that `ToolSearchService.extractParameterText` folds
    /// into the search index, so the LLM-visible catalog and the embedding
    /// index agree on what signal a parameter contributes.
    static func parameterKeyNames(_ params: JSONValue?) -> [String] {
        guard case .object(let schema) = params,
            case .object(let properties) = schema["properties"]
        else { return [] }
        // Keys come from a `[String: JSONValue]` (unordered); sort so the
        // formatted catalog is byte-stable across runs and KV-cache friendly.
        return properties.keys.sorted()
    }

    // MARK: Response Parsing

    /// Parse the model's response into canonical tool names. Accepts two
    /// shapes per line: `<name> | <reason>` (preferred — easy to read in
    /// logs) and bare `<name>` (small models routinely forget the pipe).
    /// The anti-padding contract that justifications used to enforce is
    /// now carried by `applyEmbeddingGuardrail`: every pick gets gated
    /// against the query embedding, so a "padding" pick whose semantics
    /// don't match the request gets dropped post-parse anyway.
    ///
    /// A standalone `NONE` line (case-insensitive) **abstains** when no
    /// valid pick has been collected yet, and **terminates** parsing
    /// (preserving prior picks) otherwise — this salvages the common
    /// failure mode where a model emits a real pick followed by a stray
    /// `NONE`. `[provider]` group tokens are silently ignored (the
    /// previous implementation expanded them to every tool in the group,
    /// which was the single biggest over-selection vector). Output is
    /// capped at `cap`.
    static func parseJustifiedPicks(
        from response: String,
        catalog: [ToolRegistry.ToolEntry],
        cap: Int
    ) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Pre-flight: raw LLM response: \(trimmed, privacy: .private(mask: .hash))")
        guard !trimmed.isEmpty else { return [] }

        let validNames = Dictionary(
            uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0.name) }
        )

        var selected: [String] = []
        var seen: Set<String> = []

        for rawLine in trimmed.components(separatedBy: "\n") {
            guard selected.count < cap else { break }
            // Strip bullets + line-level wrapping (`<name | reason>`)
            // BEFORE the `|` split so Apple Foundation's most common
            // output shape unwraps cleanly.
            let line = stripWrapping(
                rawLine
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[-•*]\\s*", with: "", options: .regularExpression)
            )
            guard !line.isEmpty else { continue }
            // `NONE` is the abstain signal when emitted alone (selected
            // is still empty) and a "no more picks" terminator
            // otherwise — salvages the common `pick\nNONE` failure mode.
            if line.uppercased() == "NONE" { break }

            // The pipe is just diagnostic now — the post-pick embedding
            // guardrail enforces relevance, so bare `<name>` is fine.
            let nameToken =
                line
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = canonicalize(nameToken: nameToken, validNames: validNames),
                seen.insert(canonical).inserted
            else { continue }
            selected.append(canonical)
        }

        logger.info("Pre-flight: LLM selected \(selected.count) tools: \(selected.joined(separator: ", "))")
        return selected
    }

    /// Resolve a parsed name token to a canonical tool name, handling
    /// every "model echoed the catalog formatting" variant we've
    /// observed in the wild. Returns `nil` when the token is a
    /// `[provider]` group label (silently dropped) or doesn't resolve
    /// to a known tool.
    private static func canonicalize(
        nameToken: String,
        validNames: [String: String]
    ) -> String? {
        var name = nameToken
        // `[provider]` group labels: must reject BEFORE the trailing-
        // bracket strip below, or `[spotify]` collapses to an empty
        // name and falls through to the lookup.
        if name.hasPrefix("[") { return nil }
        // Trailing `[provider]` annotation echoed from the catalog
        // (`play [spotify]` → `play`).
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        // Leading `tool:` prefix echoed from the catalog
        // (`tool: play` → `play`).
        if name.lowercased().hasPrefix("tool:") {
            name = String(name.dropFirst("tool:".count)).trimmingCharacters(in: .whitespaces)
        }
        // Per-name wrapping — catches `<name>` without a reason,
        // which the line-level strip in the caller can't see.
        name = stripWrapping(name)
        return validNames[name.lowercased()]
    }

    /// Strip a single layer of common wrapping characters around a tool
    /// name token. Small models echo the prompt's placeholder syntax —
    /// Apple Foundation almost always wraps in `<...>`, others use
    /// backticks or quotes. One layer only; doubly-wrapped tokens
    /// aren't a real failure mode.
    static func stripWrapping(_ name: String) -> String {
        let pairs: [(open: Character, close: Character)] = [
            ("<", ">"), ("`", "`"), ("\"", "\""), ("'", "'"),
        ]
        for pair in pairs where name.first == pair.open && name.last == pair.close && name.count >= 2 {
            return String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    // MARK: Embedding Guardrail

    /// Drop picks whose cosine similarity to the query is below
    /// `guardrailMinSimilarity`. This is intentionally a *floor on individual
    /// picks*, not a candidate gate — the LLM still chooses the pool, so a
    /// recall failure of the embedder cannot remove a true positive. If the
    /// embedder is unavailable or throws, all picks pass through unchanged
    /// (graceful degrade is the whole point). Pass `embedder: nil` to disable
    /// the guardrail entirely.
    static func applyEmbeddingGuardrail(
        query: String,
        picks: [String],
        nameToDesc: [String: String],
        embedder: Embedder?
    ) async -> [String] {
        guard let embedder, !picks.isEmpty else { return picks }

        let pickTexts = picks.map { name -> String in
            let desc = nameToDesc[name] ?? ""
            return desc.isEmpty ? name : "\(name) \(desc)"
        }

        do {
            let vectors = try await embedder([query] + pickTexts)
            guard vectors.count == picks.count + 1 else {
                logger.info("Pre-flight guardrail: unexpected embedding count, skipping")
                return picks
            }
            let queryVec = vectors[0]
            var kept: [String] = []
            kept.reserveCapacity(picks.count)
            for (i, name) in picks.enumerated() {
                let sim = cosineSimilarity(queryVec, vectors[i + 1])
                if sim >= guardrailMinSimilarity {
                    kept.append(name)
                } else {
                    logger.info(
                        "Pre-flight guardrail: dropped \(name) (sim=\(String(format: "%.3f", sim)))"
                    )
                }
            }
            return kept
        } catch {
            logger.info("Pre-flight guardrail: embedder unavailable, keeping all picks (\(error))")
            return picks
        }
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0 ..< n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

}

// MARK: - Plugin Creator Gate

/// Pure decision logic + formatting for the "Sandbox Plugin Creator" backstop.
///
/// Extracted from `SystemPromptComposer` so the gate can be unit-tested
/// without fighting `ToolRegistry.shared` / `SkillManager.shared` / `AgentManager.shared`.
/// The composer snapshots all inputs at the start of a turn, then calls
/// `shouldInject(_:)` with plain booleans — no actor hops, no globals.
public enum PluginCreatorGate {
    /// Every input that decides whether to inject the skill this turn.
    /// Agent-side flags ride on the composer's `AgentConfigSnapshot`,
    /// captured once at the start of compose so the gate sees the same
    /// view of the world the rest of the pipeline does.
    public struct Inputs: Equatable, Sendable {
        public var effectiveToolsOff: Bool
        public var sandboxAvailable: Bool
        public var canCreatePlugins: Bool
        public var dynamicCatalogIsEmpty: Bool
        public var hasResolvedDynamicTools: Bool
        public var skillEnabled: Bool

        public init(
            effectiveToolsOff: Bool,
            sandboxAvailable: Bool,
            canCreatePlugins: Bool,
            dynamicCatalogIsEmpty: Bool,
            hasResolvedDynamicTools: Bool,
            skillEnabled: Bool
        ) {
            self.effectiveToolsOff = effectiveToolsOff
            self.sandboxAvailable = sandboxAvailable
            self.canCreatePlugins = canCreatePlugins
            self.dynamicCatalogIsEmpty = dynamicCatalogIsEmpty
            self.hasResolvedDynamicTools = hasResolvedDynamicTools
            self.skillEnabled = skillEnabled
        }
    }

    /// Pure gate. Returns true iff every condition holds:
    /// - tools aren't globally off
    /// - sandbox is available (either already active or autonomous-enabled)
    /// - the agent is allowed to create plugins
    /// - the user has no dynamic tools installed AND this turn didn't resolve any
    /// - the user hasn't disabled the built-in skill
    public static func shouldInject(_ inputs: Inputs) -> Bool {
        !inputs.effectiveToolsOff
            && inputs.sandboxAvailable
            && inputs.canCreatePlugins
            && inputs.dynamicCatalogIsEmpty
            && !inputs.hasResolvedDynamicTools
            && inputs.skillEnabled
    }

    /// Pure formatter for the injected section.
    public static func section(skillName: String, instructions: String) -> String {
        """
        ## No existing tools match this request

        You can create new tools by writing a sandbox plugin.
        Follow the instructions below.

        ## Skill: \(skillName)
        \(instructions)
        """
    }
}
