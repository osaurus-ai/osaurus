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

    static let empty = PreflightResult(toolSpecs: [], items: [])
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
        guard mode != .off,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .empty }

        let (catalog, groups) = await MainActor.run { loadDynamicCatalog() }
        guard !catalog.isEmpty else { return .empty }

        InferenceProgressManager.shared.preflightWillStartAsync()
        defer { InferenceProgressManager.shared.preflightDidFinishAsync() }

        let llmPicks = await selectTools(
            query: query,
            catalog: catalog,
            groups: groups,
            cap: mode.toolCap,
            llm: llm
        )
        guard !llmPicks.isEmpty else { return .empty }

        let nameToDesc = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.description) })
        let selectedNames = await applyEmbeddingGuardrail(
            query: query,
            picks: llmPicks,
            nameToDesc: nameToDesc,
            embedder: embedder
        )
        guard !selectedNames.isEmpty else { return .empty }

        let (toolSpecs, items) = await MainActor.run {
            let specs = ToolRegistry.shared.specs(forTools: selectedNames)
            let items = selectedNames.compactMap { name -> PreflightCapabilityItem? in
                guard let desc = nameToDesc[name] else { return nil }
                return .init(type: .tool, name: name, description: desc)
            }
            return (specs, items)
        }

        logger.info("Pre-flight loaded \(toolSpecs.count) tools")
        return PreflightResult(toolSpecs: toolSpecs, items: items)
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

    private static func selectTools(
        query: String,
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        cap: Int,
        llm: LLMGenerator
    ) async -> [String] {
        let systemPrompt = """
            You are a tool selector. Pick the FEWEST tools needed to satisfy the user's request.

            Output format: one pick per line as
                <tool_name> | <one short reason this tool matches the request>
            If nothing in the catalog clearly matches, output exactly:
                NONE

            Hard rules:
            - \(cap) is a HARD CEILING, not a target. Prefer fewer. Prefer NONE over guessing.
            - Only pick a tool when its description (or params) clearly matches the request. Do not pad.
            - If the message is small talk, a status check, a thank-you, or a continuation that needs no new external action, output NONE.
            - Pick specific tools only — never the `[provider]` labels.
            - Use exact tool names from the `tool:` lines below; nothing else.

            Example input: "what's the weather in Tokyo?"
            Example output:
            get_weather | fetches current weather for a city

            Example input: "thanks, that's perfect"
            Example output:
            NONE

            \(formatCatalog(catalog, groups: groups))
            """

        do {
            let response = try await llm(query, systemPrompt)
            return parseJustifiedPicks(from: response, catalog: catalog, cap: cap)
        } catch {
            logger.info("Pre-flight tool selection skipped: \(error)")
            return []
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

    /// Parse the model's per-line `<name> | <reason>` response into canonical
    /// tool names. Picks without a reason are dropped — the justification
    /// requirement is the anti-padding mechanism. A standalone `NONE` line
    /// (case-insensitive) **abstains** when no valid pick has been collected
    /// yet, and **terminates** parsing (preserving prior picks) otherwise —
    /// this salvages the common failure mode where a model emits a real pick
    /// followed by a stray `NONE`. `[provider]` group tokens are silently
    /// ignored (the previous implementation expanded them to every tool in
    /// the group, which was the single biggest over-selection vector).
    /// Output is capped at `cap`.
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
            let line =
                rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[-•*]\\s*", with: "", options: .regularExpression)
            guard !line.isEmpty else { continue }
            // `NONE` is the abstain signal when emitted alone (selected is
            // still empty) and a "no more picks" terminator otherwise. The
            // common failure mode it salvages: a valid pick followed by a
            // stray `NONE` line. See the docstring for the full rationale.
            if line.uppercased() == "NONE" { break }

            // Required `name | reason` shape. No `|` ⇒ no justification ⇒
            // drop. This is the anti-padding contract.
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let reason = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { continue }

            var name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // Reject bare `[provider]`-style group tokens outright. Must come
            // before the trailing-bracket strip below or `[spotify]` would
            // collapse to an empty name and silently fall through to the
            // canonical-name check.
            if name.hasPrefix("[") { continue }
            // Strip a trailing `[provider]` annotation if the model echoed
            // the catalog formatting back at us (`play [spotify]` → `play`).
            if let bracket = name.firstIndex(of: "[") {
                name = String(name[..<bracket]).trimmingCharacters(in: .whitespaces)
            }

            guard let canonical = validNames[name.lowercased()] else { continue }
            if seen.insert(canonical).inserted {
                selected.append(canonical)
            }
        }

        logger.info("Pre-flight: LLM selected \(selected.count) tools: \(selected.joined(separator: ", "))")
        return selected
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
