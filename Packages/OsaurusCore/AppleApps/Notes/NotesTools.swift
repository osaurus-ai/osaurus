//
//  NotesTools.swift
//  osaurus
//
//  Built-in `notes_*` tools (per-agent opt-in via `AppleApp.notes`).
//

import Foundation

enum NotesToolFactory {
    static func makeTools(service: NotesServicing = AppleScriptNotesService()) -> [OsaurusTool] {
        [
            NotesFoldersTool(service: service),
            NotesListTool(service: service),
            NotesSearchTool(service: service),
            NotesReadTool(service: service),
            NotesCreateTool(service: service),
            NotesAppendTool(service: service),
            NotesOpenTool(service: service),
        ]
    }

    static let previewLength = 200

    /// Sort newest-modified first, page, then attach previews for the page.
    static func page(_ notes: [NoteSummary], limit: Int, service: NotesServicing) async throws -> AppleToolPayload {
        let sorted = notes.sorted { ($0.modified ?? "") > ($1.modified ?? "") }
        let page = AppleServiceSupport.page(sorted, limit: limit)
        let previews = try await service.previews(ids: page.items.map(\.id), length: previewLength)
        let items = page.items.map { n in
            NoteSummary(
                id: n.id, title: n.title, folder: n.folder, created: n.created, modified: n.modified,
                preview: previews[n.id]
            )
        }
        return AppleToolPayload([
            "notes": items, "count": items.count, "total": page.total, "truncated": page.truncated,
        ])
    }
}

final class NotesFoldersTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_folders",
            description: "List Apple Notes folders with their account and note count.",
            parameters: AppleSchema.object([:]), isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let folders = try await service.folders()
        return AppleToolPayload(["folders": folders, "count": folders.count])
    }
}

final class NotesListTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    static let defaultLimit = 25
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_list",
            description: "List notes, newest modified first, optionally within one folder. Each row has a stable `id` for notes_read / notes_append / notes_open and a short text preview.",
            parameters: AppleSchema.object([
                "folder": AppleSchema.string("Folder name or folder id (from notes_folders) to restrict to. Omit for all folders (Recently Deleted is never included)."),
                "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
            ]),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let folder = try AppleArgs.string(args, "folder")
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let notes = try await service.listNotes(folder: folder)
        return try await NotesToolFactory.page(notes, limit: limit, service: service)
    }
}

final class NotesSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    static let defaultLimit = 25
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_search",
            description: "Search notes by title (and body text when `include_body` is true) — case-insensitive substring match. Returns ids and previews.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("Text to look for."),
                    "folder": AppleSchema.string("Restrict to one folder (name or id from notes_folders)."),
                    "include_body": AppleSchema.boolean("Also match note body text (slower on large libraries; default true)."),
                    "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
                ],
                required: ["query"]
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.requiredString(args, "query", expected: "search text")
        let folder = try AppleArgs.string(args, "folder")
        let includeBody = try AppleArgs.bool(args, "include_body") ?? true
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let all = try await service.listNotes(folder: folder)
        var matched = all.filter { AppleServiceSupport.matches($0.title, query: query) }
        if includeBody {
            let matchedIds = Set(matched.map(\.id))
            let rest = all.filter { !matchedIds.contains($0.id) }
            // Body search: pull full previews in batches and match in Swift so the
            // AppleScript stays a simple bulk read.
            let bodies = try await service.previews(ids: rest.map(\.id), length: 20_000)
            matched += rest.filter { AppleServiceSupport.matches(bodies[$0.id], query: query) }
        }
        var payload = try await NotesToolFactory.page(matched, limit: limit, service: service)
        if var dict = payload.result as? [String: Any] {
            dict["query"] = query
            payload = AppleToolPayload(dict, warnings: payload.warnings)
        }
        return payload
    }
}

final class NotesReadTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_read",
            description: "Read one note's full plain text by `id` (from notes_list / notes_search), including its attachment names.",
            parameters: AppleSchema.object(["id": AppleSchema.string("Note id.")], required: ["id"]),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a note id")
        return AppleToolPayload(["note": try await service.read(id: id)])
    }
}

final class NotesCreateTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_create",
            description: "Create a note with a title and plain-text body (newlines preserved). The folder is created if it does not exist; omit it for the default folder. Returns the new note with its id.",
            parameters: AppleSchema.object(
                [
                    "title": AppleSchema.string("Note title (first line)."),
                    "body": AppleSchema.string("Plain-text body. Use newlines for paragraphs."),
                    "folder": AppleSchema.string("Folder name (created when missing) or folder id from notes_folders."),
                ],
                required: ["title"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let title = try AppleArgs.requiredString(args, "title", expected: "a note title")
        let body = try AppleArgs.string(args, "body") ?? ""
        let folder = try AppleArgs.string(args, "folder")
        let note = try await service.create(title: title, body: body, folder: folder)
        return AppleToolPayload(["note": note, "created": true])
    }
}

final class NotesAppendTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_append",
            description: "Append plain text to the end of an existing text-only note by `id`. Notes with attachments (images, files, drawings, tables) are refused because rewriting them would drop the attachments — use notes_create or notes_open instead. Returns the updated note.",
            parameters: AppleSchema.object(
                [
                    "id": AppleSchema.string("Note id."),
                    "text": AppleSchema.string("Text to append (newlines preserved)."),
                ],
                required: ["id", "text"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a note id")
        let text = try AppleArgs.requiredString(args, "text", expected: "text to append")
        let note = try await service.append(id: id, text: text)
        return AppleToolPayload(["note": note, "appended": true])
    }
}

final class NotesOpenTool: AppleToolBase, @unchecked Sendable {
    private let service: NotesServicing
    init(service: NotesServicing) {
        self.service = service
        super.init(
            app: .notes, name: "notes_open",
            description: "Open a note in the Notes app by `id`. Brings Notes to the front, so ask before using it mid-task.",
            parameters: AppleSchema.object(["id": AppleSchema.string("Note id.")], required: ["id"]),
            // Not a data write, but it steals focus — gate it behind the
            // same ask-first policy as writes.
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a note id")
        try await service.open(id: id)
        return AppleToolPayload(["opened": true, "id": id])
    }
}
