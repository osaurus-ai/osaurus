//
//  SearchWorkingMemoryTool.swift
//  osaurus
//
//  Recall tool: searches structured memory entries (Layer 2)
//  across all agents or scoped to a specific agent.
//

import Foundation

final class SearchWorkingMemoryTool: OsaurusTool, @unchecked Sendable {
    let name = "search_working_memory"
    let description =
        "Search structured memory entries (facts, preferences, decisions, corrections, commitments). Returns matching entries with type, content, and confidence."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query to find relevant memory entries"),
            ]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string("Optional: scope search to a specific agent ID. Omit to search all agents."),
            ]),
            "as_of": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: ISO 8601 datetime. If provided, returns memories that were active at that point in time instead of current memories."
                ),
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
        let asOfString = args["as_of"] as? String

        guard MemoryDatabase.shared.isOpen else {
            return "Memory system is not available."
        }

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
}
