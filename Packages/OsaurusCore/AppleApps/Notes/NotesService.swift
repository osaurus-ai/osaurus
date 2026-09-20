//
//  NotesService.swift
//  osaurus
//
//  Apple Notes access over AppleScript (`AppleScriptBridge`). Every note is
//  addressed by its stable Core Data id (`x-coredata://…/ICNote/pNNN`) so the
//  model can read / append / open exactly the note it listed — the plugin
//  only returned names and a 200-character preview. Notes is launched in the
//  background when needed; nothing here activates it except `open`.
//

import AppKit
import Foundation

struct NoteFolderInfo: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let account: String?
    let noteCount: Int
}

struct NoteSummary: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let folder: String
    let created: String?
    let modified: String?
    /// First ~200 characters of the plain text (list/search only).
    let preview: String?
}

struct NoteContent: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let folder: String
    let created: String?
    let modified: String?
    let plaintext: String
    let characterCount: Int
    let hasAttachments: Bool
}

protocol NotesServicing: Sendable {
    func folders() async throws -> [NoteFolderInfo]
    /// All notes (id/title/folder/dates, no body); caller sorts + pages.
    func listNotes(folder: String?) async throws -> [NoteSummary]
    /// Plain-text previews for specific ids (batched in one script).
    func previews(ids: [String], length: Int) async throws -> [String: String]
    func read(id: String) async throws -> NoteContent
    func create(title: String, body: String, folder: String?) async throws -> NoteContent
    func append(id: String, text: String) async throws -> NoteContent
    func open(id: String) async throws
}

final class AppleScriptNotesService: NotesServicing, @unchecked Sendable {
    static let bundleIdentifier = "com.apple.Notes"
    static let appName = "Notes"

    private func run(_ body: String, timeout: TimeInterval = AppleScriptBridge.defaultTimeout) async throws -> String {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: Self.bundleIdentifier, appName: Self.appName) else {
            throw AppleToolError.unavailable("Notes could not be launched on this Mac.", retryable: true)
        }
        let source = """
            \(AppleScriptBridge.separatorPrelude)
            \(AppleScriptBridge.isoDateHandler)
            \(body)
            """
        return try await AppleScriptBridge.run(source, permission: .notes, appName: Self.appName, timeout: timeout)
    }

    func folders() async throws -> [NoteFolderInfo] {
        let out = try await run(
            """
            tell application "Notes"
                set rows to {}
                repeat with f in folders
                    set acct to ""
                    try
                        set acct to name of container of f
                    end try
                    set end of rows to (id of f) & FS & (name of f) & FS & acct & FS & ((count of notes of f) as string)
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """
        )
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 4 else { return nil }
            return NoteFolderInfo(
                id: r[0], name: r[1], account: r[2].isEmpty ? nil : r[2], noteCount: Int(r[3]) ?? 0
            )
        }
    }

    func listNotes(folder: String?) async throws -> [NoteSummary] {
        let folderClause: String
        if let folder, !folder.isEmpty {
            folderClause = "set targetFolders to (folders whose name is \(AppleScriptBridge.literal(folder)))"
        } else {
            folderClause = "set targetFolders to folders"
        }
        let out = try await run(
            """
            tell application "Notes"
                \(folderClause)
                set rows to {}
                repeat with f in targetFolders
                    set fname to name of f
                    set idsL to id of notes of f
                    set namesL to name of notes of f
                    set modsL to modification date of notes of f
                    set creL to creation date of notes of f
                    repeat with i from 1 to count of idsL
                        set end of rows to (item i of idsL) & FS & (item i of namesL) & FS & fname & FS & my isoDate(item i of creL) & FS & my isoDate(item i of modsL)
                    end repeat
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """,
            timeout: 120
        )
        if let folder, !folder.isEmpty, out.isEmpty {
            // Distinguish "empty folder" from "no such folder".
            let names = try await folders().map(\.name)
            if !names.contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) {
                throw AppleToolError.notFound(
                    "No Notes folder named `\(folder)`. Folders: \(names.joined(separator: ", "))."
                )
            }
        }
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 5 else { return nil }
            return NoteSummary(
                id: r[0], title: r[1], folder: r[2],
                created: AppleScriptBridge.isoOutput(r[3]), modified: AppleScriptBridge.isoOutput(r[4]),
                preview: nil
            )
        }
    }

    func previews(ids: [String], length: Int) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let out = try await run(
            """
            tell application "Notes"
                set rows to {}
                repeat with nid in \(AppleScriptBridge.listLiteral(ids))
                    try
                        set t to plaintext of note id nid
                        if (length of t) > \(length) then set t to text 1 thru \(length) of t
                        set end of rows to nid & FS & t
                    end try
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """
        )
        var map: [String: String] = [:]
        for r in AppleScriptBridge.parseRecords(out) where r.count >= 2 {
            map[r[0]] = r[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return map
    }

    func read(id: String) async throws -> NoteContent {
        let out = try await run(
            """
            tell application "Notes"
                set n to note id \(AppleScriptBridge.literal(id))
                set fname to ""
                try
                    set fname to name of container of n
                end try
                set attCount to 0
                try
                    set attCount to count of attachments of n
                end try
                return (id of n) & FS & (name of n) & FS & fname & FS & my isoDate(creation date of n) & FS & my isoDate(modification date of n) & FS & (attCount as string) & FS & (plaintext of n)
            end tell
            """
        )
        guard let r = AppleScriptBridge.parseRecords(out).first, r.count >= 7 else {
            throw AppleToolError.notFound("No note with id `\(id)`. Call `notes_list` or `notes_search` and use one of its `id` values.")
        }
        let text = r[6...].joined(separator: String(AppleScriptBridge.fieldSeparator))
        return NoteContent(
            id: r[0], title: r[1], folder: r[2],
            created: AppleScriptBridge.isoOutput(r[3]), modified: AppleScriptBridge.isoOutput(r[4]),
            plaintext: text, characterCount: text.count, hasAttachments: (Int(r[5]) ?? 0) > 0
        )
    }

    func create(title: String, body: String, folder: String?) async throws -> NoteContent {
        let html = Self.html(title: title, body: body)
        let folderSetup: String
        if let folder, !folder.isEmpty {
            let lit = AppleScriptBridge.literal(folder)
            folderSetup = """
                set matches to (folders whose name is \(lit))
                if (count of matches) is 0 then
                    set targetFolder to make new folder with properties {name:\(lit)}
                else
                    set targetFolder to item 1 of matches
                end if
                """
        } else {
            folderSetup = "set targetFolder to default folder of default account"
        }
        let out = try await run(
            """
            tell application "Notes"
                \(folderSetup)
                set n to make new note at targetFolder with properties {name:\(AppleScriptBridge.literal(title)), body:\(AppleScriptBridge.literal(html))}
                return id of n
            end tell
            """
        )
        let newId = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newId.isEmpty else { throw AppleToolError.execution("Notes did not return an id for the new note.") }
        return try await read(id: newId)
    }

    func append(id: String, text: String) async throws -> NoteContent {
        let fragment = Self.htmlParagraphs(text)
        _ = try await run(
            """
            tell application "Notes"
                set n to note id \(AppleScriptBridge.literal(id))
                set body of n to (body of n) & \(AppleScriptBridge.literal(fragment))
                return id of n
            end tell
            """
        )
        return try await read(id: id)
    }

    func open(id: String) async throws {
        _ = try await run(
            """
            tell application "Notes"
                show note id \(AppleScriptBridge.literal(id))
                activate
            end tell
            """
        )
    }

    // MARK: HTML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Notes renders `<div>` per line; blank lines become `<div><br></div>`.
    static func htmlParagraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let t = escape(String(line))
                return t.isEmpty ? "<div><br></div>" : "<div>\(t)</div>"
            }
            .joined()
    }

    static func html(title: String, body: String) -> String {
        "<div><h1>\(escape(title))</h1></div>" + htmlParagraphs(body)
    }
}
