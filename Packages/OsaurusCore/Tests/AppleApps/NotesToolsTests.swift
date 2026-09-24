//
//  NotesToolsTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Notes contracts that do not need the Notes app: attachment-safe append
//  refusal surfaces as a typed envelope, `notes_read` exposes attachment
//  names, folder selection accepts ids, and the system folder is skipped.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class FakeNotesService: NotesServicing, @unchecked Sendable {
    var notes: [String: NoteContent] = [:]
    private(set) var appended: [(String, String)] = []

    func folders() async throws -> [NoteFolderInfo] { [] }
    func listNotes(folder: String?) async throws -> [NoteSummary] { [] }
    func previews(ids: [String], length: Int) async throws -> [String: String] { [:] }
    func read(id: String) async throws -> NoteContent {
        guard let n = notes[id] else { throw AppleToolError.notFound("No note `\(id)`.") }
        return n
    }
    func create(title: String, body: String, folder: String?) async throws -> NoteContent {
        throw AppleToolError.execution("unused")
    }
    func append(id: String, text: String) async throws -> NoteContent {
        let current = try await read(id: id)
        if current.hasAttachments {
            throw AppleToolError.unavailable("Note `\(current.title)` has attachments; not changed.", retryable: false)
        }
        appended.append((id, text))
        return current
    }
    func open(id: String) async throws {}
}

@Suite("Apple tools: Notes over a fake service")
struct NotesToolsTests {
    private func env(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func note(_ id: String, attachments: [String]) -> NoteContent {
        NoteContent(
            id: id, title: "Trip", folder: "Notes", created: nil, modified: nil, plaintext: "hello",
            characterCount: 5, hasAttachments: !attachments.isEmpty, attachments: attachments
        )
    }

    @Test("notes_append refuses notes with attachments as a non-retryable typed error and leaves them untouched")
    func appendRefusesAttachments() async throws {
        let service = FakeNotesService()
        service.notes["n1"] = note("n1", attachments: ["IMG_0001.jpeg", "budget.numbers"])
        let tool = NotesAppendTool(service: service)
        let out = try env(await tool.execute(argumentsJSON: #"{"id":"n1","text":"hello"}"#))
        #expect(out["ok"] as? Bool == false)
        #expect(out["kind"] as? String == "unavailable")
        #expect(out["retryable"] as? Bool == false)
        #expect((out["message"] as? String)?.contains("attachments") == true)
        #expect(service.appended.isEmpty)
    }

    @Test("notes_append on a text-only note proceeds")
    func appendTextOnly() async throws {
        let service = FakeNotesService()
        service.notes["n2"] = note("n2", attachments: [])
        let tool = NotesAppendTool(service: service)
        let out = try env(await tool.execute(argumentsJSON: #"{"id":"n2","text":"hello"}"#))
        #expect(out["ok"] as? Bool == true)
        #expect(service.appended.count == 1)
    }

    @Test("notes_read surfaces attachment names")
    func readSurfacesAttachments() async throws {
        let service = FakeNotesService()
        service.notes["n1"] = note("n1", attachments: ["IMG_0001.jpeg"])
        let out = try env(await NotesReadTool(service: service).execute(argumentsJSON: #"{"id":"n1"}"#))
        let result = try #require(out["result"] as? [String: Any])
        let note = try #require(result["note"] as? [String: Any])
        #expect(note["hasAttachments"] as? Bool == true)
        #expect(note["attachments"] as? [String] == ["IMG_0001.jpeg"])
    }

    @Test("notes_open asks before running (it steals focus)")
    func openIsGated() {
        let tool = NotesOpenTool(service: FakeNotesService())
        #expect(tool.defaultPermissionPolicy == .ask)
    }

    @Test("folder selection accepts a folder id, a folder name, or every non-system folder")
    func folderSelection() {
        #expect(AppleScriptNotesService.folderSelection("x-coredata://ABC/ICFolder/p12") == "set targetFolders to {folder id \"x-coredata://ABC/ICFolder/p12\"}")
        let byName = AppleScriptNotesService.folderSelection("Work")
        #expect(byName.contains("my allFolders()"))
        #expect(byName.contains("(item 2 of entry) is \"Work\""))
        let all = AppleScriptNotesService.folderSelection(nil)
        #expect(all.contains("my allFolders()"))
        #expect(AppleScriptNotesService.skippedFolderNames.contains("Recently Deleted"))
        #expect(AppleScriptNotesService.isObjectId("x-coredata://ABC/ICNote/p1"))
        #expect(!AppleScriptNotesService.isObjectId("Notes"))
    }
}
