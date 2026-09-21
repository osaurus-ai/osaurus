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
    /// Attachment names (images, files, links, drawings…) in note order.
    let attachments: [String]
}

protocol NotesServicing: Sendable {
    func folders() async throws -> [NoteFolderInfo]
    /// All notes (id/title/folder/dates, no body); caller sorts + pages.
    /// `folder` is a folder name or a folder id from `folders()`.
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

    private func run(
        _ body: String, timeout: TimeInterval = AppleScriptBridge.defaultTimeout, isWrite: Bool = false
    ) async throws -> String {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: Self.bundleIdentifier, appName: Self.appName) else {
            throw AppleToolError.unavailable("Notes could not be launched on this Mac.", retryable: true)
        }
        let eventBudget = max(Int(timeout) - 5, 10)
        let source = """
            \(AppleScriptBridge.separatorPrelude)
            \(AppleScriptBridge.isoDateHandler)
            \(Self.folderHandlers)
            with timeout of \(eventBudget) seconds
            \(body)
            end timeout
            """
        return try await AppleScriptBridge.runRetryingIfAppGone(
            bundleIdentifier: Self.bundleIdentifier, appName: Self.appName, isWrite: isWrite
        ) {
            try await AppleScriptBridge.run(source, permission: .notes, appName: Self.appName, timeout: timeout, isWrite: isWrite)
        }
    }

    /// Folder names Notes manages itself; never listed, never written to.
    static let skippedFolderNames: Set<String> = ["Recently Deleted"]

    /// Depth-first folder walk (accounts → folders → subfolders) so nested
    /// folders are reachable; the application-level `folders` element is
    /// not guaranteed to include them.
    private static let folderHandlers = """
        on collectFolders(parentObj, acctName, depth, acc)
            using terms from application "Notes"
                if depth > 10 then return acc
                repeat with f in folders of parentObj
                    set fname to name of f
                    if fname is not "Recently Deleted" then
                        set end of acc to {f, fname, acctName}
                        set acc to my collectFolders(f, acctName, depth + 1, acc)
                    end if
                end repeat
                return acc
            end using terms from
        end collectFolders
        on allFolders()
            using terms from application "Notes"
                set acc to {}
                repeat with a in accounts
                    set acc to my collectFolders(a, name of a, 0, acc)
                end repeat
                return acc
            end using terms from
        end allFolders
        """

    /// Whether `value` is a Core Data object id (folder / note id).
    static func isObjectId(_ value: String) -> Bool {
        value.hasPrefix("x-coredata://")
    }

    func folders() async throws -> [NoteFolderInfo] {
        let out = try await run(
            """
            tell application "Notes"
                set rows to {}
                repeat with entry in my allFolders()
                    set f to item 1 of entry
                    set end of rows to (id of f) & FS & (item 2 of entry) & FS & (item 3 of entry) & FS & ((count of notes of f) as string)
                end repeat
                set AppleScript's text item delimiters to RS
                set outText to rows as text
                set AppleScript's text item delimiters to ""
                return outText
            end tell
            """,
            timeout: 90
        )
        var seen = Set<String>()
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 4, !seen.contains(r[0]) else { return nil }
            seen.insert(r[0])
            return NoteFolderInfo(
                id: r[0], name: r[1], account: r[2].isEmpty ? nil : r[2], noteCount: Int(r[3]) ?? 0
            )
        }
    }

    /// Bind `targetFolders` to the folders selected by `folder` (name, id, or
    /// nil for all non-system folders).
    static func folderSelection(_ folder: String?) -> String {
        guard let folder, !folder.isEmpty else {
            return """
                set targetFolders to {}
                repeat with entry in my allFolders()
                    set end of targetFolders to item 1 of entry
                end repeat
                """
        }
        if isObjectId(folder) {
            return "set targetFolders to {folder id \(AppleScriptBridge.literal(folder))}"
        }
        let lit = AppleScriptBridge.literal(folder)
        return """
            set targetFolders to {}
            repeat with entry in my allFolders()
                if (item 2 of entry) is \(lit) then set end of targetFolders to item 1 of entry
            end repeat
            """
    }

    func listNotes(folder: String?) async throws -> [NoteSummary] {
        let out = try await run(
            """
            tell application "Notes"
                \(Self.folderSelection(folder))
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
                set outText to rows as text
                set AppleScript's text item delimiters to ""
                return outText
            end tell
            """,
            timeout: 120
        )
        if let folder, !folder.isEmpty, out.isEmpty {
            // Distinguish "empty folder" from "no such folder".
            let known = try await folders()
            let matches = known.contains { $0.id == folder || $0.name.caseInsensitiveCompare(folder) == .orderedSame }
            if !matches {
                throw AppleToolError.notFound(
                    "No Notes folder named `\(folder)`. Folders: \(known.map(\.name).joined(separator: ", "))."
                )
            }
        }
        var seen = Set<String>()
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 5, !seen.contains(r[0]) else { return nil }
            seen.insert(r[0])
            return NoteSummary(
                id: r[0], title: r[1], folder: r[2],
                created: AppleScriptBridge.isoOutput(r[3]), modified: AppleScriptBridge.isoOutput(r[4]),
                preview: nil
            )
        }
    }

    /// Notes per preview script; keeps each Apple Event batch short so a
    /// cancellation or timeout lands between chunks instead of after a
    /// library-wide read.
    static let previewChunkSize = 40

    func previews(ids: [String], length: Int) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var map: [String: String] = [:]
        var index = 0
        while index < ids.count {
            try Task.checkCancellation()
            let chunk = Array(ids[index ..< min(index + Self.previewChunkSize, ids.count)])
            index += Self.previewChunkSize
            let out = try await run(
                """
                tell application "Notes"
                    set rows to {}
                    repeat with nid in \(AppleScriptBridge.listLiteral(chunk))
                        try
                            set t to plaintext of note id nid
                            if (length of t) > \(length) then set t to text 1 thru \(length) of t
                            set end of rows to nid & FS & t
                        end try
                    end repeat
                    set AppleScript's text item delimiters to RS
                    set outText to rows as text
                    set AppleScript's text item delimiters to ""
                    return outText
                end tell
                """,
                timeout: 60
            )
            for r in AppleScriptBridge.parseRecords(out) where r.count >= 2 {
                map[r[0]] = r[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
                set attNames to {}
                try
                    repeat with att in attachments of n
                        set attName to ""
                        try
                            set attName to name of att
                        end try
                        if attName is missing value or attName is "" then set attName to "(untitled attachment)"
                        set end of attNames to attName
                    end repeat
                end try
                set AppleScript's text item delimiters to (character id 29)
                set attText to attNames as text
                set AppleScript's text item delimiters to ""
                return (id of n) & FS & (name of n) & FS & fname & FS & my isoDate(creation date of n) & FS & my isoDate(modification date of n) & FS & attText & FS & (plaintext of n)
            end tell
            """
        )
        guard let r = AppleScriptBridge.parseRecords(out).first, r.count >= 7 else {
            throw AppleToolError.notFound("No note with id `\(id)`. Call `notes_list` or `notes_search` and use one of its `id` values.")
        }
        let text = r[6...].joined(separator: String(AppleScriptBridge.fieldSeparator))
        let attachments = r[5].split(separator: "\u{1D}", omittingEmptySubsequences: true).map(String.init)
        return NoteContent(
            id: r[0], title: r[1], folder: r[2],
            created: AppleScriptBridge.isoOutput(r[3]), modified: AppleScriptBridge.isoOutput(r[4]),
            plaintext: text, characterCount: text.count, hasAttachments: !attachments.isEmpty, attachments: attachments
        )
    }

    func create(title: String, body: String, folder: String?) async throws -> NoteContent {
        let html = Self.html(title: title, body: body)
        if let folder, Self.skippedFolderNames.contains(folder) {
            throw AppleToolError.invalidArgs("Notes cannot be created in `\(folder)`.", field: "folder")
        }
        let folderSetup: String
        if let folder, !folder.isEmpty {
            let lit = AppleScriptBridge.literal(folder)
            if Self.isObjectId(folder) {
                folderSetup = "set targetFolder to folder id \(lit)"
            } else {
                folderSetup = """
                    set targetFolder to missing value
                    repeat with entry in my allFolders()
                        if (item 2 of entry) is \(lit) then
                            set targetFolder to item 1 of entry
                            exit repeat
                        end if
                    end repeat
                    if targetFolder is missing value then set targetFolder to make new folder with properties {name:\(lit)}
                    """
            }
        } else {
            folderSetup = "set targetFolder to default folder of default account"
        }
        // Notes hands out a provisional id right after `make new`; once the
        // note is saved the same object answers with its permanent id. Ask
        // again after a short settle so the id we return keeps working.
        let out = try await run(
            """
            tell application "Notes"
                \(folderSetup)
                set n to make new note at targetFolder with properties {name:\(AppleScriptBridge.literal(title)), body:\(AppleScriptBridge.literal(html))}
                set provisionalId to id of n
                set stableId to provisionalId
                repeat 6 times
                    delay 0.25
                    try
                        set stableId to id of (note id provisionalId)
                    end try
                    if stableId is not provisionalId then exit repeat
                end repeat
                return stableId
            end tell
            """,
            isWrite: true
        )
        let newId = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newId.isEmpty else { throw AppleToolError.execution("Notes did not return an id for the new note.") }
        return try await read(id: newId)
    }

    func append(id: String, text: String) async throws -> NoteContent {
        // Rewriting `body` re-renders the note from HTML and drops every
        // attachment (images, files, drawings, tables). Refuse instead of
        // silently destroying content; the caller can create a new note or
        // open this one for the user.
        let current = try await read(id: id)
        if current.hasAttachments {
            let names = current.attachments.prefix(5).joined(separator: ", ")
            throw AppleToolError.unavailable(
                "Note `\(current.title)` has \(current.attachments.count) attachment(s) (\(names)). Appending would rewrite the note and remove them, so it was not changed. Use notes_create for a new note, or notes_open so the user can edit this one.",
                retryable: false
            )
        }
        let fragment = Self.htmlParagraphs(text)
        _ = try await run(
            """
            tell application "Notes"
                set n to note id \(AppleScriptBridge.literal(id))
                if (count of attachments of n) > 0 then error "Note has attachments; refusing to rewrite it." number -10000
                set body of n to (body of n) & \(AppleScriptBridge.literal(fragment))
                return id of n
            end tell
            """,
            isWrite: true
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
