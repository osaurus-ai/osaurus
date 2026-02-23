//
//  SearchConversationsTool.swift
//  osaurus
//
//  Recall tool: searches full conversation transcripts (Layer 4)
//  across all agents or scoped to a specific agent.
//

import Foundation

final class SearchConversationsTool: OsaurusTool, @unchecked Sendable {
    let name = "search_conversations"
    let description = "Search past conversation transcripts. Returns matching excerpts with timestamps and context."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query to find relevant conversation excerpts"),
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
}
