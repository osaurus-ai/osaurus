//
//  CapabilityTools.swift
//  osaurus
//
//  Unified capability search and load tools. capabilities_discover queries
//  methods, skills, and tools in one call. capabilities_load injects the
//  selected items into the active session with cascading dependencies.
//

import Foundation

// MARK: - CapabilityLoadBuffer

/// Structured diagnostic for a dynamically-loaded tool schema that cannot be
/// exposed safely. Dynamic schemas must fail closed: a missing/malformed
/// provider schema is not silently replaced with `{}` because that teaches the
/// model to call an underspecified tool and then rely on parser repair.
struct CapabilitySchemaDiagnostic: Sendable {
    let toolName: String
    let kind: ToolEnvelope.Kind
    let message: String
    let field: String?
    let expected: String?

    func dictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "tool_name": toolName,
            "kind": kind.rawValue,
            "message": message,
        ]
        if let field { dict["field"] = field }
        if let expected { dict["expected"] = expected }
        return dict
    }
}

/// Shared buffer for communicating newly loaded tool specs from capabilities_load
/// back to the execution loop. The loop drains pending tools after each
/// capabilities_load call and appends them to the active tool set.
actor CapabilityLoadBuffer {
    static let shared = CapabilityLoadBuffer()

    private var pendingToolOrder: [String] = []
    private var pendingToolsByName: [String: Tool] = [:]

    @discardableResult
    func add(_ tool: Tool) -> CapabilitySchemaDiagnostic? {
        if let diagnostic = Self.validateDynamicToolSchema(tool) {
            return diagnostic
        }
        let name = tool.function.name
        if pendingToolsByName[name] == nil {
            pendingToolOrder.append(name)
        }
        // Idempotent duplicate loads in one turn: keep one activation slot,
        // but let the latest spec replace an earlier copy if the registry
        // refreshed it before the buffer drained.
        pendingToolsByName[name] = tool
        return nil
    }

    func drain() -> [Tool] {
        let tools = pendingToolOrder.compactMap { pendingToolsByName[$0] }
        pendingToolOrder = []
        pendingToolsByName = [:]
        return tools
    }

    static func validateDynamicToolSchema(_ tool: Tool) -> CapabilitySchemaDiagnostic? {
        let name = tool.function.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return CapabilitySchemaDiagnostic(
                toolName: tool.function.name,
                kind: .invalidArgs,
                message: "Loaded tool schema is missing a function name.",
                field: "name",
                expected: "non-empty function name"
            )
        }
        guard tool.type == "function" else {
            return CapabilitySchemaDiagnostic(
                toolName: name,
                kind: .invalidArgs,
                message: "Loaded tool '\(name)' has unsupported tool type '\(tool.type)'.",
                field: "type",
                expected: "function"
            )
        }
        guard let parameters = tool.function.parameters else {
            // Existing no-argument tools legitimately use nil parameters; the
            // OpenAI encoder normalizes nil to an empty object schema.
            return nil
        }
        guard case .object(let schema) = parameters else {
            return CapabilitySchemaDiagnostic(
                toolName: name,
                kind: .invalidArgs,
                message: "Loaded tool '\(name)' has a non-object parameter schema.",
                field: "parameters",
                expected: "JSON Schema object with type: object"
            )
        }
        guard case .string("object")? = schema["type"] else {
            return CapabilitySchemaDiagnostic(
                toolName: name,
                kind: .invalidArgs,
                message: "Loaded tool '\(name)' parameter schema must declare type: object.",
                field: "parameters.type",
                expected: "object"
            )
        }
        if let properties = schema["properties"], case .object = properties {
            // Valid.
        } else if schema["properties"] != nil {
            return CapabilitySchemaDiagnostic(
                toolName: name,
                kind: .invalidArgs,
                message: "Loaded tool '\(name)' parameter schema has non-object properties.",
                field: "parameters.properties",
                expected: "object mapping property names to schemas"
            )
        }
        if let required = schema["required"] {
            guard case .array(let values) = required,
                values.allSatisfy({
                    if case .string = $0 { return true }
                    return false
                })
            else {
                return CapabilitySchemaDiagnostic(
                    toolName: name,
                    kind: .invalidArgs,
                    message: "Loaded tool '\(name)' parameter schema has malformed required fields.",
                    field: "parameters.required",
                    expected: "array of strings"
                )
            }
        }
        return nil
    }
}

// MARK: - capabilities_discover

final class CapabilitiesDiscoverTool: OsaurusTool, @unchecked Sendable {
    let name = "capabilities_discover"
    let description =
        "Find additional tools or skills the current schema does not include. "
        + "Use this to discover or confirm any capability, including whether a named tool exists in the enabled set. "
        + "Your current tool list is a fixed subset, not the full set. "
        + "Returns ranked IDs (e.g. `tool/sandbox_exec`, `skill/plot-data`) you then pass to `capabilities_load`. "
        + "Example: `{\"query\": \"convert csv to json\"}`."

    let agentId: UUID?

    init(agentId: UUID? = nil) {
        self.agentId = agentId
    }

    // `additionalProperties` stays permissive (not `false`) so the central
    // preflight does not reject a legacy `queries` payload before
    // `requireQueries` can absorb it. `queries` is intentionally absent from
    // `properties` so small models only ever see the single `query` field.
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(true),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Single search query describing what you need"),
            ])
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
        let isDefaultAgent = agentContextId == Agent.defaultId
        let baseAllowedToolNames = await Self.allowedToolNames(for: agentContextId)

        // Phase C scoping:
        //   * Default agent: results restricted to the configure writes
        //     so search returns ONLY `osaurus_*_<verb>` candidates. The
        //     default agent has no business loading sandbox/MCP/plugin
        //     tools — its job is configuration.
        //   * Other agents: the configure write set is masked out so a
        //     stray ranking can't surface them.
        // `ToolRegistry.configure*ToolNames` read the `@MainActor`
        // `ConfigurationDomainRegistry`; snapshot once so the search
        // loop below stays off the main actor.
        let (configureWrites, configureAll) = await MainActor.run {
            (ToolRegistry.configureWriteToolNames, ToolRegistry.configureToolNames)
        }
        let effectiveAllowedToolNames: Set<String>?
        if isDefaultAgent {
            effectiveAllowedToolNames = configureWrites
        } else if let base = baseAllowedToolNames {
            effectiveAllowedToolNames = base.subtracting(configureAll)
        } else {
            effectiveAllowedToolNames = nil
        }

        // Run each query independently and merge by best score per item.
        // The previous implementation joined every query into one string
        // and ran a single search — `["weather API", "get current weather
        // data"]` became `"weather API get current weather data"`, which
        // tokenises as a longer, less precise sentence the embedder
        // doesn't recognise. The whole point of accepting an array is
        // "OR these searches", not "concatenate them".
        //
        // Default agent takes the tools-only fast path: methods and
        // skills are off-limits on that surface, so ranking them is
        // pure wasted embedder work.
        let perQueryResults: [CapabilitySearchResults] = await withTaskGroup(
            of: CapabilitySearchResults.self
        ) { group in
            for q in queries {
                group.addTask {
                    if isDefaultAgent {
                        return await CapabilitySearch.searchToolsOnly(
                            query: q,
                            topK: Self.perQueryTopK.tools,
                            allowedToolNames: effectiveAllowedToolNames
                        )
                    }
                    return await CapabilitySearch.search(
                        query: q,
                        topK: Self.perQueryTopK,
                        allowedToolNames: effectiveAllowedToolNames
                    )
                }
            }
            var collected: [CapabilitySearchResults] = []
            collected.reserveCapacity(queries.count)
            for await r in group { collected.append(r) }
            return collected
        }

        let hits = Self.mergeHits(perQueryResults)
        let toolAvailabilityByName: [String: ToolAvailability] = await MainActor.run {
            var result: [String: ToolAvailability] = [:]
            result.reserveCapacity(hits.tools.count)
            for hit in hits.tools {
                result[hit.entry.id] = ToolRegistry.shared.availability(
                    forTool: hit.entry.id,
                    agentAllowedNames: effectiveAllowedToolNames
                )
            }
            return result
        }

        if hits.isEmpty {
            let queryList = queries.map { "'\($0)'" }.joined(separator: ", ")
            var text: String
            let pluginCreationAgentId = await Self.resolvePluginCreationAgentId(explicit: agentId)
            if await CapabilitySearch.canCreatePlugins(agentId: pluginCreationAgentId) {
                text = """
                    No capabilities found matching \(queryList).

                    Don't stop here — build it. Assemble it from sandbox \
                    primitives (see Discovering more tools), and package \
                    reusable work as a sandbox plugin (see Building new tools).
                    """
            } else {
                text = "No capabilities found matching \(queryList)."
            }
            if let diagnostic = await Self.exposureDiagnosticForNamedTools(
                queries: queries,
                allowedToolNames: effectiveAllowedToolNames
            ) {
                text += "\n\n\(diagnostic.textBlock)"
            }
            return ToolEnvelope.success(tool: name, text: text)
        }

        struct ScoredResult {
            let id: String
            let type: String
            let description: String
            let score: Double
            let extraLines: [String]
        }

        let results: [ScoredResult] =
            (hits.methods.map {
                ScoredResult(
                    id: "method/\($0.method.id)",
                    type: "method",
                    description: "\($0.method.name): \($0.method.description)",
                    score: $0.score,
                    extraLines: ["tools_used: \($0.method.toolsUsed.joined(separator: ", "))"]
                )
            }
            + hits.tools.map {
                var extraLines = ["runtime: \($0.entry.runtime.rawValue)"]
                if let availability = toolAvailabilityByName[$0.entry.id] {
                    extraLines.append("availability: \(availability.compactSummary)")
                    if let groupName = availability.groupName {
                        extraLines.append("provider: \(groupName)")
                    }
                }
                return ScoredResult(
                    id: "tool/\($0.entry.id)",
                    type: "tool",
                    description: "\($0.entry.name): \($0.entry.description)",
                    score: Double($0.searchScore),
                    extraLines: extraLines
                )
            }
            + hits.skills.map {
                ScoredResult(
                    id: "skill/\($0.skill.name)",
                    type: "skill",
                    description: "\($0.skill.name): \($0.skill.description)",
                    score: Double($0.searchScore),
                    extraLines: []
                )
            }).sorted { $0.score > $1.score }

        var output = "Found \(results.count) capability(ies):\n\n"
        for r in results {
            output += "- **\(r.id)** [\(r.type)]\n"
            output += "  \(r.description)\n"
            for extra in r.extraLines {
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
    /// non-nil set is authoritative: `capabilities_discover` must not
    /// return a dynamic tool the current agent has not been granted.
    private static func allowedToolNames(for agentId: UUID?) async -> Set<String>? {
        guard let agentId else { return nil }
        return await MainActor.run {
            AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init)
        }
    }

    /// When a search misses entirely, surface diagnostics only for tool-like
    /// names the request explicitly mentioned. This keeps normal semantic
    /// searches concise while making exact probes such as `tool/sandbox_exec`
    /// or `capabilities_discover` explain why they did not appear as hits.
    private static func exposureDiagnosticForNamedTools(
        queries: [String],
        allowedToolNames: Set<String>?
    ) async -> ToolExposureDiagnostic? {
        let registeredNames = await MainActor.run {
            Set(ToolRegistry.shared.listTools().map(\.name))
        }
        let candidates = namedToolCandidates(
            in: queries,
            registeredToolNames: registeredNames
        )
        guard !candidates.isEmpty else { return nil }
        let diagnostic = await ToolIndexService.shared.exposureDiagnostic(
            forToolNames: candidates,
            agentAllowedNames: allowedToolNames
        )
        return diagnostic.rows.isEmpty ? nil : diagnostic
    }

    static func namedToolCandidates(
        in queries: [String],
        registeredToolNames: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []
        let regex = try? NSRegularExpression(
            pattern: #"(?:tool/)?[A-Za-z0-9_-]{1,64}"#,
            options: []
        )

        for query in queries {
            let range = NSRange(query.startIndex ..< query.endIndex, in: query)
            let matches = regex?.matches(in: query, options: [], range: range) ?? []
            for match in matches {
                guard let swiftRange = Range(match.range, in: query) else { continue }
                let raw = String(query[swiftRange])
                let explicitTool = raw.hasPrefix("tool/")
                let candidate = explicitTool ? String(raw.dropFirst("tool/".count)) : raw
                let normalized =
                    registeredToolNames.contains(candidate)
                    ? candidate
                    : candidate.lowercased()
                guard
                    explicitTool
                        || registeredToolNames.contains(normalized)
                        || candidate.contains("_")
                        || candidate.contains("-")
                else { continue }
                if seen.insert(normalized).inserted {
                    candidates.append(normalized)
                }
            }
        }
        return candidates
    }

    /// Accept the template-safe singular `query` spelling plus older
    /// `queries` arrays. This recovery is local to the discovery tool so
    /// other array arguments keep the stricter validator behavior.
    private static func requireQueries(
        _ args: [String: Any],
        tool: CapabilitiesDiscoverTool
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
                    message:
                        "Missing required argument `query` (search string). Legacy `queries` arrays are still accepted.",
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
            let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            return array
        }

        let body: String
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            body = String(normalized.dropFirst().dropLast())
        } else {
            body = normalized
        }

        return
            body
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
        "Load capabilities into the current session by ID. IDs come from the Enabled capabilities list "
        + "or from `capabilities_discover` results — do not invent IDs. After loading, the named tools are "
        + "callable for the rest of the session; a named skill's instructions are returned in this tool's "
        + "result for you to follow. A `plugin/<id>` id loads that plugin's whole tool group (and any "
        + "governing skill) in one call. Example: `{\"ids\": [\"plugin/calendar\", \"tool/sandbox_exec\", \"skill/plot-data\"]}`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "IDs from the Enabled capabilities list or capabilities_discover results (e.g. 'plugin/calendar', 'method/abc', 'tool/sandbox_exec', 'skill/swift-best-practices')"
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
            expected:
                "non-empty array of `<type>/<id>` strings from the Enabled capabilities list or `capabilities_discover` results",
            tool: name
        )
        guard case .value(let ids) = idsReq else { return idsReq.failureEnvelope ?? "" }

        var sections: [String] = []
        var failures: [LoadFailure] = []

        for id in ids {
            guard let slashIdx = id.firstIndex(of: "/") else {
                failures.append(
                    LoadFailure(
                        kind: .invalidArgs,
                        message:
                            "Invalid ID format '\(id)' — expected `<type>/<id>` "
                            + "(e.g. `tool/sandbox_exec`, `skill/plot-data`). Use IDs from the Enabled capabilities list or `capabilities_discover`.",
                        field: "ids"
                    )
                )
                continue
            }

            let typePrefix = String(id[id.startIndex ..< slashIdx])
            let rawId = String(id[id.index(after: slashIdx)...])

            let outcome: LoadOutcome
            switch typePrefix {
            case "method":
                outcome = await loadMethod(rawId)
            case "tool":
                outcome = await loadTool(rawId)
            case "skill":
                outcome = await loadSkill(rawId)
            case "plugin":
                outcome = await loadPlugin(rawId)
            default:
                outcome = .failure(
                    LoadFailure(
                        kind: .invalidArgs,
                        message:
                            "Unknown type '\(typePrefix)' in ID '\(id)' "
                            + "(expected `tool`, `skill`, `plugin`, or `method`)."
                    )
                )
            }
            switch outcome {
            case .success(let text): sections.append(text)
            case .failure(let failure): failures.append(failure)
            }
        }

        // Hard failure contract: when NOTHING loaded, return a real
        // failure envelope — "Error: …" prose inside a success envelope
        // taught small models to treat misses as wins.
        if sections.isEmpty, let first = failures.first {
            let combined = failures.map(\.message).joined(separator: "\n")
            // A bad/unknown capability id is deterministic: capability ids are
            // a closed vocabulary, so re-issuing the identical call cannot
            // succeed. Mark those (and policy refusals) non-retryable — only a
            // genuine runtime error is worth retrying as-is. This also keeps
            // the flag consistent with the deterministic-error replay guard.
            let deterministicKinds: Set<ToolEnvelope.Kind> = [.rejected, .invalidArgs, .notFound]
            return ToolEnvelope.failure(
                kind: first.kind,
                message: combined,
                field: first.field ?? (first.kind == .invalidArgs ? "ids" : nil),
                expected: first.expected,
                tool: name,
                retryable: !deterministicKinds.contains(first.kind)
            )
        }

        let text = sections.isEmpty ? "No capabilities loaded." : sections.joined()
        let warnings = failures.map(\.message)
        return ToolEnvelope.success(
            tool: name,
            text: text,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Structured per-id failure: the `kind` drives the all-failed
    /// envelope's taxonomy, the message rides as a warning on partial
    /// success.
    private struct LoadFailure {
        let kind: ToolEnvelope.Kind
        let message: String
        var field: String? = nil
        var expected: String? = nil
    }

    private enum LoadOutcome {
        case success(String)
        case failure(LoadFailure)
    }

    // MARK: - Loaders

    private func loadMethod(_ methodId: String) async -> LoadOutcome {
        if ChatExecutionContext.currentAgentId == Agent.defaultId {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Method loading is disabled for the configuration agent. "
                        + "Use `capabilities_discover` to find a configuration tool (osaurus_*_<verb>) "
                        + "and load it directly."
                )
            )
        }
        do {
            guard let method = try await MethodService.shared.load(id: methodId) else {
                return .failure(
                    LoadFailure(kind: .notFound, message: "Method '\(methodId)' not found.")
                )
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
                let (loadableToolNames, blockedToolNames) = await MainActor.run {
                    () -> ([String], [String]) in
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
                    return (allowed, blocked)
                }
                output += await bufferToolSpecs(named: loadableToolNames)
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

            return .success(output)
        } catch {
            return .failure(
                LoadFailure(
                    kind: .executionError,
                    message: "Error loading method '\(methodId)': \(error.localizedDescription)"
                )
            )
        }
    }

    private func loadTool(_ toolId: String) async -> LoadOutcome {
        let isDefaultAgent = ChatExecutionContext.currentAgentId == Agent.defaultId
        // Phase C default-agent gate: limit `capabilities_load` to the
        // configure write tools. Everything else (sandbox, MCP, plugin
        // tools) is hard-stopped with a routing hint so the model
        // self-corrects without burning a turn.
        if isDefaultAgent {
            let configureWrites = await MainActor.run {
                ToolRegistry.configureWriteToolNames
            }
            if !configureWrites.contains(toolId) {
                return .failure(
                    LoadFailure(
                        kind: .rejected,
                        message:
                            "Default agent can only load configuration write tools "
                            + "(`osaurus_*_<verb>`). Use `osaurus_status`, `osaurus_list`, or "
                            + "`osaurus_describe` for reads; nothing else needs `capabilities_load`."
                    )
                )
            }
        }
        let allowedNames = await grantedToolNamesForCurrentAgent()
        let (availability, isEnabled, isBuiltIn, toolSpec) = await MainActor.run {
            (
                ToolRegistry.shared.availability(
                    forTool: toolId,
                    agentAllowedNames: allowedNames
                ),
                ToolRegistry.shared.isGlobalEnabled(toolId),
                ToolRegistry.shared.builtInToolNames.contains(toolId),
                ToolRegistry.shared.specs(forTools: [toolId])
            )
        }
        guard !availability.reasonCodes.contains(.notRegistered) else {
            return .failure(
                LoadFailure(
                    kind: .notFound,
                    message:
                        "Tool '\(toolId)' not found or not registered. availability: \(availability.compactSummary)"
                )
            )
        }
        // Idempotent re-load — checked BEFORE the enabled/grant guards. A
        // tool already in this session's schema (the always-loaded baseline
        // snapshot or an earlier capabilities_load) is ALREADY callable, so
        // re-loading it must return success regardless of the current
        // global-enabled or agent-grant state. Rejecting it here was a
        // guard-ordering bug: the `isEnabled`/`allowedNames` guards fired
        // first, so re-loading an already-baseline tool returned
        // `{"ok":false,"kind":"rejected","message":"… is disabled"}` for a
        // tool the model could already call — which derails the loop (the
        // model believes a working capability failed). The early return also
        // prevents re-buffering, which would re-trigger the deferred-schema
        // bookkeeping and a redundant "callable now" notice.
        if await isAlreadyLoadedInSession(toolId) {
            return .success("Tool '\(toolId)' is already loaded and callable — no action needed.\n")
        }
        guard isBuiltIn || (allowedNames?.contains(toolId) ?? true) else {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Tool '\(toolId)' is not enabled for this agent. availability: \(availability.compactSummary)"
                )
            )
        }
        guard !availability.reasonCodes.contains(.disabled) else {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Tool '\(toolId)' is disabled. availability: \(availability.compactSummary)"
                )
            )
        }
        // Built-in tools are always loaded via alwaysLoadedSpecs, so skip the
        // enabled check — rejecting them here is misleading since they're callable.
        guard isEnabled || isBuiltIn else {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Tool '\(toolId)' is disabled. availability: \(availability.compactSummary)"
                )
            )
        }
        guard let spec = toolSpec.first else {
            return .failure(
                LoadFailure(
                    kind: .notFound,
                    message:
                        "Tool '\(toolId)' not found or not registered. availability: \(availability.compactSummary)"
                )
            )
        }
        if let diagnostic = await CapabilityLoadBuffer.shared.add(spec) {
            return .failure(
                LoadFailure(
                    kind: diagnostic.kind,
                    message: diagnostic.message,
                    field: diagnostic.field,
                    expected: diagnostic.expected
                )
            )
        }
        return .success(
            "Tool '\(toolId)' loaded — callable NOW by name; do not call "
                + "capabilities_discover or capabilities_load for it again.\n"
                + Self.loadedSchemaBlock(for: spec)
        )
    }

    /// Render a freshly loaded tool's callable schema for inclusion in the
    /// `capabilities_load` result — i.e. the conversation *suffix*. Delivering
    /// the schema here (append-only) instead of rewriting the frozen `<tools>`
    /// prefix mid-run is what keeps the paged-KV prefix byte-stable while still
    /// giving the model same-turn visibility: it reads the schema from this
    /// result and calls the tool by name (registry dispatch is name-based, so
    /// the tool is callable even though it is not yet in the rendered `<tools>`
    /// block). The loaded tool folds into `<tools>` on the next user turn via
    /// `frozenAlwaysLoadedNames`.
    ///
    /// The default (configuration) agent only ever loads configure-write tools;
    /// it gets the compact bootstrap skeleton (enums + field names + required
    /// kept, prose dropped) so the suffix stays as lean as its turn-1 baseline.
    /// Every other agent gets the full schema so dynamically loaded
    /// plugin/MCP/sandbox tools call correctly on the first attempt.
    static func loadedSchemaBlock(for spec: Tool) -> String {
        let compact = ChatExecutionContext.currentAgentId == Agent.defaultId
        let rendered = compact ? SystemPromptComposer.compactBootstrapSpec(spec) : spec
        let dict = rendered.toTokenizerToolSpec()
        guard JSONSerialization.isValidJSONObject(dict),
            let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return "Schema for `\(spec.function.name)`:\n\(json)\n"
    }

    /// True when the current session's tool state already carries this
    /// tool (first-turn always-loaded snapshot or a prior mid-session
    /// load). Without a session in context we can't know — return false
    /// and let the buffer path run (harmless, just redundant).
    private func isAlreadyLoadedInSession(_ toolId: String) async -> Bool {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty,
            let state = await SessionToolStateStore.shared.get(sessionId)
        else { return false }
        if state.loadedToolNames.contains(toolId) { return true }
        return state.initialAlwaysLoadedNames?.contains(toolId) ?? false
    }

    /// Nil means this agent has not been seeded by the capability picker
    /// yet, so the historical global-enabled behavior remains in force.
    /// A concrete set is the user's grant boundary and is enforced even
    /// if the model invents a `tool/<name>` ID instead of receiving it
    /// from `capabilities_discover`.
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

    /// Buffer the named tools' specs into the session load buffer so they
    /// become callable after the next drain. Returns the `Auto-loaded tools`
    /// summary line, or an empty string when there is nothing to load. Shared
    /// by the method `toolsUsed` cascade and the skill tool-group auto-load.
    private func bufferToolSpecs(named names: [String]) async -> String {
        guard !names.isEmpty else { return "" }
        let specs = await MainActor.run { ToolRegistry.shared.specs(forTools: names) }
        var loadedNames: [String] = []
        var loadedSpecs: [Tool] = []
        var skippedLines: [String] = []
        for spec in specs {
            if let diagnostic = await CapabilityLoadBuffer.shared.add(spec) {
                skippedLines.append("Skipped tool '\(diagnostic.toolName)': \(diagnostic.message)")
            } else {
                loadedNames.append(spec.function.name)
                loadedSpecs.append(spec)
            }
        }
        var output = ""
        if !loadedNames.isEmpty {
            output += "Auto-loaded tools (callable NOW by name): \(loadedNames.joined(separator: ", "))\n"
            // Append each tool's schema so the model can call them this same
            // turn without a mid-run `<tools>` rewrite (KV-prefix stability).
            for spec in loadedSpecs {
                output += Self.loadedSchemaBlock(for: spec)
            }
        }
        if !skippedLines.isEmpty {
            output += skippedLines.joined(separator: "\n") + "\n"
        }
        return output
    }

    private func loadSkill(_ skillName: String) async -> LoadOutcome {
        if ChatExecutionContext.currentAgentId == Agent.defaultId {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Skill loading is disabled for the configuration agent. "
                        + "Use `capabilities_discover` to find a configuration tool (osaurus_*_<verb>) "
                        + "and load it directly."
                )
            )
        }
        let skill = await MainActor.run {
            SkillManager.shared.skill(named: skillName)
        }
        guard let skill = skill else {
            return .failure(
                LoadFailure(kind: .notFound, message: "Skill '\(skillName)' not found.")
            )
        }
        var output = "## Skill: \(skill.name)\n"
        if !skill.description.isEmpty {
            output += "*\(skill.description)*\n\n"
        }
        output += skill.instructions
        output += "\n\n"

        // A plugin skill governs its sibling tools, so auto-load the plugin's
        // whole dynamic tool group (agent-scoped) instead of forcing a
        // separate `capabilities_load` per tool.
        if let pluginId = skill.pluginId, !pluginId.isEmpty {
            output += await bufferPluginGroup(pluginId: pluginId)
        }
        return .success(output)
    }

    /// Buffer every agent-allowed dynamic tool in `pluginId`'s group, capped
    /// at `enabledManifestToolCap`, and return the human-facing summary line.
    /// Sorted for a deterministic, KV-stable load order and a predictable cap
    /// boundary. Shared by the skill-governed auto-load (`skill/<name>`) and
    /// the `plugin/<id>` group loader.
    ///
    /// Size guard: a very large plugin would otherwise dump every sibling
    /// tool's schema into the live tool channel on a single load — context the
    /// model rarely needs all of, and needless `<tools>` bloat. Past the cap,
    /// the model can pull any remaining tool by id with `capabilities_load`.
    private func bufferPluginGroup(pluginId: String) async -> String {
        let allowedNames = await grantedToolNamesForCurrentAgent()
        let groupToolNames = await MainActor.run {
            ToolRegistry.shared.listDynamicTools()
                .filter { ToolRegistry.shared.groupName(for: $0.name) == pluginId }
                .map(\.name)
                .filter { allowedNames?.contains($0) ?? true }
        }
        .sorted()
        guard !groupToolNames.isEmpty else { return "" }

        let cap = SystemPromptTemplates.enabledManifestToolCap
        if groupToolNames.count > cap {
            let loaded = Array(groupToolNames.prefix(cap))
            let deferred = Array(groupToolNames.dropFirst(cap))
            var summary = await bufferToolSpecs(named: loaded)
            summary +=
                "\(groupToolNames.count) tools belong to this plugin; "
                + "auto-loaded the first \(cap). Load any of the remaining "
                + "\(deferred.count) by id with `capabilities_load` "
                + "(e.g. `tool/\(deferred.first ?? "")`).\n"
            return summary
        }
        return await bufferToolSpecs(named: groupToolNames)
    }

    /// Load a whole plugin tool group by its `plugin/<id>` manifest id. This
    /// is the compact-manifest entry point: the tiered manifest lists one
    /// `plugin/<id>` per plugin, and loading it pulls in the group's tools
    /// plus any governing skill's instructions in a single call.
    private func loadPlugin(_ rawId: String) async -> LoadOutcome {
        if ChatExecutionContext.currentAgentId == Agent.defaultId {
            return .failure(
                LoadFailure(
                    kind: .rejected,
                    message:
                        "Plugin loading is disabled for the configuration agent. "
                        + "Use `capabilities_discover` to find a configuration tool (osaurus_*_<verb>) "
                        + "and load it directly."
                )
            )
        }

        // Resolve the manifest id to a concrete tool-group id. The tiered
        // manifest emits the exact group id, so an exact match is the common
        // path; the case-insensitive and display-name fallbacks tolerate a
        // model that copies the friendly name instead.
        let resolved = await MainActor.run { () -> String? in
            let groupIds = Set(
                ToolRegistry.shared.listDynamicTools()
                    .compactMap { ToolRegistry.shared.groupName(for: $0.name) }
                    .filter { !$0.isEmpty }
            )
            if groupIds.contains(rawId) { return rawId }
            if let ci = groupIds.first(where: { $0.caseInsensitiveCompare(rawId) == .orderedSame }) {
                return ci
            }
            return groupIds.first { gid in
                guard let display = PluginManager.shared.loadedPlugin(for: gid)?.plugin.manifest.name
                else { return false }
                return display.caseInsensitiveCompare(rawId) == .orderedSame
            }
        }
        guard let pluginId = resolved else {
            return .failure(
                LoadFailure(
                    kind: .notFound,
                    message:
                        "Plugin '\(rawId)' not found. Use the `plugin/<id>` exactly as shown in "
                        + "the Enabled capabilities list, or call `capabilities_discover`."
                )
            )
        }

        // Governing skill(s) first — their instructions teach the tool
        // ordering a name-only manifest can't convey. Mirrors `loadSkill`.
        var output = ""
        let governingSkills = await MainActor.run {
            SkillManager.shared.skills.filter { $0.enabled && $0.pluginId == pluginId }
        }
        for skill in governingSkills {
            output += "## Skill: \(skill.name)\n"
            if !skill.description.isEmpty {
                output += "*\(skill.description)*\n\n"
            }
            output += skill.instructions
            output += "\n\n"
        }

        output += await bufferPluginGroup(pluginId: pluginId)
        guard !output.isEmpty else {
            return .failure(
                LoadFailure(
                    kind: .notFound,
                    message: "Plugin '\(pluginId)' has no loadable tools or skills for this agent."
                )
            )
        }
        return .success(output)
    }
}
