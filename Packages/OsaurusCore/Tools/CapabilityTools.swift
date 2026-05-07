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
        "Find additional tools or skills the current schema does not include. "
        + "Use ONLY when your existing tools cannot do the task — your initial set was pre-selected for relevance. "
        + "Returns ranked IDs (e.g. `tool/sandbox_exec`, `skill/plot-data`) you then pass to `capabilities_load`. "
        + "Example: `{\"queries\": [\"convert csv to json\", \"send http request\"]}`."

    let agentId: UUID?

    init(agentId: UUID? = nil) {
        self.agentId = agentId
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "queries": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("One or more search queries describing what you need"),
            ])
        ]),
        "required": .array([.string("queries")]),
    ])

    /// Cap on the number of distinct queries we'll fan out per call.
    /// Each query triggers one embedding pass + one BM25/FTS5 read,
    /// so a runaway model emitting `["a","b","c",…]` could otherwise
    /// fan out to N embed calls per turn. 8 covers every realistic
    /// "search for these aspects of my problem" use case while
    /// keeping the worst-case fan-out bounded.
    private static let maxQueries = 8

    /// Per-query topK passed down to `CapabilitySearch.search`. Kept
    /// at the historical (5,5,3) so a single-query call returns the
    /// same shaped result as before; the multi-query path lets the
    /// merged set grow naturally up to `maxQueries × topK` minus dedup.
    private static let perQueryTopK: (methods: Int, tools: Int, skills: Int) =
        (methods: 5, tools: 5, skills: 3)

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let queriesReq = requireStringArray(
            args,
            "queries",
            expected: "non-empty array of search query strings",
            tool: name
        )
        guard case .value(let rawQueries) = queriesReq else { return queriesReq.failureEnvelope ?? "" }

        // Normalise: trim, drop empties, dedupe case-insensitively (small
        // models routinely emit the same query in different casing or
        // with stray whitespace), and cap the fan-out. Keep first-seen
        // order so the no-match diagnostic mirrors what the model asked.
        var seen = Set<String>()
        let queries: [String] =
            rawQueries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(Self.maxQueries)
            .map { $0 }

        guard !queries.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `queries` must contain at least one non-empty search string.",
                field: "queries",
                expected: "non-empty array of search query strings",
                tool: name
            )
        }

        // Run each query independently and merge by best score per item.
        // The previous implementation joined every query into one string
        // and ran a single search — `["weather API", "get current weather
        // data"]` became `"weather API get current weather data"`, which
        // tokenises as a longer, less precise sentence the embedder
        // doesn't recognise. The whole point of accepting an array is
        // "OR these searches", not "concatenate them".
        let perQueryResults: [CapabilitySearchResults] = await withTaskGroup(
            of: CapabilitySearchResults.self
        ) { group in
            for q in queries {
                group.addTask {
                    await CapabilitySearch.search(query: q, topK: Self.perQueryTopK)
                }
            }
            var collected: [CapabilitySearchResults] = []
            collected.reserveCapacity(queries.count)
            for await r in group { collected.append(r) }
            return collected
        }

        let hits = Self.mergeHits(perQueryResults)

        if hits.isEmpty {
            let id: UUID
            if let existingId = agentId ?? ChatExecutionContext.currentAgentId {
                id = existingId
            } else {
                id = await MainActor.run { AgentManager.shared.activeAgent.id }
            }

            let queryList = queries.map { "'\($0)'" }.joined(separator: ", ")
            let text: String
            if await CapabilitySearch.canCreatePlugins(agentId: id) {
                text = """
                    No capabilities found matching \(queryList).

                    You can create new tools for this. Load the plugin creator skill:
                      capabilities_load("skill/Sandbox Plugin Creator")
                    """
            } else {
                text = "No capabilities found matching \(queryList)."
            }
            return ToolEnvelope.success(tool: name, text: text)
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
        return ToolEnvelope.success(tool: name, text: output)
    }

    // MARK: - Merge

    /// Merge per-query `CapabilitySearchResults` into a single set,
    /// keeping the entry with the highest `searchScore` per (type, id).
    /// `searchScore` is the embedding similarity in every lane and is
    /// directly comparable across queries (same embedder, same vector
    /// space). Methods carry an extra `score: Double` used downstream
    /// for cross-type ranking; that field follows the kept entry, so
    /// the existing display sort remains stable.
    ///
    /// Each lane is independently sorted by `searchScore` desc so the
    /// caller's cross-type ranker sees inputs in best-first order even
    /// before its own sort runs.
    private static func mergeHits(
        _ results: [CapabilitySearchResults]
    ) -> CapabilitySearchResults {
        var methodsById: [String: MethodSearchResult] = [:]
        var toolsById: [String: ToolSearchResult] = [:]
        var skillsByName: [String: SkillSearchResult] = [:]

        for r in results {
            for m in r.methods {
                if let existing = methodsById[m.method.id], existing.searchScore >= m.searchScore {
                    continue
                }
                methodsById[m.method.id] = m
            }
            for t in r.tools {
                if let existing = toolsById[t.entry.id], existing.searchScore >= t.searchScore {
                    continue
                }
                toolsById[t.entry.id] = t
            }
            for s in r.skills {
                if let existing = skillsByName[s.skill.name], existing.searchScore >= s.searchScore {
                    continue
                }
                skillsByName[s.skill.name] = s
            }
        }

        return CapabilitySearchResults(
            methods: methodsById.values.sorted { $0.searchScore > $1.searchScore },
            tools: toolsById.values.sorted { $0.searchScore > $1.searchScore },
            skills: skillsByName.values.sorted { $0.searchScore > $1.searchScore }
        )
    }
}

// MARK: - capabilities_load

final class CapabilitiesLoadTool: OsaurusTool, @unchecked Sendable {
    let name = "capabilities_load"
    let description =
        "Load capabilities into the current session by ID. IDs MUST come from `capabilities_search` results — "
        + "do not invent IDs. After loading, the named tools are callable for the rest of the session and named "
        + "skills are appended to your instructions. "
        + "Example: `{\"ids\": [\"tool/sandbox_exec\", \"skill/plot-data\"]}`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
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
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let idsReq = requireStringArray(
            args,
            "ids",
            expected: "non-empty array of `<type>/<id>` strings from `capabilities_search` results",
            tool: name
        )
        guard case .value(let ids) = idsReq else { return idsReq.failureEnvelope ?? "" }

        var output = ""

        for id in ids {
            guard let slashIdx = id.firstIndex(of: "/") else {
                output +=
                    "Warning: Invalid ID format '\(id)' — expected `<type>/<id>` "
                    + "(e.g. `tool/sandbox_exec`, `skill/plot-data`). Get IDs from `capabilities_search`.\n"
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
                output +=
                    "Warning: Unknown type '\(typePrefix)' in ID '\(id)' "
                    + "(expected `tool`, `skill`, or `method`).\n"
            }
        }

        let text = output.isEmpty ? "No capabilities loaded." : output
        return ToolEnvelope.success(tool: name, text: text)
    }

    // MARK: - Loaders

    private func loadMethod(_ methodId: String) async -> String {
        do {
            guard let method = try await MethodService.shared.load(id: methodId) else {
                return "Error: Method '\(methodId)' not found.\n"
            }

            let sessionId = ChatExecutionContext.currentSessionId
            try await MethodService.shared.reportOutcome(
                methodId: methodId,
                outcome: .loaded,
                agentId: sessionId
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
        let (isEnabled, isBuiltIn, toolSpec) = await MainActor.run {
            (
                ToolRegistry.shared.isGlobalEnabled(toolId),
                ToolRegistry.shared.builtInToolNames.contains(toolId),
                ToolRegistry.shared.specs(forTools: [toolId])
            )
        }
        // Built-in tools are always loaded via alwaysLoadedSpecs, so skip the
        // enabled check — rejecting them here is misleading since they're callable.
        guard isEnabled || isBuiltIn else {
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
