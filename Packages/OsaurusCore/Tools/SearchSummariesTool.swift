//
//  SearchSummariesTool.swift
//  osaurus
//
//  Recall tool: searches conversation summaries (Layer 3)
//  across all agents or scoped to a specific agent.
//

import Foundation

final class SearchSummariesTool: OsaurusTool, @unchecked Sendable {
    let name = "search_summaries"
    let description = "Search past conversation summaries. Returns matching summaries with dates and agents."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query to find relevant conversation summaries"),
            ]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string("Optional: scope search to a specific agent ID"),
            ]),
            "days": .object([
                "type": .string("integer"),
                "description": .string("Optional: limit search to last N days (default: 30)"),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let query = args["query"] as? String
        else {
            return "Error: 'query' parameter is required."
        }

        let agentId = args["agent_id"] as? String
        let days = (args["days"] as? Int) ?? 30

        guard MemoryDatabase.shared.isOpen else {
            return "Memory system is not available."
        }

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
}
