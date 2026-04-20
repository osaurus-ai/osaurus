//
//  SearchMemoryTool.swift
//  osaurus
//
//  Unified recall tool: a single `search_memory(scope, query)` that
//  dispatches to the right `MemorySearchService` backend by scope.
//
//  Scopes:
//    - `working`       — structured memory entries (facts, preferences, ...).
//    - `conversations` — raw transcript excerpts.
//    - `summaries`     — per-conversation summaries.
//    - `graph`         — entity-relationship knowledge graph.
//    - `all`           — working + conversations + summaries (graph excluded
//                        because it needs `entity_name`/`relation`, not a
//                        free-text query).
//

import Foundation

final class SearchMemoryTool: OsaurusTool, @unchecked Sendable {
    let name = "search_memory"
    let description =
        "Search the agent's persistent memory across past sessions. "
        + "Pick a `scope`: `working` for structured facts/preferences/decisions, "
        + "`conversations` for transcript excerpts, `summaries` for per-session summaries, "
        + "`graph` for entity relationships, or `all` to run working+conversations+summaries together. "
        + "Use this only when the user references something the current chat does not contain."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("working"),
                    .string("conversations"),
                    .string("summaries"),
                    .string("graph"),
                    .string("all"),
                ]),
                "description": .string(
                    "Which memory layer to search: working|conversations|summaries|graph|all."
                ),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "Natural-language query. Required for working/conversations/summaries/all."
                ),
            ]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: restrict to a specific agent ID. Omit to search across all agents."
                ),
            ]),
            "days": .object([
                "type": .string("integer"),
                "description": .string(
                    "For conversations/summaries: limit to last N days (default 30)."
                ),
            ]),
            "as_of": .object([
                "type": .string("string"),
                "description": .string(
                    "For working scope only: ISO 8601 datetime to view memories as they were at that point."
                ),
            ]),
            "entity_name": .object([
                "type": .string("string"),
                "description": .string(
                    "For graph scope: entity to traverse from (person, project, place, ...)."
                ),
            ]),
            "relation": .object([
                "type": .string("string"),
                "description": .string(
                    "For graph scope: relation type to filter by (works_on, uses, knows, ...)."
                ),
            ]),
            "depth": .object([
                "type": .string("integer"),
                "description": .string("For graph scope: hops to traverse (1-4, default 2)."),
            ]),
        ]),
        "required": .array([.string("scope")]),
    ])

    private static let allScopes: Set<String> = ["working", "conversations", "summaries", "graph", "all"]
    private static let scopeListPipe = "working|conversations|summaries|graph|all"

    /// Param-name -> set of scopes where it has any effect. Used to reject
    /// scope-incompatible params with `invalid_args` so the model doesn't
    /// think a silently-ignored `as_of` actually applied.
    private static let scopeAllowedParams: [String: Set<String>] = [
        "scope": allScopes,
        "agent_id": ["working", "conversations", "summaries", "all"],
        "query": ["working", "conversations", "summaries", "all"],
        "days": ["conversations", "summaries", "all"],
        "as_of": ["working"],
        "entity_name": ["graph"],
        "relation": ["graph"],
        "depth": ["graph"],
    ]

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        guard let scopeRaw = (args["scope"] as? String)?.lowercased() else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing required argument `scope`. Use one of: \(Self.scopeListPipe).",
                field: "scope",
                expected: "one of \(Self.scopeListPipe)",
                tool: name
            )
        }

        // Reject scope-incompatible params up front so the model isn't
        // tricked by silent ignores. E.g. `as_of` only applies to
        // `scope=working`; passing it with `scope=conversations` used to
        // be silently dropped, leaving the model thinking the temporal
        // filter took effect.
        for key in args.keys {
            guard let allowed = Self.scopeAllowedParams[key] else { continue }
            if !allowed.contains(scopeRaw) {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`\(key)` is not valid with `scope=\(scopeRaw)`. "
                        + "Valid scopes for `\(key)`: \(allowed.sorted().joined(separator: ", ")).",
                    field: key,
                    expected: "scope in \(allowed.sorted().joined(separator: "|"))",
                    tool: name
                )
            }
        }

        // Validate scope-required arguments before touching the database
        // (so tests / no-DB environments still get the right error).
        if let argError = validate(scope: scopeRaw, args: args) {
            return argError
        }

        guard MemoryDatabase.shared.isOpen else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Memory system is not available.",
                tool: name,
                retryable: true
            )
        }

        // Each per-scope dispatcher returns raw prose; we wrap once here.
        let text: String
        switch scopeRaw {
        case "working":
            text = await searchWorking(args: args)
        case "conversations":
            text = await searchConversations(args: args)
        case "summaries":
            text = await searchSummaries(args: args)
        case "graph":
            text = await searchGraph(args: args)
        case "all":
            text = await searchAll(args: args)
        default:
            return unknownScopeFailure(scopeRaw)
        }
        return ToolEnvelope.success(tool: name, text: text)
    }

    private func unknownScopeFailure(_ scope: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown scope `\(scope)`. Use one of: \(Self.scopeListPipe).",
            field: "scope",
            expected: "one of \(Self.scopeListPipe)",
            tool: name
        )
    }

    /// Per-scope required-argument validation. Returns nil when args are
    /// acceptable or a ready-to-return failure envelope. The cross-scope
    /// rejection (`as_of` on the wrong scope, etc.) lives in `execute` —
    /// this function only enforces the required keys per scope.
    private func validate(scope: String, args: [String: Any]) -> String? {
        switch scope {
        case "working", "conversations", "summaries", "all":
            guard let q = args["query"] as? String, !q.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Missing required argument `query` for scope=\(scope).",
                    field: "query",
                    expected: "non-empty natural-language query string",
                    tool: name
                )
            }
            // `as_of` (working-only) requires a specific agent — without it
            // the temporal lookup has nothing to anchor against.
            if scope == "working", args["as_of"] != nil, args["agent_id"] == nil {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`agent_id` is required when `as_of` is specified.",
                    field: "agent_id",
                    expected: "agent UUID string",
                    tool: name
                )
            }
            return nil
        case "graph":
            let entityName = args["entity_name"] as? String
            let relation = args["relation"] as? String
            if entityName == nil && relation == nil {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "scope=graph requires at least one of `entity_name` or `relation`.",
                    field: "entity_name",
                    expected: "either `entity_name` or `relation` (or both)",
                    tool: name
                )
            }
            return nil
        default:
            return unknownScopeFailure(scope)
        }
    }

    // MARK: - Per-scope dispatchers

    /// Caller has already verified `query` (and `agent_id` when `as_of`
    /// is set) via `validate(scope:args:)`. This dispatcher is for
    /// scope=working only.
    private func searchWorking(args: [String: Any]) async -> String {
        let query = args["query"] as? String ?? ""
        let agentId = args["agent_id"] as? String
        let asOfString = args["as_of"] as? String

        let entries: [MemoryEntry]
        if let asOfString, let agentId {
            let temporal = (try? MemoryDatabase.shared.loadEntriesAsOf(agentId: agentId, asOf: asOfString)) ?? []
            entries = temporal.filter { $0.content.localizedCaseInsensitiveContains(query) }
        } else {
            entries = await MemorySearchService.shared.searchMemoryEntries(
                query: query,
                agentId: agentId
            )
        }

        if entries.isEmpty {
            return "No memory entries found matching '\(query)'."
        }

        var result = "Found \(entries.count) memory entries:\n\n"
        for entry in entries {
            result += "- [\(entry.type.displayName)] \(entry.content)"
            result += " (confidence: \(String(format: "%.1f", entry.confidence))"
            if !entry.createdAt.isEmpty {
                result += ", created: \(entry.createdAt)"
            }
            if !entry.validFrom.isEmpty {
                result += ", valid_from: \(entry.validFrom)"
            }
            if let validUntil = entry.validUntil {
                result += ", valid_until: \(validUntil)"
            }
            result += ")\n"
        }
        return result
    }

    private func searchConversations(args: [String: Any]) async -> String {
        let query = args["query"] as? String ?? ""
        let agentId = args["agent_id"] as? String
        let days = ArgumentCoercion.int(args["days"]) ?? 30

        let chunks = await MemorySearchService.shared.searchConversations(
            query: query,
            agentId: agentId,
            days: days
        )

        if chunks.isEmpty {
            return "No conversation excerpts found matching '\(query)' in the last \(days) days."
        }

        var result = "Found \(chunks.count) conversation excerpts:\n\n"
        for chunk in chunks {
            let title = chunk.conversationTitle ?? "Untitled"
            result += "[\(chunk.createdAt)] \(title) (\(chunk.role)):\n"
            let preview = chunk.content.prefix(300)
            result += "\(preview)\(chunk.content.count > 300 ? "..." : "")\n\n"
        }
        return result
    }

    private func searchSummaries(args: [String: Any]) async -> String {
        let query = args["query"] as? String ?? ""
        let agentId = args["agent_id"] as? String
        let days = ArgumentCoercion.int(args["days"]) ?? 30

        let summaries = await MemorySearchService.shared.searchSummaries(
            query: query,
            agentId: agentId,
            days: days
        )

        if summaries.isEmpty {
            return "No conversation summaries found matching '\(query)' in the last \(days) days."
        }

        var result = "Found \(summaries.count) conversation summaries:\n\n"
        for summary in summaries {
            result += "[\(summary.conversationAt)] Agent: \(summary.agentId)\n"
            result += "\(summary.summary)\n\n"
        }
        return result
    }

    private func searchGraph(args: [String: Any]) async -> String {
        // Caller validated that at least one of entity_name/relation exists.
        let entityName = args["entity_name"] as? String
        let relation = args["relation"] as? String
        let rawDepth = ArgumentCoercion.int(args["depth"]) ?? 2
        let depth = max(1, min(rawDepth, 4))

        let results = await MemorySearchService.shared.searchGraph(
            entityName: entityName,
            relation: relation,
            depth: depth
        )

        if results.isEmpty {
            if let entityName {
                return "No graph connections found for '\(entityName)'."
            } else if let relation {
                return "No active '\(relation)' relationships found."
            }
            return "No results found."
        }

        var output = "Found \(results.count) graph connection(s):\n\n"
        for result in results {
            output += "- \(result.path) [\(result.entityType), depth: \(result.depth)]\n"
        }
        return output
    }

    /// Run working + conversations + summaries with a shared `query` and
    /// concatenate the results. Sequential — `[String: Any]` isn't Sendable
    /// so `async let` doesn't apply, and the SQLite backends are quick
    /// enough that parallelism wouldn't move the needle on turn time.
    private func searchAll(args: [String: Any]) async -> String {
        let working = await searchWorking(args: args)
        let conversations = await searchConversations(args: args)
        let summaries = await searchSummaries(args: args)

        return [
            "## Working memory\n\(working)",
            "## Conversations\n\(conversations)",
            "## Summaries\n\(summaries)",
        ].joined(separator: "\n\n")
    }
}
