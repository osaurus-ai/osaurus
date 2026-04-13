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
        case .off: return "Disable pre-flight search. Only explicit tool calls are used."
        case .narrow: return "Minimal tool injection. Up to 3 tools loaded."
        case .balanced: return "Default. Up to 8 relevant tools loaded."
        case .wide: return "Aggressive search. Up to 15 tools loaded, may increase prompt size."
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
    let contextSnippet: String
    let items: [PreflightCapabilityItem]

    static let empty = PreflightResult(toolSpecs: [], contextSnippet: "", items: [])
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
            query: query, topK: topK.methods, threshold: threshold
        )
        async let toolHits = ToolSearchService.shared.search(
            query: query, topK: topK.tools, threshold: threshold
        )
        async let skillHits = SkillSearchService.shared.search(
            query: query, topK: topK.skills, threshold: threshold
        )

        return CapabilitySearchResults(
            methods: (await methodHits).filter { $0.searchScore >= threshold },
            tools: (await toolHits).filter { $0.searchScore >= threshold },
            skills: (await skillHits).filter { $0.searchScore >= threshold }
        )
    }

    static func canCreatePlugins() async -> Bool {
        await MainActor.run {
            let agentId = AgentManager.shared.activeAgent.id
            guard let config = AgentManager.shared.effectiveAutonomousExec(for: agentId) else { return false }
            return config.enabled && config.pluginCreate
        }
    }
}

// MARK: - Preflight Tool Selection

enum PreflightCapabilitySearch {

    private static let selectionTimeout: TimeInterval = 8

    // MARK: Search

    static func search(query: String, mode: PreflightSearchMode = .balanced) async -> PreflightResult {
        guard mode != .off,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .empty }

        let (catalog, groups) = await MainActor.run {
            let tools = ToolRegistry.shared.listDynamicTools()
            let groupMap = Dictionary(
                uniqueKeysWithValues: tools.compactMap { tool in
                    ToolRegistry.shared.groupName(for: tool.name).map { (tool.name, $0) }
                }
            )
            let sorted = tools.sorted { (groupMap[$0.name] ?? "") < (groupMap[$1.name] ?? "") }
            return (sorted, groupMap)
        }

        guard !catalog.isEmpty else { return .empty }

        let selectedNames = await selectTools(
            query: query, catalog: catalog, groups: groups, cap: mode.toolCap
        )

        if selectedNames.isEmpty {
            return .empty
        }

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
        return PreflightResult(toolSpecs: toolSpecs, contextSnippet: "", items: items)
    }

    // MARK: LLM Tool Selection

    private static func selectTools(
        query: String,
        catalog: [ToolRegistry.ToolEntry],
        groups: [String: String],
        cap: Int
    ) async -> [String] {
        guard !catalog.isEmpty else { return [] }

        let catalogText = formatCatalog(catalog, groups: groups)
        let systemPrompt = """
            Output ONLY tool names, comma-separated. No explanation.
            Max \(cap). If none relevant: NONE

            Example input: "play some jazz"
            Example output: play,search_songs

            \(catalogText)
            """

        do {
            let response = try await CoreModelService.shared.generate(
                prompt: query,
                systemPrompt: systemPrompt,
                temperature: 0.0,
                maxTokens: 256,
                timeout: selectionTimeout
            )
            return parseToolNames(from: response, catalog: catalog, cap: cap)
        } catch {
            logger.info("Pre-flight tool selection skipped: \(error)")
            return []
        }
    }

    // MARK: Catalog Formatting

    private static func formatCatalog(
        _ catalog: [ToolRegistry.ToolEntry],
        groups: [String: String]
    ) -> String {
        var sections: [(group: String, tools: [ToolRegistry.ToolEntry])] = []
        var currentGroup = ""
        var currentTools: [ToolRegistry.ToolEntry] = []

        for entry in catalog {
            let group = groups[entry.name] ?? ""
            if group != currentGroup {
                if !currentTools.isEmpty { sections.append((currentGroup, currentTools)) }
                currentGroup = group
                currentTools = []
            }
            currentTools.append(entry)
        }
        if !currentTools.isEmpty { sections.append((currentGroup, currentTools)) }

        return sections.map { group, tools in
            let header = group.isEmpty ? "" : "# \(group)\n"
            let lines = tools.map { "- \($0.name): \($0.description)" }
            return header + lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: Response Parsing

    private static func parseToolNames(
        from response: String,
        catalog: [ToolRegistry.ToolEntry],
        cap: Int
    ) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Pre-flight: raw LLM response: \(trimmed)")

        if trimmed.isEmpty || trimmed.uppercased() == "NONE" { return [] }

        let validNames = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name.lowercased(), $0.name) })

        var selected: [String] = []
        var seen: Set<String> = []

        let tokens = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for token in tokens {
            let cleaned = token
                .replacingOccurrences(of: "^[-•*]\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            if let canonical = validNames[cleaned.lowercased()],
               seen.insert(canonical).inserted {
                selected.append(canonical)
            }
        }

        let capped = Array(selected.prefix(cap))
        logger.info("Pre-flight: LLM selected \(capped.count) tools: \(capped.joined(separator: ", "))")
        return capped
    }

    // MARK: Fallback

    private static func sandboxPluginCreatorFallback() async -> PreflightResult {
        guard await CapabilitySearch.canCreatePlugins() else { return .empty }
        let skill = await MainActor.run {
            SkillManager.shared.skill(named: "Sandbox Plugin Creator")
        }
        guard let skill else { return .empty }

        logger.info("Pre-flight: no tools selected, injected Sandbox Plugin Creator skill")
        return PreflightResult(
            toolSpecs: [],
            contextSnippet: """
                ## No existing tools match this request

                You can create new tools by writing a sandbox plugin.
                Follow the instructions below.

                ## Skill: \(skill.name)
                \(skill.instructions)
                """,
            items: [.init(type: .skill, name: skill.name, description: skill.description)]
        )
    }
}
