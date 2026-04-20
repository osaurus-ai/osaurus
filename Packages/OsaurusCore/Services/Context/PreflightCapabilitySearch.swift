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
        case .narrow: return 3
        case .balanced: return 8
        case .wide: return 15
        }
    }

    public var helpText: String {
        switch self {
        case .off: return L("Disable pre-flight search. Only explicit tool calls are used.")
        case .narrow: return L("Minimal tool injection. Up to 3 tools loaded.")
        case .balanced: return L("Default. Up to 8 relevant tools loaded.")
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

    // MARK: Search

    static func search(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID
    ) async -> PreflightResult {
        guard mode != .off,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .empty }

        let (catalog, groups) = await MainActor.run { loadDynamicCatalog() }
        guard !catalog.isEmpty else { return .empty }

        InferenceProgressManager.shared.preflightWillStartAsync()
        defer { InferenceProgressManager.shared.preflightDidFinishAsync() }

        let selectedNames = await selectTools(
            query: query,
            catalog: catalog,
            groups: groups,
            cap: mode.toolCap
        )
        guard !selectedNames.isEmpty else { return .empty }

        let (toolSpecs, items) = await MainActor.run {
            let specs = ToolRegistry.shared.specs(forTools: selectedNames)
            let nameToDesc = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.description) })
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

    private static func selectTools(
        query: String,
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        cap: Int
    ) async -> [String] {
        let systemPrompt = """
            Output ONLY tool names from the `tool:` lines below, comma-separated. No explanation.
            Max \(cap). If none relevant: NONE
            Do NOT output group/provider names (the `[provider]` headers). Pick the specific tools.

            Example input: "play some jazz"
            Example output: play,search_songs

            \(formatCatalog(catalog, groups: groups))
            """

        do {
            let response = try await CoreModelService.shared.generate(
                prompt: query,
                systemPrompt: systemPrompt,
                temperature: 0.0,
                maxTokens: 256,
                timeout: selectionTimeout
            )
            return parseToolNames(from: response, catalog: catalog, groups: groups, cap: cap)
        } catch {
            logger.info("Pre-flight tool selection skipped: \(error)")
            return []
        }
    }

    // MARK: Catalog Formatting

    /// Render `catalog` as a model-friendly listing. Group headers are
    /// labeled `[provider: ...]` and each tool line is prefixed with `tool:`
    /// so the model can clearly tell apart pickable items from section
    /// headers. (An earlier `# group / - tool:` format caused models to
    /// pick group names like `osaurus.pptx` as if they were tools.)
    private static func formatCatalog(
        _ catalog: [ToolRegistry.ToolEntry],
        groups: [String: String]
    ) -> String {
        let bySection = Dictionary(grouping: catalog) { groups[$0.name] ?? "" }

        // Preserve first-seen order rather than dictionary order so the
        // listing stays deterministic across runs.
        var sectionOrder: [String] = []
        var seenSections: Set<String> = []
        for entry in catalog {
            let g = groups[entry.name] ?? ""
            if seenSections.insert(g).inserted { sectionOrder.append(g) }
        }

        return sectionOrder.map { group in
            let header = group.isEmpty ? "" : "[provider: \(group)]\n"
            let lines = (bySection[group] ?? []).map {
                "tool: \($0.name) — \($0.description)"
            }
            return header + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Response Parsing

    /// Parse the model's comma-/newline-separated response into canonical
    /// tool names from `catalog`. If the model returns a `[provider]` group
    /// label instead of individual tool names (a common failure mode), the
    /// group is expanded to every tool it owns, then the combined list is
    /// capped.
    private static func parseToolNames(
        from response: String,
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        cap: Int
    ) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Pre-flight: raw LLM response: \(trimmed)")
        guard !trimmed.isEmpty, trimmed.uppercased() != "NONE" else { return [] }

        let validNames = Dictionary(
            uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0.name) }
        )
        let groupExpansion = Dictionary(grouping: catalog) {
            (groups[$0.name] ?? "").lowercased()
        }
        .filter { !$0.key.isEmpty }
        .mapValues { $0.map(\.name) }

        var selected: [String] = []
        var seen: Set<String> = []

        for raw in trimmed.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let key =
                raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[-•*]\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !key.isEmpty, selected.count < cap else { continue }

            if let canonical = validNames[key], seen.insert(canonical).inserted {
                selected.append(canonical)
            } else if let toolsInGroup = groupExpansion[key] {
                for name in toolsInGroup where selected.count < cap && seen.insert(name).inserted {
                    selected.append(name)
                }
            }
        }

        logger.info("Pre-flight: LLM selected \(selected.count) tools: \(selected.joined(separator: ", "))")
        return selected
    }

    // MARK: Plugin Creator Fallback

    /// Compose the Sandbox Plugin Creator skill section. Returns nil when the
    /// agent does not have plugin creation enabled or the skill is not
    /// installed. Invoked by `SystemPromptComposer` after tool resolution so
    /// the section is injected uniformly across auto/manual modes, empty
    /// queries, and `preflightSearchMode == .off`.
    static func pluginCreatorSkillSection(for agentId: UUID) async -> String? {
        guard await CapabilitySearch.canCreatePlugins(agentId: agentId) else { return nil }
        let skill = await MainActor.run { SkillManager.shared.skill(named: "Sandbox Plugin Creator") }
        guard let skill else { return nil }

        logger.info("Plugin creator: no dynamic tools matched, injecting \(skill.name) skill")
        return """
            ## No existing tools match this request

            You can create new tools by writing a sandbox plugin.
            Follow the instructions below.

            ## Skill: \(skill.name)
            \(skill.instructions)
            """
    }
}
