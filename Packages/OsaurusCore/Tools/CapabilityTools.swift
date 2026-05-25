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
        + "Example: `{\"query\": \"convert csv to json\"}`."

    let agentId: UUID?

    init(agentId: UUID? = nil) {
        self.agentId = agentId
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Single search query describing what you need"),
            ]),
            "queries": .object([
                "type": .string("string"),
                "description": .string("Compatibility alias for a single search query. Prefer `query`."),
            ]),
        ]),
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

        let queriesReq = Self.requireQueries(args, tool: self)
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

        let agentContextId = Self.resolveAgentContextId(explicit: agentId)
        let allowedToolNames = await Self.allowedToolNames(for: agentContextId)

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
                    await CapabilitySearch.search(
                        query: q,
                        topK: Self.perQueryTopK,
                        allowedToolNames: allowedToolNames
                    )
                }
            }
            var collected: [CapabilitySearchResults] = []
            collected.reserveCapacity(queries.count)
            for await r in group { collected.append(r) }
            return collected
        }

        let hits = Self.mergeHits(perQueryResults)

        if hits.isEmpty {
            let queryList = queries.map { "'\($0)'" }.joined(separator: ", ")
            let text: String
            let pluginCreationAgentId = await Self.resolvePluginCreationAgentId(explicit: agentId)
            if await CapabilitySearch.canCreatePlugins(agentId: pluginCreationAgentId) {
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

    /// Resolve the agent context whose capability picker scopes runtime
    /// search. Only explicit tool instances and task-local chat execution
    /// contexts carry the user's current grant boundary; direct utility
    /// calls with neither value keep the historical global-enabled search.
    private static func resolveAgentContextId(explicit: UUID?) -> UUID? {
        explicit ?? ChatExecutionContext.currentAgentId
    }

    /// The no-match plugin-creator hint predates runtime allowlist
    /// scoping and was based on the active agent when no task-local
    /// context existed. Keep that behavior separate from search
    /// filtering so direct/no-context search results stay unscoped.
    private static func resolvePluginCreationAgentId(explicit: UUID?) async -> UUID {
        if let id = resolveAgentContextId(explicit: explicit) { return id }
        return await MainActor.run { AgentManager.shared.activeAgent.id }
    }

    /// The enabled-tool allowlist is nil for legacy/unseeded agents,
    /// which deliberately means "use the global enabled registry." A
    /// non-nil set is authoritative: `capabilities_search` must not
    /// return a dynamic tool the current agent has not been granted.
    private static func allowedToolNames(for agentId: UUID?) async -> Set<String>? {
        guard let agentId else { return nil }
        return await MainActor.run {
            AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init)
        }
    }

    /// Accept the template-safe singular `query` spelling plus older
    /// `queries` arrays. This recovery is local to the discovery tool so
    /// other array arguments keep the stricter validator behavior.
    private static func requireQueries(
        _ args: [String: Any],
        tool: CapabilitiesSearchTool
    ) -> ArgumentRequirement<[String]> {
        if args["queries"] != nil {
            if let stringified = args["queries"] as? String {
                let parsed = parseStringifiedQueries(stringified)
                if !parsed.isEmpty {
                    return .value(parsed)
                }
            }

            let req = tool.requireStringArray(
                args,
                "queries",
                expected: "non-empty array of search query strings",
                tool: tool.name
            )
            if case .value(let queries) = req, !queries.isEmpty {
                return .value(queries)
            }
            if args["query"] == nil { return req }
        }

        guard args["query"] != nil else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Missing required argument `query` (search string). Legacy `queries` arrays are still accepted.",
                    field: "query",
                    expected: "single search query string",
                    tool: tool.name
                )
            )
        }

        let req = tool.requireString(
            args,
            "query",
            expected: "single search query string",
            tool: tool.name
        )
        guard case .value(let query) = req else {
            return .failure(req.failureEnvelope ?? "")
        }
        return .value([query])
    }

    private static func parseStringifiedQueries(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized = trimmed.replacingOccurrences(of: #"<|"|>"#, with: #"""#)
        if let data = normalized.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array
        }

        let body: String
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            body = String(normalized.dropFirst().dropLast())
        } else {
            body = normalized
        }

        return body
            .split(separator: ",")
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
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
                let allowedNames = await grantedToolNamesForCurrentAgent()
                let (loadableToolNames, blockedToolNames, toolSpecs) = await MainActor.run {
                    var allowed: [String] = []
                    var blocked: [String] = []
                    for name in method.toolsUsed {
                        let isBuiltIn = ToolRegistry.shared.builtInToolNames.contains(name)
                        if isBuiltIn || (allowedNames?.contains(name) ?? true) {
                            allowed.append(name)
                        } else {
                            blocked.append(name)
                        }
                    }
                    return (
                        allowed,
                        blocked,
                        ToolRegistry.shared.specs(forTools: allowed)
                    )
                }
                for spec in toolSpecs {
                    await CapabilityLoadBuffer.shared.add(spec)
                }
                if !loadableToolNames.isEmpty {
                    output += "Auto-loaded tools: \(loadableToolNames.joined(separator: ", "))\n"
                }
                if !blockedToolNames.isEmpty {
                    output += "Skipped tools not enabled for this agent: \(blockedToolNames.joined(separator: ", "))\n"
                }
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
        let allowedNames = await grantedToolNamesForCurrentAgent()
        let (isEnabled, isBuiltIn, toolSpec) = await MainActor.run {
            (
                ToolRegistry.shared.isGlobalEnabled(toolId),
                ToolRegistry.shared.builtInToolNames.contains(toolId),
                ToolRegistry.shared.specs(forTools: [toolId])
            )
        }
        guard isBuiltIn || (allowedNames?.contains(toolId) ?? true) else {
            return "Error: Tool '\(toolId)' is not enabled for this agent.\n"
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

    /// Nil means this agent has not been seeded by the capability picker
    /// yet, so the historical global-enabled behavior remains in force.
    /// A concrete set is the user's grant boundary and is enforced even
    /// if the model invents a `tool/<name>` ID instead of receiving it
    /// from `capabilities_search`.
    private func grantedToolNamesForCurrentAgent() async -> Set<String>? {
        let id: UUID
        if let contextId = ChatExecutionContext.currentAgentId {
            id = contextId
        } else {
            id = await MainActor.run { AgentManager.shared.activeAgent.id }
        }
        return await MainActor.run {
            AgentManager.shared.effectiveEnabledToolNames(for: id).map(Set.init)
        }
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
