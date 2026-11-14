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
        // `ToolEnvelope.failure` writes `message` at the TOP level of the
        // envelope, not nested under an `error` object.
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return dict["message"] as? String ?? ""
    }

    // MARK: - empty new_string through preflight (#3031)

    @Test func emptyNewStringSurvivesPreflightAndDeletesMatch() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("keep-before\nREMOVE_ME\nkeep-after\n", name: "repro.txt", root: root)
        let tool = FileEditTool(rootPath: root)

        let outcome = ToolRegistry.preflight(
            argumentsJSON: #"{"path":"repro.txt","old_string":"REMOVE_ME\n","new_string":""}"#,
            schema: tool.parameters,
            toolName: tool.name,
            preservingEmpty: tool.preservedEmptyStringArguments
        )
        guard case .ready(let argumentsJSON) = outcome else {
            Issue.record("preflight rejected an explicit empty new_string")
            return
        }
        let output = try await tool.execute(argumentsJSON: argumentsJSON)
        #expect(ToolEnvelope.successPayload(output) != nil, "\(output)")
        #expect(fileContent(url) == "keep-before\nkeep-after\n")
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

    /// Constrained decoders emit the unused optional collection as an
    /// empty filler next to the real edit form (`"operations": []` beside
    /// `edits`, 5/5 on xAI grok-4.3). The filler carries no intent and must
    /// not turn a text-file batch into an "operations on a text file" error.
    @Test func batch_emptyOperationsFiller_isIgnored() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("timeout = 30\nretries = 3\n", name: "settings.ini", root: root)

        let batch = try await FileEditTool(rootPath: root).execute(
            argumentsJSON:
                #"{"path":"settings.ini","edits":[{"old_string":"timeout = 30","new_string":"timeout = 60"}],"operations":[]}"#
        )
        #expect(ToolEnvelope.successPayload(batch) != nil, "\(batch)")
        #expect(fileContent(url) == "timeout = 60\nretries = 3\n")

        let single = try await FileEditTool(rootPath: root).execute(
            argumentsJSON:
                #"{"path":"settings.ini","old_string":"retries = 3","new_string":"retries = 5","edits":[],"operations":null}"#
        )
        #expect(ToolEnvelope.successPayload(single) != nil, "\(single)")
        #expect(fileContent(url) == "timeout = 60\nretries = 5\n")

        // Once the decoder has opened the array it may pad it with an empty
        // object (grok-4.3, `edit-batch-edits-single-call`): still content-free.
        for filler in [#"[{}]"#, #"{}"#, #"[{"op":""}]"#, #"[{"op":null,"cells":{}}]"#] {
            let padded = try await FileEditTool(rootPath: root).execute(
                argumentsJSON:
                    #"{"path":"settings.ini","edits":[{"old_string":"retries = 5","new_string":"retries = 7"}],"operations":"# + filler + "}"
            )
            #expect(ToolEnvelope.successPayload(padded) != nil, "\(filler) → \(padded)")
            #expect(fileContent(url) == "timeout = 60\nretries = 7\n")
            _ = try await FileEditTool(rootPath: root).execute(
                argumentsJSON: #"{"path":"settings.ini","old_string":"retries = 7","new_string":"retries = 5"}"#)
        }
        #expect(FileEditTool.isContentFree([["op": NSNull(), "cells": [String: Any]()]]))
        #expect(!FileEditTool.isContentFree([["op": "set_cells"]]))
        #expect(!FileEditTool.isContentFree([["index": 0]]))

        // A filler with no other form still gets the pointed error.
        let onlyFiller = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"settings.ini","operations":[]}"#
        )
        #expect(ToolEnvelope.successPayload(onlyFiller) == nil)
        #expect(failureMessage(onlyFiller).contains("operations"), "\(failureMessage(onlyFiller))")
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
        #expect(payload["match_strategy"] as? String == "exact")
        #expect(payload["matched_lines"] as? [String] == ["1"])
        #expect(fileContent(url) == "hello osaurus")
    }

    // MARK: - tolerance cascade through the tool

    private func warnings(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return dict["warnings"] as? [String] ?? []
    }

    @Test func relaxedMatch_appliesReportsStrategyAndQuotesFileText() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("def f():\n\tif x:\n\t\treturn 1\n\treturn 0\n", name: "a.py", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"a.py","old_string":"    if x:\n        return 1","new_string":"    if x:\n        return 2"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["match_strategy"] as? String == "whitespace_normalized")
        #expect(payload["matched_lines"] as? [String] == ["2-3"])
        #expect(fileContent(url) == "def f():\n\tif x:\n\t\treturn 2\n\treturn 0\n")
        let notes = warnings(output)
        #expect(notes.contains { $0.contains("did not match the file byte-for-byte") && $0.contains("\tif x:") })
    }

    @Test func batch_mixedStrategies_reportPerEdit() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("name: \u{201C}Ada\u{201D}\nport: 8080\n", name: "cfg.yaml", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: """
                {"path":"cfg.yaml","edits":[
                  {"old_string":"port: 8080","new_string":"port: 9090"},
                  {"old_string":"name: \\"Ada\\"","new_string":"name: \\"Grace\\""}
                ]}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["edit_strategies"] as? [String] == ["exact", "unicode_normalized"])
        #expect(payload["match_strategy"] as? String == "unicode_normalized")
        #expect(fileContent(url) == "name: \"Grace\"\nport: 9090\n")
    }

    @Test func identicalOldAndNew_isRejectedAsNoOp() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("x = 1\n", name: "a.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"a.txt","old_string":"x = 1","new_string":"x = 1"}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        #expect(failureMessage(output).contains("identical"))
    }

    @Test func relaxedAmbiguity_namesStrategyAndSuggestsReplaceAll() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("\tfoo(1)\n\tbar\n\tfoo(1)\n", name: "a.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"a.txt","old_string":"  foo(1)","new_string":"  foo(2)"}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        let message = failureMessage(output)
        #expect(message.contains("Found 2 matches"))
        #expect(message.contains("replace_all"))
        #expect(message.contains("whitespace"))
        #expect(fileContent(url) == "\tfoo(1)\n\tbar\n\tfoo(1)\n")
    }

    @Test func crlfFile_keepsCRLFAfterEdit() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("one\r\ntwo\r\nthree\r\n", name: "win.txt", root: root)

        let output = try await FileEditTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"win.txt","old_string":"two\nthree","new_string":"two\n2.5\nthree"}"#
        )
        _ = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(fileContent(url) == "one\r\ntwo\r\n2.5\r\nthree\r\n")
    }
}
