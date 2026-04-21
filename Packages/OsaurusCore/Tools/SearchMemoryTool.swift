//
//  SearchMemoryTool.swift
//  osaurus
//
//  v2 unified recall tool: a single `search_memory(scope, query)` that
//  dispatches to the right memory layer.
//
//  Scopes (collapsed from v1's five):
//    - `pinned`     — salience-scored facts the system has promoted
//    - `episodes`   — per-session digests
//    - `transcript` — raw conversation turns (for "what did I literally say")
//
//  v1's `working`, `summaries`, `all`, and `graph` scopes are gone:
//    - `working`    → subsumed by `pinned`
//    - `summaries`  → renamed to `episodes`
//    - `all`        → just call `pinned` and/or `episodes` explicitly; the
//                     planner already picks the right slice for context
//                     injection, and the model can still chain calls
//    - `graph`      → the v2 graph is internal-only (used for entity hits
//                     in the relevance gate); not exposed as a tool scope
//

import Foundation

final class SearchMemoryTool: OsaurusTool, @unchecked Sendable {
    let name = "search_memory"
    let description =
        "Search the agent's persistent memory across past sessions. "
        + "Pick a `scope`: `pinned` for high-salience facts about the user, "
        + "`episodes` for past-session digests, or `transcript` for raw "
        + "conversation excerpts. Use this only when the user references "
        + "something the current chat does not contain."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("pinned"),
                    .string("episodes"),
                    .string("transcript"),
                ]),
                "description": .string("Which memory layer to search: pinned|episodes|transcript."),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("Natural-language query."),
            ]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: restrict to a specific agent ID. Omit to search across all agents."
                ),
            ]),
            "days": .object([
                "type": .string("integer"),
                "description": .string("For transcript: limit to last N days (default 365)."),
            ]),
            "top_k": .object([
                "type": .string("integer"),
                "description": .string("Maximum results to return (default 10, max 50)."),
            ]),
        ]),
        "required": .array([.string("scope"), .string("query")]),
    ])

    private static let allScopes: Set<String> = ["pinned", "episodes", "transcript"]
    private static let scopeListPipe = "pinned|episodes|transcript"

    private static let scopeAllowedParams: [String: Set<String>] = [
        "scope": allScopes,
        "agent_id": allScopes,
        "query": allScopes,
        "days": ["transcript"],
        "top_k": allScopes,
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

        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing required argument `query`.",
                field: "query",
                expected: "non-empty natural-language query string",
                tool: name
            )
        }

        guard Self.allScopes.contains(scopeRaw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown scope `\(scopeRaw)`. Use one of: \(Self.scopeListPipe).",
                field: "scope",
                expected: "one of \(Self.scopeListPipe)",
                tool: name
            )
        }

        guard MemoryDatabase.shared.isOpen else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Memory system is not available.",
                tool: name,
                retryable: true
            )
        }

        let agentId = args["agent_id"] as? String
        let topK = max(1, min(50, ArgumentCoercion.int(args["top_k"]) ?? 10))

        let text: String
        switch scopeRaw {
        case "pinned":
            text = await searchPinned(query: query, agentId: agentId, topK: topK)
        case "episodes":
            text = await searchEpisodes(query: query, agentId: agentId, topK: topK)
        case "transcript":
            let days = max(1, min(3650, ArgumentCoercion.int(args["days"]) ?? 365))
            text = await searchTranscript(query: query, agentId: agentId, days: days, topK: topK)
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown scope `\(scopeRaw)`.",
                tool: name
            )
        }
        return ToolEnvelope.success(tool: name, text: text)
    }

    private func searchPinned(query: String, agentId: String?, topK: Int) async -> String {
        let facts = await MemorySearchService.shared.searchPinnedFacts(
            query: query,
            agentId: agentId,
            topK: topK
        )
        if facts.isEmpty { return "No pinned facts match '\(query)'." }
        var out = "Found \(facts.count) pinned fact(s):\n\n"
        for fact in facts {
            out += "- \(fact.content) (salience: \(String(format: "%.2f", fact.salience)))\n"
        }
        return out
    }

    private func searchEpisodes(query: String, agentId: String?, topK: Int) async -> String {
        let episodes = await MemorySearchService.shared.searchEpisodes(
            query: query,
            agentId: agentId,
            topK: topK
        )
        if episodes.isEmpty { return "No episodes match '\(query)'." }
        var out = "Found \(episodes.count) episode(s):\n\n"
        for ep in episodes {
            out += "[\(ep.conversationAt.prefix(10))] \(ep.summary)\n"
            if !ep.topicsCSV.isEmpty {
                out += "  topics: \(ep.topicsCSV)\n"
            }
            if !ep.decisions.isEmpty {
                out += "  decisions: \(ep.decisions.replacingOccurrences(of: "\n", with: "; "))\n"
            }
            out += "\n"
        }
        return out
    }

    private func searchTranscript(query: String, agentId: String?, days: Int, topK: Int) async -> String {
        let turns = await MemorySearchService.shared.searchTranscript(
            query: query,
            agentId: agentId,
            days: days,
            topK: topK
        )
        if turns.isEmpty {
            return "No transcript turns match '\(query)' in the last \(days) days."
        }
        var out = "Found \(turns.count) transcript excerpt(s):\n\n"
        for turn in turns {
            let title = turn.conversationTitle ?? "Untitled"
            out += "[\(turn.createdAt.prefix(19))] \(title) (\(turn.role)):\n"
            let preview = turn.content.prefix(300)
            out += "\(preview)\(turn.content.count > 300 ? "..." : "")\n\n"
        }
        return out
    }
}
