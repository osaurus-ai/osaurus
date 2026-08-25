//
//  FileEditBatchTests.swift
//  osaurusTests
//
//  Coverage for the `file_edit` bulk forms added for redaction-style
//  tasks: `replace_all` (every occurrence of one string) and `edits`
//  (an atomic batch of distinct replacements). The batch is atomic by
//  construction — a failing edit must leave the file byte-identical.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileEditBatchTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-edit-batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ content: String, name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileContent(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func failureMessage(_ output: String) -> String {
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = dict["error"] as? [String: Any]
        else { return "" }
        return error["message"] as? String ?? ""
    }

    // MARK: - replace_all

    @Test func replaceAll_replacesEveryOccurrence() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("call Bob. Bob emailed Bob.", name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON:
                #"{"path":"note.txt","old_string":"Bob","new_string":"[REDACTED NAME]","replace_all":true}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["replacements"] as? Int == 3)
        #expect(fileContent(url) == "call [REDACTED NAME]. [REDACTED NAME] emailed [REDACTED NAME].")
    }

    @Test func multipleMatches_withoutReplaceAll_failsAndSuggestsIt() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("x x", name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","old_string":"x","new_string":"y"}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        #expect(failureMessage(output).contains("replace_all"))
        #expect(fileContent(url) == "x x")
    }

    // MARK: - edits batch

    @Test func batch_appliesDistinctEditsInOrder() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write(
            "Alice met Bob.\nEmail: a@b.co\nPhone: 555-0100\n",
            name: "note.txt",
            root: root
        )

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt","edits":[
                  {"old_string":"Alice","new_string":"[REDACTED NAME]"},
                  {"old_string":"a@b.co","new_string":"[REDACTED EMAIL]"},
                  {"old_string":"555-0100","new_string":"[REDACTED PHONE]"}
                ]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["replacements"] as? Int == 3)
        #expect(payload["edits_applied"] as? [Int] == [1, 1, 1])
        #expect(
            fileContent(url)
                == "[REDACTED NAME] met Bob.\nEmail: [REDACTED EMAIL]\nPhone: [REDACTED PHONE]\n"
        )
    }

    @Test func batch_withReplaceAll_countsPerEdit() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("a a b", name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt","replace_all":true,"edits":[
                  {"old_string":"a","new_string":"1"},
                  {"old_string":"b","new_string":"2"}
                ]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["edits_applied"] as? [Int] == [2, 1])
        #expect(fileContent(url) == "1 1 2")
    }

    @Test func batch_failingEdit_isAtomic() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "Alice met Bob."
        let url = try write(original, name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt","edits":[
                  {"old_string":"Alice","new_string":"X"},
                  {"old_string":"NOT-IN-FILE","new_string":"Y"}
                ]}
                """
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        #expect(failureMessage(output).contains("edits[1]"))
        #expect(failureMessage(output).contains("atomic"))
        #expect(fileContent(url) == original)
    }

    @Test func batch_emptyArray_rejected() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("x", name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","edits":[]}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
    }

    @Test func batch_overCap_rejected() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("x", name: "note.txt", root: root)

        let edits = (0 ... FileEditTool.maxBatchEdits)
            .map { #"{"old_string":"o\#($0)","new_string":"n"}"# }
            .joined(separator: ",")
        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","edits":[\#(edits)]}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        #expect(failureMessage(output).contains("\(FileEditTool.maxBatchEdits)"))
    }

    @Test func batch_dryRun_previewsWithoutWriting() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "Alice met Bob."
        let url = try write(original, name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"note.txt","dry_run":true,"edits":[
                  {"old_string":"Alice","new_string":"X"},
                  {"old_string":"Bob","new_string":"Y"}
                ]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["replacements"] as? Int == 2)
        #expect(fileContent(url) == original)
    }

    // MARK: - single-edit regression

    @Test func singleEdit_uniqueMatch_stillWorks() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("hello world", name: "note.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt","old_string":"world","new_string":"osaurus"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["replacements"] as? Int == 1)
        #expect(fileContent(url) == "hello osaurus")
    }
}
