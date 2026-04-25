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
    var loadedToolNames: Set<String>
    /// Snapshot of always-loaded tool names from the FIRST compose of this
    /// session. On subsequent composes the resolver intersects the live
    /// always-loaded set against this snapshot so a tool that registers
    /// mid-session (e.g. sandbox_exec coming online a few seconds late)
    /// does NOT silently appear in turn 2's schema. Toolsets must stay
    /// stable mid-conversation — changing them breaks prompt caching and
    /// disorients the model. New tools only enter via the explicit
    /// `capabilities_load` path (which writes loadedToolNames).
    /// `nil` means "no snapshot yet" — the next compose will record one.
    var initialAlwaysLoadedNames: Set<String>?
    /// Compact signature of the (executionMode, toolSelectionMode) that
    /// captured this state. The send path compares the live signature on
    /// every turn and invalidates on a flip, so dynamically-loaded tools
    /// from one mode cannot leak into another and an empty manual-mode
    /// preflight cache cannot survive a flip back to auto. `nil` only for
    /// legacy entries created before this field existed.
    var sessionFingerprint: String?

    init(
        initialPreflight: PreflightResult,
        loadedToolNames: Set<String> = [],
        initialAlwaysLoadedNames: Set<String>? = nil,
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
    static let minimumRelevanceScore: Float = 0.7

    static func search(
        query: String,
        topK: (methods: Int, tools: Int, skills: Int)
    ) async -> CapabilitySearchResults {
        let threshold = minimumRelevanceScore
        async let methodHits = MethodSearchService.shared.search(
            query: query,
            topK: topK.methods,
            threshold: threshold
        )
        async let toolHits = ToolSearchService.shared.search(
            query: query,
            topK: topK.tools,
            threshold: threshold
        )
        async let skillHits = SkillSearchService.shared.search(
            query: query,
            topK: topK.skills,
            threshold: threshold
        )

        return CapabilitySearchResults(
            methods: (await methodHits).filter { $0.searchScore >= threshold },
            tools: (await toolHits).filter { $0.searchScore >= threshold },
            skills: (await skillHits).filter { $0.searchScore >= threshold }
        )
    }

    static func canCreatePlugins(agentId: UUID) async -> Bool {
        await MainActor.run {
            guard let config = AgentManager.shared.effectiveAutonomousExec(for: agentId) else { return false }
            return config.enabled && config.pluginCreate
        }
    }
}

// MARK: - Preflight Tool Selection

enum PreflightCapabilitySearch {

    private static let selectionTimeout: TimeInterval = 8

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

    /// Public entry point. `agentId` is reserved for future agent-aware
    /// behavior (e.g. per-agent tool restrictions) so callers don't have to
    /// change when that lands; it is intentionally unused today.
    static func search(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID
    ) async -> PreflightResult {
        await search(query: query, mode: mode, llm: defaultLLM, embedder: defaultEmbedder)
    }

    /// Internal entry point with injectable LLM + embedder seams. Tests call
    /// this directly with canned closures; production goes through
    /// `search(query:mode:agentId:)` which wires the real services.
    static func search(
        query: String,
        mode: PreflightSearchMode,
        llm: LLMGenerator,
        embedder: Embedder?
    ) async -> PreflightResult {
        let (result, _) = await searchWithDiagnostic(
            query: query,
            mode: mode,
            llm: llm,
            embedder: embedder
        )
        return result
    }

    /// Diagnostic-capturing entry point. Wires the production LLM +
    /// embedder so callers (the eval CLI, future scoreboards) get the
    /// exact same one-shot generation contract the chat path uses.
    /// `agentId` is reserved for future per-agent gating, mirroring
    /// `search(query:mode:agentId:)`.
    static func searchWithDiagnostic(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID
    ) async -> (PreflightResult, PreflightDiagnostic?) {
        await searchWithDiagnostic(
            query: query,
            mode: mode,
            llm: defaultLLM,
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
    static func searchWithDiagnostic(
        query: String,
        mode: PreflightSearchMode,
        llm: LLMGenerator,
        embedder: Embedder?
    ) async -> (PreflightResult, PreflightDiagnostic?) {
        // Truly nothing-to-say short-circuits — no diagnostic at all.
        guard mode != .off,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (.empty, nil) }

        let (catalog, groups) = await MainActor.run { loadDynamicCatalog() }
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
        guard !llmPicks.isEmpty else { return (.empty, diagnostic) }

        let nameToDesc = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.description) })
        let selectedNames = await applyEmbeddingGuardrail(
            query: query,
            picks: llmPicks,
            nameToDesc: nameToDesc,
            embedder: embedder
        )
        guard !selectedNames.isEmpty else { return (.empty, diagnostic) }

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
        let result = PreflightResult(toolSpecs: toolSpecs, items: items, companions: companions)
        return (result, diagnostic)
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

        let hits = await ToolSearchService.shared.search(
            query: query,
            topK: topK,
            threshold: 0.0
        )
        guard !hits.isEmpty else {
            logger.notice(
                "rankCatalog: tool index returned no hits (index warming or embedder unavailable) — falling back to alphabetical top \(topK) of \(catalog.count)"
            )
            return safeFallbackSlice(catalog: catalog, topK: topK)
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
        return ranked.isEmpty ? safeFallbackSlice(catalog: catalog, topK: topK) : ranked
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
    @MainActor
    private static func loadDynamicCatalog() -> (catalog: [ToolRegistry.ToolEntry], groups: [String: String]) {
        let tools = ToolRegistry.shared.listDynamicTools()
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
    /// signature matches `LLMGenerator` and so test paths can swap it
    /// without touching `CoreModelService`.
    private static let defaultLLM: LLMGenerator = { prompt, systemPrompt in
        try await CoreModelService.shared.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: 0.0,
            maxTokens: 256,
            timeout: selectionTimeout
        )
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
            // so the message is human-readable in Console — the raw
            // form ("OsaurusCore.CoreModelError.circuitBreakerOpen")
            // hid the actual cause and made misconfigured core
            // models look like an internal bug.
            logger.info("Pre-flight tool selection skipped: \(error.localizedDescription)")
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
        logger.info("Pre-flight: raw LLM response: \(trimmed)")
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

    // MARK: Plugin Creator Skill

    /// Compose the Sandbox Plugin Creator skill section. Returns nil when the
    /// agent does not have plugin creation enabled or the skill is not
    /// installed/enabled. Invoked by `SystemPromptComposer` after tool
    /// resolution so the section is injected uniformly across auto/manual
    /// modes, empty queries, and `preflightSearchMode == .off`.
    static func pluginCreatorSkillSection(for agentId: UUID) async -> String? {
        guard await CapabilitySearch.canCreatePlugins(agentId: agentId) else { return nil }
        let skill = await MainActor.run { SkillManager.shared.skill(named: "Sandbox Plugin Creator") }
        // Honour the user's explicit toggle in the skill catalog. Without
        // this, disabling "Sandbox Plugin Creator" in the UI had no effect
        // on the auto-injection path — the section still landed in every
        // applicable system prompt.
        guard let skill, skill.enabled else { return nil }

        logger.info("Plugin creator: injecting \(skill.name) skill")
        return """
            ## No existing tools match this request

            You can create new tools by writing a sandbox plugin.
            Follow the instructions below.

            ## Skill: \(skill.name)
            \(skill.instructions)
            """
    }
}
