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

    private func withSession<T>(
        _ sessionId: String = "folder-tools-\(UUID().uuidString)",
        body: (String) async throws -> T
    ) async throws -> T {
        try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await body(sessionId)
        }
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

    /// Regression for the old `(empty file)` lie at the bottom of
    /// `FileReadTool.execute`. A single oversized line now returns the
    /// leading slice inside the success envelope plus a truncation note,
    /// instead of pretending the file had no content.
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
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.hasPrefix("     1|"), "got: \(text.prefix(40))")
        #expect(text.contains("(empty file)") == false)
        // The char cap cut line 1 mid-way: it is reported as PARTIAL, not
        // counted as an included line (honest partial-line accounting).
        #expect(text.contains("line 1 is only PARTIALLY shown"))
        #expect(payload["partial_line"] as? Int == 1)
        #expect(payload["truncated"] as? Bool == true)
        #expect(payload["raw_bytes_truncated"] as? Bool == false)
    }

    /// Raw text / CSV reads are part of the prompt-building hot path. A
    /// huge file should be capped before full-file loading, with explicit
    /// envelope metadata so the model understands it only saw a prefix.
    @Test func fileRead_largeRawFileCapsBytesBeforeDecode() async throws {
        let root = tmpRoot()
        let path = root.appendingPathComponent("huge.csv")
        let size = 6 * 1024 * 1024
        try Data(repeating: 0x61, count: size).write(to: path)

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "huge.csv"}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let text = try #require(payload["text"] as? String)
        let bytesRead = try #require(payload["bytes_read"] as? Int)
        let byteLimit = try #require(payload["byte_limit"] as? Int)
        let fileSize = try #require(payload["file_size"] as? Int)

        #expect(byteLimit == 5 * 1024 * 1024)
        #expect(bytesRead <= byteLimit)
        #expect(fileSize == size)
        #expect(payload["raw_bytes_truncated"] as? Bool == true)
        #expect(payload["total_lines_exact"] as? Bool == false)
        #expect(payload["truncated"] as? Bool == true)
        #expect(text.contains("raw read capped at 5 MiB"))
    }

    /// The success payload carries a single line-numbered `text` field — no
    /// duplicate raw `content`. Sending both doubled the retained token cost
    /// of every read under `store:false`; the model reads ranges from `text`.
    @Test func fileRead_successPayloadIsSingleLineNumberedField() async throws {
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
        // The duplicate raw-content field is gone.
        #expect(payload["content"] == nil)
        #expect(payload["start_line"] as? Int == 1)
        #expect(payload["end_line"] as? Int == 1)
        #expect(payload["total_lines"] as? Int == 3)
        #expect(payload["total_lines_exact"] as? Bool == true)
        #expect(payload["truncated"] as? Bool == false)
        #expect(payload["raw_bytes_truncated"] as? Bool == false)
        let text = try #require(payload["text"] as? String)
        #expect(text.contains("1|#!/usr/bin/env python3"))
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

    @Test func fileWrite_rejectsWorkbookPackagesWithoutTouchingExistingFile() async throws {
        let root = tmpRoot()
        let existing = root.appendingPathComponent("report.xlsx")
        let original = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
        try original.write(to: existing)

        let tool = FileWriteTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "report.xlsx", "content": "not a workbook"}"#
        )

        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "rejected")
        #expect(failureField(result) == "path")
        #expect(result.contains("structured workbook"))
        let after = try Data(contentsOf: existing)
        #expect(after == original)
    }

    @Test func fileWrite_allowsCSVTextOutput() async throws {
        let root = tmpRoot()
        let tool = FileWriteTool(rootPath: root)

        let result = try await tool.execute(
            argumentsJSON: #"{"path": "report.csv", "content": "month,total\nJan,1200\n"}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let written = try String(
            contentsOf: root.appendingPathComponent("report.csv"),
            encoding: .utf8
        )
        #expect(written == "month,total\nJan,1200\n")
    }

    @Test func fileWrite_rejectsPDFAndPresentationPackagesWithoutTouchingExistingFile() async throws {
        let root = tmpRoot()
        let cases: [(name: String, bytes: [UInt8])] = [
            ("report.pdf", [0x25, 0x50, 0x44, 0x46]),
            ("deck.pptx", [0x50, 0x4B, 0x03, 0x04]),
        ]

        let tool = FileWriteTool(rootPath: root)
        for item in cases {
            let target = root.appendingPathComponent(item.name)
            let original = Data(item.bytes)
            try original.write(to: target)

            let result = try await tool.execute(
                argumentsJSON: #"{"path": "\#(item.name)", "content": "fake structured output"}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(failureKind(result) == "rejected")
            #expect(failureField(result) == "path")
            let after = try Data(contentsOf: target)
            #expect(after == original)
        }
    }

    @Test func fileWrite_dryRunPreviewsDiffWithoutWritingOrLogging() async throws {
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()
        let path = root.appendingPathComponent("note.txt")
        try "alpha\nbeta\n".write(to: path, atomically: true, encoding: .utf8)

        try await withSession { sessionId in
            let tool = FileWriteTool(rootPath: root)
            let result = try await tool.execute(
                argumentsJSON: #"{"path": "note.txt", "content": "alpha\ngamma\n", "dry_run": true}"#
            )

            #expect(ToolEnvelope.isSuccess(result))
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["kind"] as? String == "workspace_write_preview")
            #expect(payload["dry_run"] as? Bool == true)
            #expect(payload["applied"] as? Bool == false)
            let diff = try #require(payload["diff"] as? String)
            #expect(diff.contains("-beta"))
            #expect(diff.contains("+gamma"))

            let after = try String(contentsOf: path, encoding: .utf8)
            #expect(after == "alpha\nbeta\n")
            let operations = await FileOperationLog.shared.operations(for: sessionId)
            #expect(operations.isEmpty)
        }
    }

    @Test func fileWrite_applyLogsInspectableOperationHistory() async throws {
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()

        try await withSession { _ in
            let write = FileWriteTool(rootPath: root)
            let writeResult = try await write.execute(
                argumentsJSON: "{\"path\": \"nested/report.md\", \"content\": \"# Report\\n\"}"
            )
            #expect(ToolEnvelope.isSuccess(writeResult))
            let writePayload = try #require(EnvelopeAssertions.successPayload(writeResult))
            #expect(writePayload["kind"] as? String == "workspace_write_result")
            #expect(writePayload["operation_id"] as? String != nil)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("nested/report.md").path))

            let history = FileOperationHistoryTool(rootPath: root)
            let historyResult = try await history.execute(argumentsJSON: #"{"limit": 5}"#)
            #expect(ToolEnvelope.isSuccess(historyResult))
            let historyPayload = try #require(EnvelopeAssertions.successPayload(historyResult))
            #expect(historyPayload["kind"] as? String == "file_operation_history")
            let entries = try #require(historyPayload["entries"] as? [[String: Any]])
            #expect(entries.count == 1)
            #expect(entries.first?["type"] as? String == "create")
            #expect(entries.first?["path"] as? String == "nested/report.md")
        }
    }

    @Test func fileWrite_rejectsExistingNonUTF8TextTarget() async throws {
        let root = tmpRoot()
        let path = root.appendingPathComponent("blob.txt")
        let original = Data([0xFF, 0x00, 0xAB])
        try original.write(to: path)

        let tool = FileWriteTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "blob.txt", "content": "replacement"}"#
        )

        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "rejected")
        #expect(failureField(result) == "path")
        let after = try Data(contentsOf: path)
        #expect(after == original)
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

    @Test func fileEdit_dryRunPreviewsDiffWithoutMutatingOrLogging() async throws {
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()
        let path = root.appendingPathComponent("f.txt")
        try "hello world\n".write(to: path, atomically: true, encoding: .utf8)

        try await withSession { sessionId in
            let tool = FileEditTool(rootPath: root)
            let result = try await tool.execute(
                argumentsJSON: #"{"path": "f.txt", "old_string": "world", "new_string": "mars", "dry_run": true}"#
            )

            #expect(ToolEnvelope.isSuccess(result))
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["kind"] as? String == "workspace_write_preview")
            #expect(payload["operation"] as? String == "file_edit")
            let diff = try #require(payload["diff"] as? String)
            #expect(diff.contains("-hello world"))
            #expect(diff.contains("+hello mars"))

            let after = try String(contentsOf: path, encoding: .utf8)
            #expect(after == "hello world\n")
            let operations = await FileOperationLog.shared.operations(for: sessionId)
            #expect(operations.isEmpty)
        }
    }

    @Test func fileEdit_duplicateMatchReturnsStructuredArgumentError() async throws {
        let root = tmpRoot()
        let path = root.appendingPathComponent("f.txt")
        try "same\nsame\n".write(to: path, atomically: true, encoding: .utf8)

        let tool = FileEditTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "f.txt", "old_string": "same", "new_string": "other"}"#
        )

        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "invalid_args")
        #expect(failureField(result) == "old_string")
        let after = try String(contentsOf: path, encoding: .utf8)
        #expect(after == "same\nsame\n")
    }

    @Test func fileOperationHistory_requiresSessionContext() async throws {
        let tool = FileOperationHistoryTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureKind(result) == "unavailable")
    }

    // MARK: - file_undo

    /// Models routinely echo `path` alongside the `operation_id` they got
    /// from the write result (observed live: gemma-4-12B sent both, got the
    /// old blanket "Pass `operation_id` OR `path`, not both." rejection, and
    /// spiralled into a blind full-file rewrite). Agreeing arguments are
    /// redundant, not ambiguous — the undo must run.
    @Test func fileUndo_operationIdWithAgreeingPathUndoes() async throws {
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()
        // performUndo resolves relative paths against the log's root (set by
        // folder-context activation in the app).
        await FileOperationLog.shared.setRootPath(root)
        let file = root.appendingPathComponent("CHANGELOG.md")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)

        try await withSession { _ in
            let write = FileWriteTool(rootPath: root)
            let writeResult = try await write.execute(
                argumentsJSON: #"{"path": "CHANGELOG.md", "content": "clobbered\n"}"#
            )
            let opId = try #require(
                EnvelopeAssertions.successPayload(writeResult)?["operation_id"] as? String
            )

            let undo = FileUndoTool(rootPath: root)
            let result = try await undo.execute(
                argumentsJSON: #"{"operation_id": "\#(opId)", "path": "CHANGELOG.md"}"#
            )
            #expect(ToolEnvelope.isSuccess(result), "got: \(result)")
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["undone_count"] as? Int == 1)
            let after = try String(contentsOf: file, encoding: .utf8)
            #expect(after == "original\n")
        }
        await FileOperationLog.shared.setRootPath(nil)
    }

    /// A genuine DISAGREEMENT (id belongs to one file, path names another)
    /// stays refused — but with a message that names the real file so the
    /// model can pick the right argument on the next call.
    @Test func fileUndo_operationIdWithConflictingPathIsRefusedWithDiagnosis() async throws {
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()
        try "keep\n".write(
            to: root.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await withSession { _ in
            let write = FileWriteTool(rootPath: root)
            let writeResult = try await write.execute(
                argumentsJSON: #"{"path": "a.txt", "content": "changed\n"}"#
            )
            let opId = try #require(
                EnvelopeAssertions.successPayload(writeResult)?["operation_id"] as? String
            )

            let undo = FileUndoTool(rootPath: root)
            let result = try await undo.execute(
                argumentsJSON: #"{"operation_id": "\#(opId)", "path": "other.txt"}"#
            )
            #expect(ToolEnvelope.isError(result))
            #expect(failureKind(result) == "invalid_args")
            let message = EnvelopeAssertions.failureMessage(result) ?? ""
            #expect(message.contains("a.txt"))
            #expect(message.contains("other.txt"))
            // The operation must NOT have been undone by the refused call.
            let after = try String(
                contentsOf: root.appendingPathComponent("a.txt"),
                encoding: .utf8
            )
            #expect(after == "changed\n")
        }
    }

    // MARK: - file_tree

    /// A wide directory (many sibling files) must not dump the whole listing
    /// into the retained context: files past the per-directory cap collapse
    /// into a `... +N more files` summary so the payload stays lean.
    @Test func fileTree_collapsesWideDirectory() async throws {
        let root = tmpRoot()
        for i in 0 ..< 600 {
            let name = "file_with_a_reasonably_long_name_\(i).txt"
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(name).path,
                contents: Data("x".utf8)
            )
        }
        let tool = FileTreeTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: "{}")
        let text = EnvelopeAssertions.successText(result) ?? result
        #expect(text.contains("more files"))
        // Collapsing keeps the payload tiny vs. the ~600-line raw listing.
        #expect(text.count < 4000)
        // Only the per-directory cap worth of files is listed individually.
        let listedFiles = text.components(separatedBy: "\n").filter {
            $0.contains("file_with_a_reasonably_long_name_")
        }
        #expect(listedFiles.count == 20)
    }

    // MARK: - file_search

    @Test func fileSearch_missingPattern() async throws {
        let tool = FileSearchTool(rootPath: tmpRoot())
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(failureField(result) == "pattern")
    }

    @Test func fileSearch_contentPathsStayRootRelativeUnderSymlinkedRoot() async throws {
        // The gemma-4-12B `search-then-multi-file-edit` failure: eval (and
        // chat) workspaces live under `FileManager.temporaryDirectory` =
        // `/var/folders/...`, a macOS firmlink onto `/private/var/...`. The
        // enumerator returns REAL (`/private/var`) urls, the old naive
        // `hasPrefix(rootPath.path)` missed, and every nested match was
        // flattened to its basename — `src/client.py` reported as
        // `client.py:1: ...`. The model then fed `client.py` into
        // `file_edit`/`file_read` and got "File not found" for a file the
        // search itself had just reported, looping until the iteration cap.
        let root = tmpRoot()  // under temporaryDirectory → firmlinked path
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "from api import fetchDataV1\n".write(
            to: src.appendingPathComponent("client.py"),
            atomically: true,
            encoding: .utf8
        )

        let tool = FileSearchTool(rootPath: root)

        // Content mode: matched lines must carry the root-relative path.
        let content = try await tool.execute(
            argumentsJSON: #"{"pattern": "fetchDataV1"}"#
        )
        #expect(content.contains("src/client.py:1:"))
        #expect(!content.contains("\"client.py:1:"))

        // Files mode: the structured `path` field must be root-relative too.
        let files = try await tool.execute(
            argumentsJSON: #"{"pattern": "client.py", "target": "files"}"#
        )
        #expect(files.contains(#""path":"src\/client.py""#) || files.contains(#""path":"src/client.py""#))
    }

    @Test func fileRead_directoryListingPathsStayRootRelativeUnderSymlinkedRoot() async throws {
        // Same firmlink flattening as the search case, via the directory
        // listing route (`file_read` on a directory): nested entry `path`s
        // must be copy-pasteable into the next tool call.
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "x = 1\n".write(
            to: src.appendingPathComponent("client.py"),
            atomically: true,
            encoding: .utf8
        )

        let tool = FileReadTool(rootPath: root)
        let listing = try await tool.execute(argumentsJSON: #"{"path": "."}"#)
        #expect(listing.contains(#""path":"src\/client.py""#) || listing.contains(#""path":"src/client.py""#))
    }

    @Test func fileRead_payloadCarriesLineFormatContract() async throws {
        // `duplicate-call-avoidance`: given `     1|41`, gemma-4-12B read
        // "1" as the first data value — the only gutter explanation lived
        // in the tool schema, far from the payload. Every file read result
        // must carry the one-line `line_format` self-description.
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "41\n7\n".write(
            to: root.appendingPathComponent("numbers.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path": "numbers.txt"}"#)
        #expect(result.contains("line_format"))
        #expect(result.contains("content starts after the first"))
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
