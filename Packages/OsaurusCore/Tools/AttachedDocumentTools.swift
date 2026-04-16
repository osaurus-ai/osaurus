//
//  AttachedDocumentTools.swift
//  osaurus
//
//  Tools that expose full attached-document contents incrementally to local
//  models, avoiding giant inline prompts while preserving attachment access.
//

import Foundation

enum AttachedDocumentTools {
    static let toolNames = ["search_attached_documents", "read_attached_document"]

    @MainActor
    static func registerIfNeeded() {
        ToolRegistry.shared.register(SearchAttachedDocumentsTool())
        ToolRegistry.shared.register(ReadAttachedDocumentTool())
    }
}

final class SearchAttachedDocumentsTool: OsaurusTool, @unchecked Sendable {
    let name = "search_attached_documents"
    let description =
        "Search attached document contents by keyword or phrase. Use this to locate relevant excerpts in user-attached documents before answering."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "attachment_ids": .object([
                "type": .string("array"),
                "description": .string(
                    "Attachment IDs to search. Use the IDs shown in the attached document manifest."
                ),
                "items": .object([
                    "type": .string("string")
                ]),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("Keyword, phrase, or concept to find in the attached documents."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of matching excerpts to return (1-8). Default: 3."),
            ]),
        ]),
        "required": .array([.string("attachment_ids"), .string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let args = parseArguments(argumentsJSON)
        let attachmentIds = coerceStringArray(args?["attachment_ids"]) ?? []
        let query = (args?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let maxResults = coerceInt(args?["max_results"]) ?? 3

        guard !attachmentIds.isEmpty else {
            return "Error: 'attachment_ids' is required."
        }
        guard !query.isEmpty else {
            return "Error: 'query' is required."
        }

        let hits = await AttachedDocumentStore.shared.search(
            attachmentIds: attachmentIds,
            query: query,
            maxResults: maxResults
        )

        guard !hits.isEmpty else {
            return "No matching excerpts found in the requested attached documents."
        }

        var lines: [String] = ["Found \(hits.count) matching attached-document excerpt(s):"]
        for hit in hits {
            lines.append("")
            lines.append(
                "- attachment_id: \(hit.attachmentId) | name: \(hit.filename) | chunk: \(hit.chunkIndex)/\(hit.chunkCount) | score: \(hit.score)"
            )
            lines.append(hit.excerpt)
        }

        return lines.joined(separator: "\n")
    }
}

final class ReadAttachedDocumentTool: OsaurusTool, @unchecked Sendable {
    let name = "read_attached_document"
    let description =
        "Read a specific chunk from an attached document. Use after search_attached_documents or when you need to inspect a document sequentially."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "attachment_id": .object([
                "type": .string("string"),
                "description": .string("Attachment ID to read from."),
            ]),
            "chunk_index": .object([
                "type": .string("integer"),
                "description": .string("1-based chunk index to read."),
            ]),
        ]),
        "required": .array([.string("attachment_id"), .string("chunk_index")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let args = parseArguments(argumentsJSON)
        let attachmentId = (args?["attachment_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chunkIndex = coerceInt(args?["chunk_index"]) ?? 0

        guard !attachmentId.isEmpty else {
            return "Error: 'attachment_id' is required."
        }
        guard chunkIndex > 0 else {
            return "Error: 'chunk_index' must be a positive integer."
        }

        guard let chunk = await AttachedDocumentStore.shared.read(attachmentId: attachmentId, chunkIndex: chunkIndex)
        else {
            return "Error: attached document or chunk not found."
        }

        return """
            Attached document chunk \(chunk.chunkIndex)/\(chunk.chunkCount)
            attachment_id: \(chunk.attachmentId)
            name: \(chunk.filename)

            \(chunk.content)
            """
    }
}
