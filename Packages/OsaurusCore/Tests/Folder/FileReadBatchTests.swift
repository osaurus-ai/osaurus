//
//  FileReadBatchTests.swift
//  osaurusTests
//
//  `file_read` with `paths`: several files in one call, per-file failures
//  that do not sink the batch, and one shared output budget.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadBatchTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-read-batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ name: String, root: URL) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func files(_ output: String) throws -> [[String: Any]] {
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "files")
        return try #require(payload["files"] as? [[String: Any]])
    }

    @Test func readsEveryFileInRequestOrder() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("april total 120\n", "april.txt", root: root)
        try write("may total 80\n", "may.txt", root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"paths":["may.txt","april.txt"]}"#
        )
        let entries = try files(output)
        #expect(entries.map { $0["path"] as? String } == ["may.txt", "april.txt"])
        #expect(entries.allSatisfy { $0["ok"] as? Bool == true })
        #expect((entries[0]["text"] as? String)?.contains("may total 80") == true)
        #expect((entries[1]["text"] as? String)?.contains("april total 120") == true)
    }

    @Test func missingFileIsAnEntryNotABatchFailure() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("present\n", "a.txt", root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"paths":["a.txt","missing.txt"]}"#
        )
        #expect(ToolEnvelope.isSuccess(output))
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["failed_count"] as? Int == 1)
        let entries = try files(output)
        #expect(entries[1]["ok"] as? Bool == false)
        #expect(entries[1]["path"] as? String == "missing.txt")
        #expect(entries[1]["message"] as? String != nil)
    }

    @Test func allFilesMissingIsAnError() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"paths":["x.txt","y.txt"]}"#
        )
        #expect(ToolEnvelope.isError(output))
        #expect(output.contains("x.txt"))
        #expect(output.contains("y.txt"))
    }

    /// Models that fill every argument send `path` next to `paths`; both
    /// are read rather than the call being refused.
    @Test func pathAlongsidePathsJoinsTheBatch() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a\n", "a.txt", root: root)
        try write("b\n", "b.txt", root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"a.txt","paths":["b.txt","a.txt"]}"#
        )
        #expect(try files(output).map { $0["path"] as? String } == ["a.txt", "b.txt"])
    }

    @Test func emptyPathsIsASingleFileRead() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\n", "a.txt", root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"a.txt","paths":[]}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["kind"] as? String == "file")
        #expect((payload["text"] as? String)?.contains("alpha") == true)
    }

    @Test func oneEntryOrStringifiedPathsNormalize() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a\n", "a.txt", root: root)
        try write("b\n", "b.txt", root: root)
        let tool = FileReadTool(rootPath: root)

        let one = try await tool.execute(argumentsJSON: #"{"paths":["a.txt"]}"#)
        #expect((ToolEnvelope.successPayload(one) as? [String: Any])?["kind"] as? String == "file")

        let encoded = try await tool.execute(argumentsJSON: #"{"paths":"[\"a.txt\", \"b.txt\"]"}"#)
        #expect(try files(encoded).count == 2)
    }

    /// `path` stays required in the schema (an optional `path` made models
    /// pad calls with range arguments); a call that lists every file in
    /// `paths` still clears preflight and reads them all.
    @Test func pathsOnlyCallClearsPreflight() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a\n", "a.txt", root: root)
        try write("b\n", "b.txt", root: root)
        let tool = FileReadTool(rootPath: root)

        guard case .object(let schema)? = tool.parameters else {
            Issue.record("file_read has no object schema")
            return
        }
        #expect(schema["required"] == .array([.string("path")]))

        let normalized = tool.normalizeArgumentsBeforeValidation(#"{"paths":["a.txt","b.txt"]}"#)
        guard
            case .ready(let ready) = ToolRegistry.preflight(
                argumentsJSON: normalized, schema: tool.parameters, toolName: tool.name)
        else {
            Issue.record("paths-only call was rejected: \(normalized)")
            return
        }
        let output = try await tool.execute(argumentsJSON: ready)
        #expect(try files(output).map { $0["path"] as? String } == ["a.txt", "b.txt"])

        let single = #"{"path":"a.txt"}"#
        #expect(tool.normalizeArgumentsBeforeValidation(single) == single)
    }

    @Test func tooManyPathsIsRejected() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = (0...FileReadTool.maxBatchPaths).map { "\"f\($0).txt\"" }.joined(separator: ",")

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: "{\"paths\":[\(names)]}"
        )
        #expect(ToolEnvelope.isError(output))
        #expect(output.contains("at most \(FileReadTool.maxBatchPaths)"))
    }

    @Test func duplicatePathsAreReadOnce() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a\n", "a.txt", root: root)

        try write("b\n", "b.txt", root: root)
        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"paths":["a.txt","b.txt","a.txt"]}"#
        )
        #expect(try files(output).count == 2)
    }

    @Test func filesShareOneOutputBudget() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "0123456789 abcdefghij\n", count: FileReadTool.batchOutputChars / 10)
        for name in ["a.txt", "b.txt", "c.txt"] { try write(big, name, root: root) }

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"paths":["a.txt","b.txt","c.txt"]}"#
        )
        let total = try files(output).compactMap { ($0["text"] as? String)?.count }.reduce(0, +)
        #expect(total <= FileReadTool.batchOutputChars + 3 * 500)
        #expect(try files(output).allSatisfy { ($0["text"] as? String)?.isEmpty == false })
    }

    @Test func batchResultsAreNeverHeldOrReplayed() {
        let state = AgentTaskState()
        let args = #"{"paths":["new.txt","other.txt"]}"#
        let failure = ToolEnvelope.failure(kind: .notFound, message: "None of the 1 files could be read.", tool: "file_read")
        state.record(name: "file_read", argsJSON: args, result: failure)
        #expect(state.heldResult(name: "file_read", argsJSON: args) == nil)

        let withPath = #"{"path":"a.txt","paths":["b.txt"]}"#
        let success = ToolEnvelope.success(
            tool: "file_read", result: ["kind": "files", "files": []] as [String: Any])
        state.record(name: "file_read", argsJSON: withPath, result: success)
        #expect(state.heldResult(name: "file_read", argsJSON: withPath) == nil)
    }
}
