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

    static let empty = PreflightResult(toolSpecs: [], contextSnippet: "", items: [])
}

// MARK: - Shared Capability Search

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

    static func canCreatePlugins() async -> Bool {
        await MainActor.run {
            let agentId = AgentManager.shared.activeAgent.id
            return AgentManager.shared.effectiveAutonomousExec(for: agentId)?.pluginCreate == true
        }
    }
}

// MARK: - Preflight Capability Search

enum PreflightCapabilitySearch {

    private static let searchTermExtractionPrompt = """
        Given a user's request, identify what tools or capabilities would be needed to accomplish it. \
        Output 3-5 short capability descriptions, one per line. \
        Focus on the type of action or tool required, not the subject matter of the request. \
        No numbering, no explanations, no extra text.
        """

    private static let extractionTimeoutSeconds: TimeInterval = 5

    /// Uses the core model to translate a raw user query into capability-oriented search terms.
    /// Returns nil when no core model is configured or extraction fails — callers should
    /// skip the search entirely since raw queries produce too many false positives.
    private static func extractSearchTerms(from query: String) async -> String? {
        do {
            let response = try await CoreModelService.shared.generate(
                prompt: query,
                systemPrompt: searchTermExtractionPrompt,
                temperature: 0.0,
                maxTokens: 128,
                timeout: extractionTimeoutSeconds
            )
            let terms = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !terms.isEmpty else { return nil }
            logger.info("Pre-flight extracted search terms: \(terms)")
            return terms
        } catch {
            logger.info("Pre-flight search term extraction skipped: \(error)")
            return nil
        }
    }

    static func search(query: String, mode: PreflightSearchMode = .balanced) async -> PreflightResult {
        let empty = PreflightResult(toolSpecs: [], contextSnippet: "", items: [])

        guard mode != .off else { return empty }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return empty
        }
        guard let searchQuery = await extractSearchTerms(from: query) else {
            return empty
        }

        let hits = await CapabilitySearch.search(query: searchQuery, topK: mode.topKValues)

        if hits.isEmpty {
            guard await CapabilitySearch.canCreatePlugins() else { return empty }
            let skill = await MainActor.run {
                SkillManager.shared.skill(named: "Sandbox Plugin Creator")
            }
            guard let skill else { return empty }
            logger.info("Pre-flight: no results, injected Sandbox Plugin Creator skill")
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

        // Collect tool specs in a single MainActor hop:
        // direct tool hits + method-cascaded references (enabled only)
        let toolSpecs = await MainActor.run { () -> [Tool] in
            let enabled = Set(
                ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name }
            )
            var names: [String] = []
            var seen: Set<String> = []

            for name in hits.tools.map({ $0.entry.name })
            where seen.insert(name).inserted {
                names.append(name)
            }
            for r in hits.methods {
                for name in r.method.toolsUsed
                where enabled.contains(name) && seen.insert(name).inserted {
                    names.append(name)
                }
            }
            return ToolRegistry.shared.specs(forTools: names)
        }

        var sections: [String] = []
        if !hits.methods.isEmpty {
            sections.append("## Pre-loaded Methods\n")
            for result in hits.methods {
                let m = result.method
                sections.append("### \(m.name)\n")
                sections.append("*\(m.description)*\n")
                if !m.toolsUsed.isEmpty {
                    sections.append("Tools: \(m.toolsUsed.joined(separator: ", "))\n")
                }
                sections.append("\n\(m.body)\n")
            }
        }
        if !hits.skills.isEmpty {
            sections.append("## Available Skills\n")
            sections.append("Use `capabilities_load` with a skill ID to load its full instructions.\n")
            for result in hits.skills {
                sections.append("- skill/\(result.skill.name): \(result.skill.description)\n")
            }
        }

        let items: [PreflightCapabilityItem] =
            hits.methods.map { .init(type: .method, name: $0.method.name, description: $0.method.description) }
            + hits.tools.map { .init(type: .tool, name: $0.entry.name, description: $0.entry.description) }
            + hits.skills.map { .init(type: .skill, name: $0.skill.name, description: $0.skill.description) }

        logger.info(
            "Pre-flight loaded \(toolSpecs.count) tools, \(hits.methods.count) methods, \(hits.skills.count) skills"
        )

        return PreflightResult(
            toolSpecs: toolSpecs,
            contextSnippet: sections.joined(separator: "\n"),
            items: items
        )
    }
}
