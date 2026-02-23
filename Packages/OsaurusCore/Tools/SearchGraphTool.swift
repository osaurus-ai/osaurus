//
//  SearchGraphTool.swift
//  osaurus
//
//  Recall tool: searches the knowledge graph for entity relationships
//  via multi-hop traversal or relation-type queries.
//

import Foundation

final class SearchGraphTool: OsaurusTool, @unchecked Sendable {
    let name = "search_graph"
    let description =
        "Search the knowledge graph for entity relationships. Traverses connections between people, companies, places, projects, tools, and concepts. Use to answer questions like 'Who does Sarah work with?' or 'What projects use React?'."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "entity_name": .object([
                "type": .string("string"),
                "description": .string(
                    "Name of an entity to look up and traverse relationships from (e.g. a person, company, project name)."
                ),
            ]),
            "relation": .object([
                "type": .string("string"),
                "description": .string(
                    "Type of relationship to search for (e.g. works_on, lives_in, uses, knows, manages, created_by, part_of). Returns all active relationships of this type."
                ),
            ]),
            "depth": .object([
                "type": .string("integer"),
                "description": .string("How many hops to traverse from the entity (1-4). Default: 2."),
            ]),
        ]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let args = parseArguments(argumentsJSON)
        let entityName = args?["entity_name"] as? String
        let relation = args?["relation"] as? String
        let depth = (args?["depth"] as? NSNumber)?.intValue ?? 2

        guard entityName != nil || relation != nil else {
            return "Error: at least one of 'entity_name' or 'relation' is required."
        }

        guard MemoryDatabase.shared.isOpen else {
            return "Memory system is not available."
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
}
