//
//  PalaceTools.swift
//  osaurus
//
//  Model-facing tools for the Palace verbatim-memory subsystem.
//  All nine register as built-ins; SystemPromptComposer strips them from
//  the model-visible schema when `palace.enabled` is false, and every
//  execute() re-checks the flag (defense in depth for frozen schemas,
//  manual tool selection, and direct /mcp/call surfaces).
//

import Foundation

/// Shared preflight: nil when Palace is usable, otherwise a ready-to-return
/// failure envelope.
private func palaceDisabledEnvelope(tool: String) -> String? {
    guard !PalaceConfigurationStore.load().enabled else { return nil }
    return ToolEnvelope.failure(
        kind: .unavailable,
        message:
            "Palace is disabled. Enable it by setting \"enabled\": true in "
            + "~/.osaurus/config/palace.json.",
        tool: tool,
        retryable: false
    )
}

private func palaceErrorEnvelope(_ error: Error, tool: String) -> String {
    ToolEnvelope.failure(
        kind: .executionError,
        message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
        tool: tool,
        retryable: false
    )
}

// MARK: - palace_status

final class PalaceStatusTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_status"
    let description =
        "Report Palace verbatim-memory status: wing/room/drawer counts and embedding coverage."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        do {
            let status = try await PalaceService.shared.status()
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "wings": status.wingCount,
                    "rooms": status.roomCount,
                    "drawers": status.drawerCount,
                    "embedded_drawers": status.embeddedDrawerCount,
                    "embedding_backend": status.embeddingBackend,
                ]
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_add_drawer

final class PalaceAddDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_add_drawer"
    let description =
        "File a VERBATIM text chunk into the Palace archive. Content is stored exactly as "
        + "given (no summarizing). Duplicate content in the same wing+room is deduplicated. "
        + "Use `wing` for the project/person scope and `room` for the topic."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "content": .object([
                "type": .string("string"),
                "description": .string("The exact text to preserve, verbatim."),
            ]),
            "wing": .object([
                "type": .string("string"),
                "description": .string(
                    "Scope slug (e.g. project name). Defaults to the configured default wing."
                ),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Topic slug within the wing. Defaults to `general`."),
            ]),
            "source_file": .object([
                "type": .string("string"),
                "description": .string("Optional origin path or URL for attribution."),
            ]),
            "metadata_json": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional JSON object string with extra metadata (tags, session id)."
                ),
            ]),
        ]),
        "required": .array([.string("content")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let contentReq = requireString(
            args,
            "content",
            expected: "non-empty text to store",
            tool: name
        )
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }

        // metadata_json, when present, must parse as a JSON object.
        var metadataJSON: String?
        if let raw = args["metadata_json"] as? String, !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
            else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`metadata_json` must be a JSON object string.",
                    field: "metadata_json",
                    expected: "e.g. {\"tags\": [\"dream\"]}",
                    tool: name
                )
            }
            metadataJSON = raw
        }

        do {
            let result = try await PalaceService.shared.addDrawer(
                content: content,
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                sourceFile: args["source_file"] as? String,
                metadataJSON: metadataJSON
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "drawer_id": result.drawer.id,
                    "deduped": result.deduped,
                    "embedded": result.embedded,
                ]
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_get_drawer

final class PalaceGetDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_get_drawer"
    let description = "Fetch the full verbatim content and metadata of one Palace drawer by id."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Drawer id from palace_search / palace_add_drawer / palace_list_drawers."
                ),
            ])
        ]),
        "required": .array([.string("drawer_id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        do {
            guard let drawer = try await PalaceService.shared.getDrawer(id: id) else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No drawer with id \(id).",
                    tool: name
                )
            }
            var result: [String: Any] = [
                "drawer_id": drawer.id,
                "content": drawer.content,
                "content_hash": drawer.contentHash,
                "created_at": drawer.createdAt,
                "added_by": drawer.addedBy,
            ]
            if let sourceFile = drawer.sourceFile { result["source_file"] = sourceFile }
            if let metadata = drawer.metadataJSON { result["metadata_json"] = metadata }
            return ToolEnvelope.success(tool: name, result: result)
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_update_drawer

final class PalaceUpdateDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_update_drawer"
    let description =
        "Replace the verbatim content of an existing Palace drawer (re-hashes and re-embeds)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string("Drawer id to update."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("The new exact text (full replacement)."),
            ]),
        ]),
        "required": .array([.string("drawer_id"), .string("content")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        let contentReq = requireString(
            args,
            "content",
            expected: "non-empty replacement text",
            tool: name
        )
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            let updated = try await PalaceService.shared.updateDrawer(id: id, content: content)
            return ToolEnvelope.success(
                tool: name,
                result: ["drawer_id": updated.id, "content_hash": updated.contentHash]
            )
        } catch PalaceServiceError.drawerNotFound {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "No drawer with id \(id).",
                tool: name
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_delete_drawer

final class PalaceDeleteDrawerTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_delete_drawer"
    let description =
        "Permanently delete one Palace drawer (and its search index entries) by id."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "drawer_id": .object([
                "type": .string("string"),
                "description": .string("Drawer id to delete."),
            ])
        ]),
        "required": .array([.string("drawer_id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "drawer_id", expected: "a drawer id string", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        do {
            let deleted = try await PalaceService.shared.deleteDrawer(id: id)
            guard deleted else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No drawer with id \(id).",
                    tool: name
                )
            }
            return ToolEnvelope.success(tool: name, result: ["deleted": true, "drawer_id": id])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_list_wings

final class PalaceListWingsTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_wings"
    let description = "List all Palace wings (top-level scopes)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        do {
            let wings = try await PalaceService.shared.listWings()
            let entries = wings.map { ["name": $0.name, "kind": $0.kind] }
            return ToolEnvelope.success(tool: name, result: ["wings": entries])
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_list_rooms

final class PalaceListRoomsTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_rooms"
    let description = "List the rooms (topics) inside one Palace wing."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "wing": .object([
                "type": .string("string"),
                "description": .string("Wing slug to list rooms for."),
            ])
        ]),
        "required": .array([.string("wing")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let wingReq = requireString(args, "wing", expected: "a wing slug", tool: name)
        guard case .value(let wing) = wingReq else { return wingReq.failureEnvelope ?? "" }
        do {
            let rooms = try await PalaceService.shared.listRooms(wing: wing)
            return ToolEnvelope.success(
                tool: name,
                result: ["wing": wing, "rooms": rooms.map(\.name)]
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_list_drawers

final class PalaceListDrawersTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_list_drawers"
    let description =
        "List Palace drawers (newest first), optionally scoped by wing and room. Returns "
        + "previews; use palace_get_drawer for full content."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "wing": .object([
                "type": .string("string"),
                "description": .string("Optional wing slug filter."),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Optional room slug filter (requires wing)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max results (default 20, max 100)."),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Pagination offset (default 0)."),
            ]),
        ]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        if args["room"] != nil, args["wing"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`room` requires `wing`.",
                field: "room",
                expected: "provide `wing` when filtering by room",
                tool: name
            )
        }
        let limit = max(1, min(100, ArgumentCoercion.int(args["limit"]) ?? 20))
        let offset = max(0, ArgumentCoercion.int(args["offset"]) ?? 0)
        do {
            let drawers = try await PalaceService.shared.listDrawers(
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                limit: limit,
                offset: offset
            )
            let entries = drawers.map { drawer -> [String: Any] in
                [
                    "drawer_id": drawer.id,
                    "preview": String(drawer.content.prefix(160)),
                    "created_at": drawer.createdAt,
                ]
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["drawers": entries, "count": entries.count]
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}

// MARK: - palace_search

final class PalaceSearchTool: OsaurusTool, @unchecked Sendable {
    let name = "palace_search"
    let description =
        "Semantic + keyword search over the Palace verbatim archive. Use when the user asks "
        + "for exact wording, quotes, or archived material. Scope with `wing`/`room` when "
        + "known. Returns previews with drawer ids; use palace_get_drawer for full text."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Natural-language query."),
            ]),
            "wing": .object([
                "type": .string("string"),
                "description": .string("Optional wing slug scope."),
            ]),
            "room": .object([
                "type": .string("string"),
                "description": .string("Optional room slug scope (requires wing)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max results (default from palace.json, max 50)."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let envelope = palaceDisabledEnvelope(tool: name) { return envelope }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let queryReq = requireString(args, "query", expected: "non-empty query text", tool: name)
        guard case .value(let query) = queryReq else { return queryReq.failureEnvelope ?? "" }
        if args["room"] != nil, args["wing"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`room` requires `wing`.",
                field: "room",
                expected: "provide `wing` when scoping by room",
                tool: name
            )
        }
        do {
            let hits = try await PalaceService.shared.search(
                query: query,
                wing: args["wing"] as? String,
                room: args["room"] as? String,
                limit: ArgumentCoercion.int(args["limit"])
            )
            if hits.isEmpty {
                return ToolEnvelope.success(tool: name, text: "No drawers match '\(query)'.")
            }
            let entries = hits.map { hit -> [String: Any] in
                [
                    "drawer_id": hit.drawer.id,
                    "wing": hit.wingName,
                    "room": hit.roomName,
                    "score": (hit.score * 1000).rounded() / 1000,
                    "match": hit.matchType.rawValue,
                    "preview": String(hit.drawer.content.prefix(300)),
                ]
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["hits": entries, "count": entries.count]
            )
        } catch {
            return palaceErrorEnvelope(error, tool: name)
        }
    }
}
