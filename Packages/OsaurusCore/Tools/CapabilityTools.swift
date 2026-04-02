//
//  CapabilityTools.swift
//  osaurus
//
//  Unified capability search and load tools. capabilities_search queries
//  methods, skills, and tools in one call. capabilities_load injects the
//  selected items into the active session with cascading dependencies.
//

import Foundation

// MARK: - CapabilityLoadBuffer

/// Shared buffer for communicating newly loaded tool specs from capabilities_load
/// back to the execution loop. The loop drains pending tools after each
/// capabilities_load call and appends them to the active tool set.
actor CapabilityLoadBuffer {
    static let shared = CapabilityLoadBuffer()

    private var pendingTools: [Tool] = []

    func add(_ tool: Tool) {
        pendingTools.append(tool)
    }

    func drain() -> [Tool] {
        let tools = pendingTools
        pendingTools = []
        return tools
    }
}

// MARK: - capabilities_search

final class CapabilitiesSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "capabilities_search"
    let description =
        "Search for additional methods, tools, and skills beyond what was pre-loaded. "
        + "Relevant capabilities are already loaded based on your task — use this only when you "
        + "need something not already available. Returns ranked results tagged by type."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "queries": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("One or more search queries describing what you need"),
            ])
        ]),
        "required": .array([.string("queries")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let queries = ArgumentCoercion.stringArray(args["queries"]),
            !queries.isEmpty
        else {
            return "Error: 'queries' parameter (string array) is required."
        }

        let query = queries.joined(separator: " ")
        let hits = await CapabilitySearch.search(
            query: query,
            topK: (methods: 5, tools: 5, skills: 3)
        )

        if hits.isEmpty {
            if await CapabilitySearch.canCreatePlugins() {
                return """
                    No capabilities found matching '\(query)'.

                    You can create new tools for this. Load the plugin creator skill:
                      capabilities_load("skill/Sandbox Plugin Creator")
                    """
            }
            return "No capabilities found matching '\(query)'."
        }

        struct ScoredResult {
            let id: String
            let type: String
            let description: String
            let score: Double
            let extra: String?
        }

        let results: [ScoredResult] =
            (hits.methods.map {
                ScoredResult(
                    id: "method/\($0.method.id)",
                    type: "method",
                    description: "\($0.method.name): \($0.method.description)",
                    score: $0.score,
                    extra: "tools_used: \($0.method.toolsUsed.joined(separator: ", "))"
                )
            }
            + hits.tools.map {
                ScoredResult(
                    id: "tool/\($0.entry.id)",
                    type: "tool",
                    description: "\($0.entry.name): \($0.entry.description)",
                    score: Double($0.searchScore),
                    extra: "runtime: \($0.entry.runtime.rawValue)"
                )
            }
            + hits.skills.map {
                ScoredResult(
                    id: "skill/\($0.skill.name)",
                    type: "skill",
                    description: "\($0.skill.name): \($0.skill.description)",
                    score: Double($0.searchScore),
                    extra: nil
                )
            }).sorted { $0.score > $1.score }

        var output = "Found \(results.count) capability(ies):\n\n"
        for r in results {
            output += "- **\(r.id)** [\(r.type)]\n"
            output += "  \(r.description)\n"
            if let extra = r.extra {
                output += "  \(extra)\n"
            }
            output += "\n"
        }
        output += "Use `capabilities_load` with the IDs to load them into this session."
        return output
    }
}

// MARK: - capabilities_load

final class CapabilitiesLoadTool: OsaurusTool, @unchecked Sendable {
    let name = "capabilities_load"
    let description =
        "Load additional capabilities into the current session by ID (from capabilities_search results). "
        + "Methods load their full steps plus auto-load referenced tools and skills. "
        + "Tools become available as function calls. Skills load instruction text into context."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "IDs from capabilities_search results (e.g. 'method/abc', 'tool/sandbox_exec', 'skill/swift-best-practices')"
                ),
            ])
        ]),
        "required": .array([.string("ids")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let ids = ArgumentCoercion.stringArray(args["ids"]),
            !ids.isEmpty
        else {
            return "Error: 'ids' parameter (string array) is required."
        }

        var output = ""

        for id in ids {
            guard let slashIdx = id.firstIndex(of: "/") else {
                output += "Warning: Invalid ID format '\(id)' — expected type/id.\n"
                continue
            }

            let typePrefix = String(id[id.startIndex ..< slashIdx])
            let rawId = String(id[id.index(after: slashIdx)...])

            switch typePrefix {
            case "method":
                output += await loadMethod(rawId)
            case "tool":
                output += await loadTool(rawId)
            case "skill":
                output += await loadSkill(rawId)
            default:
                output += "Warning: Unknown type '\(typePrefix)' in ID '\(id)'.\n"
            }
        }

        return output.isEmpty ? "No capabilities loaded." : output
    }

    // MARK: - Loaders

    private func loadMethod(_ methodId: String) async -> String {
        do {
            guard let method = try await MethodService.shared.load(id: methodId) else {
                return "Error: Method '\(methodId)' not found.\n"
            }

            let issueId = WorkExecutionContext.currentIssueId
            try await MethodService.shared.reportOutcome(
                methodId: methodId,
                outcome: .loaded,
                agentId: issueId
            )

            var output = "# Method: \(method.name)\n\n"
            output += "Description: \(method.description)\n"
            output += "Version: \(method.version) | Source: \(method.source.rawValue)\n"
            if !method.toolsUsed.isEmpty {
                output += "Tools: \(method.toolsUsed.joined(separator: ", "))\n"
            }
            output += "\n---\n\n"
            output += method.body
            output += "\n\n"

            if !method.toolsUsed.isEmpty {
                let toolSpecs = await MainActor.run {
                    ToolRegistry.shared.specs(forTools: method.toolsUsed)
                }
                for spec in toolSpecs {
                    await CapabilityLoadBuffer.shared.add(spec)
                }
                output += "Auto-loaded tools: \(method.toolsUsed.joined(separator: ", "))\n"
            }

            if !method.skillsUsed.isEmpty {
                let skills: [(String, String)] = await MainActor.run {
                    method.skillsUsed.compactMap { name in
                        SkillManager.shared.skill(named: name).map { (name, $0.instructions) }
                    }
                }
                for (name, instructions) in skills {
                    output += "\n## Skill: \(name)\n"
                    output += instructions
                    output += "\n\n"
                }
            }

            return output
        } catch {
            return "Error loading method '\(methodId)': \(error.localizedDescription)\n"
        }
    }

    private func loadTool(_ toolId: String) async -> String {
        let (isEnabled, toolSpec) = await MainActor.run {
            (
                ToolRegistry.shared.isGlobalEnabled(toolId),
                ToolRegistry.shared.specs(forTools: [toolId])
            )
        }
        guard isEnabled else {
            return "Error: Tool '\(toolId)' is disabled.\n"
        }
        guard let spec = toolSpec.first else {
            return "Error: Tool '\(toolId)' not found or not registered.\n"
        }
        await CapabilityLoadBuffer.shared.add(spec)
        return "Tool '\(toolId)' loaded and available.\n"
    }

    private func loadSkill(_ skillName: String) async -> String {
        let skill = await MainActor.run {
            SkillManager.shared.skill(named: skillName)
        }
        guard let skill = skill else {
            return "Error: Skill '\(skillName)' not found.\n"
        }
        var output = "## Skill: \(skill.name)\n"
        if !skill.description.isEmpty {
            output += "*\(skill.description)*\n\n"
        }
        output += skill.instructions
        output += "\n\n"
        return output
    }
}
