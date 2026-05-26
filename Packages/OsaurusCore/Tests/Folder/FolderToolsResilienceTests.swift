//
//  FolderToolsResilienceTests.swift
//
//  Pin the resilience contract for the folder built-ins. Every tool
//  must return a structured `ToolEnvelope` failure (with `field` +
//  `expected`) for the common malformed shapes quantized models emit —
//  not a bare `FolderToolError.invalidArguments` prose message.
//
//  Cases covered (per tool, where applicable):
//    - missing required arg            → `invalid_args` with `field`
//    - required arg as wrong type      → `invalid_args` with `field`
//    - empty required string           → `invalid_args` with `field`
//    - empty optional string filler    → preflight drops the key
//    - extra unknown key               → `invalid_args` (preflight)
//    - JSON-encoded scalar / array     → coerced through preflight
//
//  Tools without required args (file_tree, git_status, git_diff) skip
//  the missing/empty/wrong-type rows.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FolderToolsResilienceTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-folder-tools-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    private func failureField(_ result: String) -> String? {
        EnvelopeAssertions.failureField(result)
    }

    private func failureKind(_ result: String) -> String? {
        EnvelopeAssertions.failureKind(result)
    }

    // MARK: - file_read

    @Test func fileRead_missingPath() async throws {
        let tool = FileReadTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "invalid_args")
        #expect(failureField(result) == "path")
    }

    @Test func fileRead_pathWrongType() async throws {
        let tool = FileReadTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: #"{"path": 42}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "path")
    }

    @Test func fileRead_emptyPath() async throws {
        let tool = FileReadTool(rootPath: tmpRoot())
        // `requireString` rejects empty without `allowEmpty: true`, so this
        // surfaces as a pointed `must not be empty` envelope rather than
        // continuing with `path: ""`.
        let result = try await tool.execute(argumentsJSON: #"{"path": ""}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "path")
    }

    /// Pins the `.docx` / `.pdf` / `.rtf` fix: rich-document extensions
    /// route through `DocumentParser` instead of the raw UTF-8 decode
    /// that used to surface `NSCocoaErrorDomain` code 264 ("isn't in
    /// the correct format"). We use RTF here because `NSAttributedString`
    /// can synthesise it inline without checking in a binary fixture.
    @Test @MainActor func fileRead_richDocumentExtractsText() async throws {
        let root = tmpRoot()
        let body = "Hello rich world — extracted via DocumentParser."
        let attributed = NSAttributedString(string: body)
        guard
            let rtfData = attributed.rtf(
                from: NSRange(location: 0, length: attributed.length)
            )
        else {
            Issue.record("Could not synthesise RTF fixture via NSAttributedString")
            return
        }
        let path = root.appendingPathComponent("note.rtf")
        try rtfData.write(to: path)

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "note.rtf"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains(body), "extracted text missing the body: \(text)")
    }

    /// Pins the binary-sniff branch: a non-rich file whose first 4KB
    /// contains a NUL byte must surface as
    /// `kind: execution_error, retryable: false` so the agent loop
    /// pivots instead of retrying. Previously the raw NSCocoa text
    /// flowed through `retryable: true`.
    ///
    /// `FileReadTool` throws `FolderToolError.binaryContent` (matching
    /// the `fileNotFound` convention); `ToolRegistry` wraps that into
    /// the canonical envelope via `ToolEnvelope.fromError`. We mirror
    /// the registry's wrap-on-catch here so the assertion runs against
    /// the exact bytes the model would see.
    @Test func fileRead_binaryReturnsNonRetryable() async throws {
        let root = tmpRoot()
        var bytes = Data(count: 4096)
        bytes[7] = 0xFF
        bytes[13] = 0x00  // NUL byte well inside the sniff window
        bytes[19] = 0xAB
        let path = root.appendingPathComponent("blob.bin")
        try bytes.write(to: path)

        let tool = FileReadTool(rootPath: root)
        let envelope: String
        do {
            envelope = try await tool.execute(
                argumentsJSON: #"{"path": "blob.bin"}"#
            )
        } catch {
            envelope = ToolEnvelope.fromError(error, tool: tool.name)
        }
        #expect(ToolEnvelope.isError(envelope))
        #expect(failureKind(envelope) == "execution_error")
        #expect(EnvelopeAssertions.failureRetryable(envelope) == false)
        let message = EnvelopeAssertions.failureMessage(envelope) ?? ""
        #expect(
            message.contains("binary"),
            "binary envelope missing the explanatory hint: \(message)"
        )
    }

    /// Regression for the `(empty file)` raw-string leak at the bottom
    /// of `FileReadTool.execute`. The branch is reachable when the
    /// first line alone exceeds `maxOutputChars` — output stays empty
    /// after the truncation break and the tool returned the bare
    /// `"(empty file)"` string instead of an envelope. Pinned via a
    /// 16k-character line so the truncation fires deterministically.
    @Test func fileRead_oversizedFirstLineWrappedInEnvelope() async throws {
        let root = tmpRoot()
        let path = root.appendingPathComponent("wide.txt")
        let oversized = String(repeating: "a", count: 16_000)
        try oversized.write(to: path, atomically: true, encoding: .utf8)

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "wide.txt"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text == "(empty file)", "got: \(text)")
    }

    @Test func fileRead_successPayloadIncludesRawContentForModelReplay() async throws {
        let root = tmpRoot()
        let path = root.appendingPathComponent("script.py")
        try "#!/usr/bin/env python3\nprint('ok')\n".write(
            to: path,
            atomically: true,
            encoding: .utf8
        )

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "script.py", "start_line": 1, "end_line": 1}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        #expect(result.contains(#"\/"#) == false)
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["path"] as? String == "script.py")
        #expect(payload["content"] as? String == "#!/usr/bin/env python3")
        #expect(payload["start_line"] as? Int == 1)
        #expect(payload["end_line"] as? Int == 1)
        #expect(payload["total_lines"] as? Int == 3)
        #expect(payload["truncated"] as? Bool == false)
        let text = try #require(payload["text"] as? String)
        #expect(text.contains("1| #!/usr/bin/env python3"))
        #expect(text.contains(#"\/"#) == false)
    }

    // MARK: - file_write

    @Test func fileWrite_missingContent() async throws {
        let tool = FileWriteTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: #"{"path": "x.txt"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "content")
    }

    @Test func fileWrite_emptyContentIsAllowed() async throws {
        // Truncate-to-zero is a legitimate use of file_write; the tool
        // explicitly opts in via `allowEmpty: true`.
        let root = tmpRoot()
        let tool = FileWriteTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "empty.txt", "content": ""}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let path = root.appendingPathComponent("empty.txt").path
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test @MainActor func fileWrite_unknownKeyIsRejected() {
        // `additionalProperties: false` kicks in during preflight
        // validation; the model gets a structured envelope pointing at
        // the offending key without ever touching the filesystem.
        let tool = FileWriteTool(rootPath: tmpRoot())
        let outcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"path": "x.txt", "content": "hi", "extra": "nope"}"#,
            schema: tool.parameters,
            toolName: tool.name
        )
        switch outcome {
        case .rejected(let envelope):
            #expect(failureKind(envelope) == "invalid_args")
            #expect(failureField(envelope) == "extra")
        case .ready(let argsJSON):
            Issue.record("preflight should have rejected the extra key, got: \(argsJSON)")
        }
    }

    // MARK: - file_edit

    @Test func fileEdit_emptyOldStringIsRejected() async throws {
        let tool = FileEditTool(rootPath: tmpRoot())
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "f.txt", "old_string": "", "new_string": "x"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "old_string")
    }

    @Test func fileEdit_emptyNewStringIsAllowed() async throws {
        // Empty new_string deletes the matched text; the tool opts into
        // it via `allowEmpty: true`. Validation should not block before
        // execution (the file-not-found path can fail later).
        let root = tmpRoot()
        let path = root.appendingPathComponent("f.txt")
        try "hello world".write(to: path, atomically: true, encoding: .utf8)
        let tool = FileEditTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "f.txt", "old_string": "world", "new_string": ""}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let after = try String(contentsOf: path, encoding: .utf8)
        #expect(after == "hello ")
    }

    // MARK: - file_search

    @Test func fileSearch_missingPattern() async throws {
        let tool = FileSearchTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "pattern")
    }

    // MARK: - shell_run

    @Test func shellRun_missingCommand() async throws {
        let tool = ShellRunTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "command")
    }

    @Test @MainActor func shellRun_stringTimeoutPassesPreflight() {
        // The screenshot bug: `"timeout": "15"`. Preflight coercion must
        // accept the string-encoded integer and forward it as a native
        // value to the tool body; without this the validator would
        // surface a confusing `invalid_args` failure for what's a real
        // execution request.
        let tool = ShellRunTool(rootPath: tmpRoot())
        let outcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"command": "echo hi", "timeout": "15"}"#,
            schema: tool.parameters,
            toolName: tool.name
        )
        switch outcome {
        case .ready(let argsJSON):
            // Sanity: the rewrite turned the string into a native int.
            #expect(argsJSON.contains("\"timeout\":15"))
        case .rejected(let envelope):
            Issue.record("preflight rejected the call: \(envelope)")
        }
    }

    // MARK: - git_commit

    @Test func gitCommit_missingMessage() async throws {
        let tool = GitCommitTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "message")
    }

    @Test @MainActor func gitCommit_filesAcceptsJSONEncodedArray() {
        // Local models occasionally emit `files: "[\"a.txt\", \"b.txt\"]"`.
        // Preflight coerces the stringified array to a native one before
        // dispatch; we assert the rewrite happened rather than executing
        // git against a non-repo tmp dir.
        let tool = GitCommitTool(rootPath: tmpRoot())
        let outcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"message": "x", "files": "[\"a.txt\"]"}"#,
            schema: tool.parameters,
            toolName: tool.name
        )
        switch outcome {
        case .ready(let argsJSON):
            #expect(argsJSON.contains("\"files\":[\"a.txt\"]"))
        case .rejected(let envelope):
            Issue.record("preflight rejected the call: \(envelope)")
        }
    }

    // MARK: - ShellRunOutputCollector (perf-shellrun-tasks)

    /// Pin Phase A's shellrun-tasks change: the collector is no longer
    /// an actor, so a chatty pipe doesn't spawn a `Task` per chunk.
    /// Concurrency stress here just confirms the lock-guarded class
    /// preserves chunk ordering and totals.
    @Test func shellRunCollector_handlesChunkFloodWithoutLoss() async {
        let collector = ShellRunOutputCollector()
        let chunkCount = 1_000

        // Fan out from many tasks to mimic readabilityHandler firing
        // off Foundation's IO queue. Lock contention is the path under
        // test — actor used to serialise via the cooperative executor;
        // the lock-guarded class must produce the same exact totals.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< chunkCount {
                let isStderr = i % 2 == 1
                let payload = Data("\(i)\n".utf8)
                group.addTask {
                    collector.append(payload, isStderr: isStderr)
                }
            }
        }

        let (stdout, stderr) = collector.snapshot()
        // Even halves go to stdout, odd halves to stderr → 500 chunks
        // each, regardless of arrival order.
        #expect(
            stdout.split(separator: "\n").count == chunkCount / 2,
            "stdout chunk count mismatch: \(stdout.split(separator: "\n").count)"
        )
        #expect(
            stderr.split(separator: "\n").count == chunkCount / 2,
            "stderr chunk count mismatch: \(stderr.split(separator: "\n").count)"
        )
    }

    @Test func shellRunCollector_lastActivityAdvancesOnAppend() async throws {
        let collector = ShellRunOutputCollector()
        let before = collector.lastActivity
        // Even a 1ms wait is enough for `Date()` to tick.
        try await Task.sleep(nanoseconds: 5_000_000)
        collector.append(Data("hello".utf8), isStderr: false)
        let after = collector.lastActivity
        #expect(after > before)
    }
}
