//
//  PreflightCapabilitySearch.swift
//  osaurus
//
//  Runs RAG across methods, tools, and skills before the agent loop starts.
//  Returns tool specs to merge into the active tool set and context snippets
//  to inject into the system prompt.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "PreflightSearch")

public enum PreflightSearchMode: String, Codable, CaseIterable, Sendable {
    case off
    case narrow
    case balanced
    case wide

    var topKValues: (methods: Int, tools: Int, skills: Int) {
        switch self {
        case .off: return (0, 0, 0)
        case .narrow: return (1, 2, 0)
        case .balanced: return (3, 5, 1)
        case .wide: return (5, 8, 2)
        }
    }

    public var helpText: String {
        switch self {
        case .off: return "Disable pre-flight search. Only explicit tool calls are used."
        case .narrow: return "Minimal context injection. Fewer methods, tools, and skills loaded."
        case .balanced: return "Default. Loads a moderate set of relevant capabilities."
        case .wide: return "Aggressive search. More context loaded, may increase prompt size."
        }
    }
}

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
}

enum PreflightCapabilitySearch {

    private static let searchTermExtractionPrompt = """
        Given a user's request, identify what tools or capabilities would be needed to accomplish it. \
        Output 3-5 short capability descriptions, one per line. \
        Focus on the type of action or tool required, not the subject matter of the request. \
        No numbering, no explanations, no extra text.
        """

    private static let extractionTimeout: TimeInterval = 5

    /// Uses the core model to distill focused search terms from a raw user query.
    /// Falls back to the original query on any failure.
    private static func extractSearchTerms(from query: String) async -> String {
        do {
            let response = try await CoreModelService.shared.generate(
                prompt: query,
                systemPrompt: searchTermExtractionPrompt,
                temperature: 0.0,
                maxTokens: 128,
                timeout: extractionTimeout
            )
            let terms = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !terms.isEmpty else { return query }
            logger.info("Pre-flight extracted search terms: \(terms)")
            return terms
        } catch {
            logger.warning("Pre-flight search term extraction failed, using raw query: \(error)")
            return query
        }
    }

    /// Searches methods, tools, and skills in parallel and returns
    /// tool specs + a context snippet for system prompt injection.
    static func search(query: String, mode: PreflightSearchMode = .balanced) async -> PreflightResult {
        let empty = PreflightResult(toolSpecs: [], contextSnippet: "", items: [])

        guard mode != .off else { return empty }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return empty
        }

        let searchQuery = await extractSearchTerms(from: query)

        let topK = mode.topKValues
        async let methodHits = MethodSearchService.shared.search(query: searchQuery, topK: topK.methods)
        async let toolHits = ToolSearchService.shared.search(query: searchQuery, topK: topK.tools)
        async let skillHits = SkillSearchService.shared.search(query: searchQuery, topK: topK.skills)

        let methods = await methodHits
        let tools = await toolHits
        let skills = await skillHits

        // Enabled tool names for filtering method-cascaded tool references
        let enabledToolNames = await MainActor.run {
            Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
        }

        // Collect tool specs to inject
        var toolSpecsToAdd: [Tool] = []
        var toolNamesAdded: Set<String> = []

        // Tools matched directly by search
        for result in tools {
            let specs = await MainActor.run {
                ToolRegistry.shared.specs(forTools: [result.entry.name])
            }
            for spec in specs where !toolNamesAdded.contains(spec.function.name) {
                toolSpecsToAdd.append(spec)
                toolNamesAdded.insert(spec.function.name)
            }
        }

        // Tools referenced by matched methods (cascading — filter by enabled)
        for result in methods {
            let method = result.method
            for toolName in method.toolsUsed
            where enabledToolNames.contains(toolName) && !toolNamesAdded.contains(toolName) {
                let specs = await MainActor.run {
                    ToolRegistry.shared.specs(forTools: [toolName])
                }
                for spec in specs {
                    toolSpecsToAdd.append(spec)
                    toolNamesAdded.insert(spec.function.name)
                }
            }
        }

        // Build context snippet for methods and skills
        var sections: [String] = []

        if !methods.isEmpty {
            sections.append("## Pre-loaded Methods\n")
            for result in methods {
                let m = result.method
                sections.append("### \(m.name)\n")
                sections.append("*\(m.description)*\n")
                if !m.toolsUsed.isEmpty {
                    sections.append("Tools: \(m.toolsUsed.joined(separator: ", "))\n")
                }
                sections.append("\n\(m.body)\n")
            }
        }

        if !skills.isEmpty {
            sections.append("## Available Skills\n")
            sections.append("Use `capabilities_load` with a skill ID to load its full instructions.\n")
            for result in skills {
                let skill = result.skill
                sections.append("- skill/\(skill.name): \(skill.description)\n")
            }
        }

        var snippet = sections.joined(separator: "\n")

        var items: [PreflightCapabilityItem] =
            methods.map { .init(type: .method, name: $0.method.name, description: $0.method.description) }
            + tools.map { .init(type: .tool, name: $0.entry.name, description: $0.entry.description) }
            + skills.map { .init(type: .skill, name: $0.skill.name, description: $0.skill.description) }

        // When nothing matches and pluginCreate is enabled, inject the full
        // Sandbox Plugin Creator skill so the agent can self-create tools.
        if methods.isEmpty && tools.isEmpty && skills.isEmpty && toolSpecsToAdd.isEmpty {
            let canCreate = await MainActor.run {
                let agentId = AgentManager.shared.activeAgent.id
                return AgentManager.shared.effectiveAutonomousExec(for: agentId)?.pluginCreate == true
            }
            if canCreate {
                let creatorSkill = await MainActor.run {
                    SkillManager.shared.skill(named: "Sandbox Plugin Creator")
                }
                if let skill = creatorSkill {
                    snippet = """
                        ## No existing tools match this request

                        You can create new tools by writing a sandbox plugin.
                        Follow the instructions below.

                        ## Skill: \(skill.name)
                        \(skill.instructions)
                        """
                    items.append(
                        .init(
                            type: .skill,
                            name: skill.name,
                            description: skill.description
                        )
                    )
                    logger.info("Pre-flight: no results, injected Sandbox Plugin Creator skill")
                }
            }
        }

        if !toolSpecsToAdd.isEmpty || !snippet.isEmpty {
            let tc = toolSpecsToAdd.count
            let mc = methods.count
            let sc = skills.count
            logger.info("Pre-flight loaded \(tc) tools, \(mc) methods, \(sc) skills")
        }

        return PreflightResult(toolSpecs: toolSpecsToAdd, contextSnippet: snippet, items: items)
    }
}
