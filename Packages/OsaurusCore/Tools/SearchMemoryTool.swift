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

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let scopeRaw = (args["scope"] as? String)?.lowercased()
        else {
            return "Error: 'scope' is required (working|conversations|summaries|graph|all)."
        }

        // Validate arguments BEFORE touching the database. The model
        // gets the same actionable error whether memory is open or not,
        // and tests can exercise the contract without a real DB.
        if let argError = validate(scope: scopeRaw, args: args) {
            return argError
        }

        guard MemoryDatabase.shared.isOpen else {
            return "Memory system is not available."
        }

        switch scopeRaw {
        case "working":
            return await searchWorking(args: args)
        case "conversations":
            return await searchConversations(args: args)
        case "summaries":
            return await searchSummaries(args: args)
        case "graph":
            return await searchGraph(args: args)
        case "all":
            return await searchAll(args: args)
        default:
            // `validate` already rejects unknown scopes; this is unreachable
            // but kept for exhaustiveness in case validate's set diverges.
            return "Error: unknown scope '\(scopeRaw)'. Use working|conversations|summaries|graph|all."
        }
    }

    /// Per-scope argument validation. Returns nil when args are acceptable
    /// or an error string the model can read.
    private func validate(scope: String, args: [String: Any]) -> String? {
        switch scope {
        case "working", "conversations", "summaries", "all":
            guard let q = args["query"] as? String, !q.isEmpty else {
                return "Error: 'query' is required for scope=\(scope)."
            }
            return nil
        case "graph":
            let entityName = args["entity_name"] as? String
            let relation = args["relation"] as? String
            if entityName == nil && relation == nil {
                return "Error: scope=graph requires at least one of 'entity_name' or 'relation'."
            }
            return nil
        default:
            return "Error: unknown scope '\(scope)'. Use working|conversations|summaries|graph|all."
        }
    }

    // MARK: - Per-scope dispatchers

    private func searchWorking(args: [String: Any]) async -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: 'query' is required for scope=working."
        }
        let agentId = args["agent_id"] as? String
        let asOfString = args["as_of"] as? String

        let entries: [MemoryEntry]
        if let asOfString {
            guard let agentId else {
                return "Error: 'agent_id' is required when using 'as_of'."
            }
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
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: 'query' is required for scope=conversations."
        }
        let agentId = args["agent_id"] as? String
        let days = (args["days"] as? Int) ?? 30

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
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: 'query' is required for scope=summaries."
        }
        let agentId = args["agent_id"] as? String
        let days = (args["days"] as? Int) ?? 30

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
        let entityName = args["entity_name"] as? String
        let relation = args["relation"] as? String
        let depth = (args["depth"] as? NSNumber)?.intValue ?? 2

        guard entityName != nil || relation != nil else {
            return "Error: scope=graph requires at least one of 'entity_name' or 'relation'."
        }

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
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: 'query' is required for scope=all."
        }

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
