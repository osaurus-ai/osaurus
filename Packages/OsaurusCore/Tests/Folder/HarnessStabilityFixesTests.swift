//
//  HarnessStabilityFixesTests.swift
//
//  Pins the harness-stability fixes proven necessary by the frontier
//  agent-loop evals and the FolderTools audit:
//    1. file_edit 0-match diagnostics (N| prefix / whitespace-only /
//       closest-line) — the reproducible grok-4.3 death-spiral input.
//    2. AgentTaskState held-error replay for deterministic folder-tool
//       failures, with fresh-read-parity invalidation rules.
//    3. summarizeToolResult honesty: file-kind branch keeps the real path,
//       and every compressed branch carries the re-fetch steer.
//    4. file_search glob escaping (metacharacters can no longer build a
//       regex that silently matches nothing) + skipped-file reporting +
//       structured truncation warnings.
//    5. shell_run idle-timeout clamp.
//    6. file_read partial-line truncation accounting.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HarnessStabilityFixesTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-harness-stability-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func warnings(_ envelope: String) -> [String] {
        guard let data = envelope.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return dict["warnings"] as? [String] ?? []
    }

    // MARK: - 1. file_edit 0-match diagnostics

    @Test func fileEditDiagnosis_detectsLineNumberPrefix() {
        // grok-4.3's observed failing shape: `N| ` prefixes copied straight
        // out of file_read output.
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "    42| item 042 value=42",
            content: "item 042 value=42\n"
        )
        #expect(diagnosis.contains("line-number prefixes"))
        #expect(diagnosis.contains("file_read"))
    }

    @Test func fileEditDiagnosis_whitespaceOnlyMismatchQuotesExactBytes() {
        // Leading space the file doesn't have (historically copied from the
        // old `N| ` read gutter; the gutter is now `N|` with no space, but
        // whitespace-only mismatches still happen and must stay diagnosed).
        let content = "alpha\nitem 042 value=42\nomega\n"
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: " item 042 value=42",
            content: content
        )
        #expect(diagnosis.contains("differing only in whitespace"))
        #expect(diagnosis.contains("line 2"))
        // The exact file bytes are quoted verbatim for copy-paste.
        #expect(diagnosis.contains("item 042 value=42"))
    }

    @Test func fileEditDiagnosis_multiLineWhitespaceMismatch() {
        let content = "func a() {\n    let x = 1\n    return x\n}\n"
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "let x = 1\nreturn x",
            content: content
        )
        #expect(diagnosis.contains("differing only in whitespace"))
        #expect(diagnosis.contains("line 2"))
        #expect(diagnosis.contains("    let x = 1\n    return x"))
    }

    @Test func fileEditDiagnosis_closestLineHint() {
        // Not a whitespace issue — content genuinely differs — but a
        // similar line exists; quote it with its real line number.
        let content = "one\nlet total = computeTotal(items)\nthree\n"
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "let total = computeTotal(items, tax)",
            content: content
        )
        #expect(diagnosis.contains("closest matching line"))
        #expect(diagnosis.contains("line 2"))
        #expect(diagnosis.contains("let total = computeTotal(items)"))
    }

    @Test func fileEditDiagnosis_fallbackWhenNothingSimilar() {
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "completely unrelated text",
            content: "alpha\nbeta\n"
        )
        #expect(diagnosis == "Make sure it exactly matches the file content.")
    }

    @Test func fileEditDiagnosis_blankLineCountDrift() {
        // Regression (E4B loop, ordered-procedure): the file has TWO blank
        // lines between sections, the model sent ONE. Check 2 (equal line
        // counts) can't fire and the old check-3 anchor pointed at a line
        // that looked identical — the model re-sent the same failing edit
        // until its budget died. Check 2b must quote the real region with
        // its real blank lines.
        let content = "step one\n\n\nstep two\ntail\n"
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "step one\n\nstep two",
            content: content
        )
        #expect(diagnosis.contains("blank lines between them differ"))
        #expect(diagnosis.contains("line 1"))
        // The quoted region carries BOTH real blank lines verbatim.
        #expect(diagnosis.contains("step one\n\n\nstep two"))
    }

    @Test func fileEditDiagnosis_blankLineDriftNotFiredOnAmbiguousMatch() {
        // Two candidate regions share the same non-blank lines — quoting
        // one would be a coin flip, so check 2b must stay silent and let
        // the later checks (or the fallback) speak instead.
        let content = "a\n\nb\nx\na\n\n\nb\n"
        let diagnosis = FileEditTool.noMatchDiagnosis(
            oldString: "a\n\n\n\nb",
            content: content
        )
        #expect(!diagnosis.contains("blank lines between them differ"))
    }

    @Test func fileEdit_endToEnd_noMatchEnvelopeCarriesDiagnosis() async throws {
        let root = tmpRoot()
        try "item 042 value=42\n".write(
            to: root.appendingPathComponent("data.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileEditTool(rootPath: root)
        // Leading space that isn't in the file (whitespace-only mismatch).
        let result = try await tool.execute(
            argumentsJSON:
                #"{"path": "data.txt", "old_string": " item 042 value=42", "new_string": "item 042 value=43"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        let message = ToolEnvelope.failureMessage(result)
        #expect(message.contains("differing only in whitespace"))
    }

    // MARK: - 2. Held-error replay (AgentTaskState)

    private func invalidArgsError(tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Could not find `old_string` in f.txt.",
            field: "old_string",
            expected: "exact text",
            tool: tool
        )
    }

    @Test func heldErrorReplay_replaysDeterministicFolderToolError() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt", "old_string": " x", "new_string": "y"}"#
        let error = invalidArgsError(tool: "file_edit")

        // Novel call: nothing held yet.
        #expect(state.heldResult(name: "file_edit", argsJSON: args) == nil)

        state.record(name: "file_edit", argsJSON: args, result: error)

        // Identical re-issue replays the EXACT envelope with an
        // escalating notice (original execution + 1 replay = 2 failures).
        let replay = state.heldResult(name: "file_edit", argsJSON: args)
        #expect(replay == error)
        #expect(state.lastReplayNotice?.contains("failed 2 times") == true)
        #expect(state.lastReplayNotice?.contains("change the arguments") == true)

        // Escalation counts up on every replay.
        _ = state.heldResult(name: "file_edit", argsJSON: args)
        #expect(state.lastReplayNotice?.contains("failed 3 times") == true)
    }

    @Test func heldErrorReplay_keyIsCanonicalised() {
        let state = AgentTaskState()
        let error = invalidArgsError(tool: "file_edit")
        state.record(
            name: "file_edit",
            argsJSON: #"{"path": "f.txt", "old_string": " x", "new_string": "y"}"#,
            result: error
        )
        // Same args, different key order: same signature, same replay.
        let replay = state.heldResult(
            name: "file_edit",
            argsJSON: #"{"new_string": "y", "old_string": " x", "path": "f.txt"}"#
        )
        #expect(replay == error)
    }

    @Test func heldErrorReplay_writeToSamePathInvalidates() {
        let state = AgentTaskState()
        let readArgs = #"{"path": "missing.txt"}"#
        let notFound = ToolEnvelope.failure(
            kind: .notFound,
            message: "File not found: missing.txt",
            tool: "file_read"
        )
        state.record(name: "file_read", argsJSON: readArgs, result: notFound)
        #expect(state.heldResult(name: "file_read", argsJSON: readArgs) == notFound)

        // file_write CREATES the file — the identical read could now
        // succeed, so the held error must clear (path canonicalization
        // shared with fresh reads: `./missing.txt` matches `missing.txt`).
        state.record(
            name: "file_write",
            argsJSON: #"{"path": "./missing.txt", "content": "hi"}"#,
            result: ToolEnvelope.success(tool: "file_write", result: ["path": "missing.txt"])
        )
        #expect(state.heldResult(name: "file_read", argsJSON: readArgs) == nil)
    }

    @Test func heldErrorReplay_writeToOtherPathDoesNotInvalidate() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt", "old_string": " x", "new_string": "y"}"#
        let error = invalidArgsError(tool: "file_edit")
        state.record(name: "file_edit", argsJSON: args, result: error)

        state.record(
            name: "file_write",
            argsJSON: #"{"path": "unrelated.txt", "content": "hi"}"#,
            result: ToolEnvelope.success(tool: "file_write", result: ["path": "unrelated.txt"])
        )
        #expect(state.heldResult(name: "file_edit", argsJSON: args) == error)
    }

    @Test func heldErrorReplay_execWipesAllHeldErrors() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt", "old_string": " x", "new_string": "y"}"#
        state.record(name: "file_edit", argsJSON: args, result: invalidArgsError(tool: "file_edit"))

        // A shell command may have fixed the file (sed/touch/mv) — every
        // held error clears regardless of path.
        state.record(
            name: "shell_run",
            argsJSON: #"{"command": "sed -i '' s/a/b/ f.txt"}"#,
            result: ToolEnvelope.success(tool: "shell_run", result: ["exit_code": 0])
        )
        #expect(state.heldResult(name: "file_edit", argsJSON: args) == nil)
    }

    @Test func heldErrorReplay_searchErrorsClearedByAnyWrite() {
        let state = AgentTaskState()
        let args = #"{"pattern": "TODO", "path": "missing-dir"}"#
        let notFound = ToolEnvelope.failure(
            kind: .notFound,
            message: "File not found: missing-dir",
            tool: "file_search"
        )
        state.record(name: "file_search", argsJSON: args, result: notFound)
        #expect(state.heldResult(name: "file_search", argsJSON: args) == notFound)

        // A write ANYWHERE clears a held search error (the write may have
        // created the missing dir as a parent).
        state.record(
            name: "file_write",
            argsJSON: #"{"path": "missing-dir/new.txt", "content": "hi"}"#,
            result: ToolEnvelope.success(tool: "file_write", result: ["path": "missing-dir/new.txt"])
        )
        #expect(state.heldResult(name: "file_search", argsJSON: args) == nil)
    }

    @Test func heldErrorReplay_shellRunErrorsAreNeverHeld() {
        let state = AgentTaskState()
        let args = #"{"command": "curl https://flaky.example"}"#
        let error = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "boom",
            tool: "shell_run"
        )
        state.record(name: "shell_run", argsJSON: args, result: error)
        // Identical shell retries are legitimate — always re-execute.
        #expect(state.heldResult(name: "shell_run", argsJSON: args) == nil)
    }

    @Test func heldErrorReplay_nonDeterministicErrorKindsAreNotHeld() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt"}"#
        let execError = ToolEnvelope.failure(
            kind: .executionError,
            message: "transient IO failure",
            tool: "file_read"
        )
        state.record(name: "file_read", argsJSON: args, result: execError)
        #expect(state.heldResult(name: "file_read", argsJSON: args) == nil)
    }

    @Test func heldErrorReplay_successSupersedesHeldError() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt", "old_string": "x", "new_string": "y"}"#
        state.record(name: "file_edit", argsJSON: args, result: invalidArgsError(tool: "file_edit"))
        // Same call later succeeds (file changed externally): held error
        // must be dropped, not replayed over the success.
        state.record(
            name: "file_edit",
            argsJSON: args,
            result: ToolEnvelope.success(tool: "file_edit", result: ["path": "f.txt"])
        )
        #expect(state.heldResult(name: "file_edit", argsJSON: args) == nil)
    }

    @Test func heldErrorReplay_freshReadReplayHasNoEscalationNotice() {
        let state = AgentTaskState()
        let args = #"{"path": "a.txt"}"#
        let env = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "text": "hello", "path": "a.txt"]
        )
        state.record(name: "file_read", argsJSON: args, result: env)
        let replay = state.heldResult(name: "file_read", argsJSON: args)
        #expect(replay == env)
        // Fresh-read replays use the driver's standard dedupe notice; the
        // escalation notice is reserved for held ERRORS.
        #expect(state.lastReplayNotice == nil)
    }

    @Test func heldErrorReplay_beginMessageClears() {
        let state = AgentTaskState()
        let args = #"{"path": "f.txt", "old_string": "x", "new_string": "y"}"#
        state.record(name: "file_edit", argsJSON: args, result: invalidArgsError(tool: "file_edit"))
        state.beginMessage()
        #expect(state.heldResult(name: "file_edit", argsJSON: args) == nil)
    }

    // MARK: - 3. summarizeToolResult honesty

    @Test func summarize_fileKindKeepsPathAndSteer() {
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            result: [
                "kind": "file",
                "text": String(repeating: "line\n", count: 100),
                "path": "logs/log1.txt",
                "total_lines": 100,
            ]
        )
        let summary = ContextBudgetManager.summarizeToolResult(envelope, toolCallId: nil)
        #expect(summary.contains("logs/log1.txt"))
        #expect(summary.contains("100 lines"))
        #expect(summary.contains("re-read the file"))
        // The compressed summary must not retain file content.
        #expect(!summary.contains("line\nline"))
    }

    @Test func summarize_shellBranchCarriesRefetchSteer() {
        let content = "Exit code: 0\n" + String(repeating: "build output\n", count: 50)
        let summary = ContextBudgetManager.summarizeToolResult(content, toolCallId: nil)
        #expect(summary.contains("Exit code: 0"))
        #expect(summary.contains("do not recall from memory"))
    }

    @Test func summarize_genericBranchCarriesRefetchSteer() {
        let content = String(repeating: "x", count: 500)
        let summary = ContextBudgetManager.summarizeToolResult(content, toolCallId: nil)
        #expect(summary.contains("do not recall from memory"))
    }

    @Test func summarize_smallResultsUntouched() {
        let content = "ok"
        #expect(ContextBudgetManager.summarizeToolResult(content, toolCallId: nil) == "ok")
    }

    // MARK: - 4. file_search correctness

    @Test func globToRegex_escapesMetacharacters() {
        // `+` is a regex quantifier; unescaped it made `c++*` an invalid
        // or wrong regex that matched nothing.
        #expect(FolderToolHelpers.matchesPattern("main.cpp", pattern: "*.cpp"))
        #expect(FolderToolHelpers.matchesPattern("lib+extras.txt", pattern: "lib+*"))
        #expect(FolderToolHelpers.matchesPattern("file(1).txt", pattern: "file(1).*"))
        #expect(FolderToolHelpers.matchesPattern("data[old].csv", pattern: "data[old]*"))
        #expect(!FolderToolHelpers.matchesPattern("dataXold.csv", pattern: "data[old]*"))
        // `.` must stay literal: `*.swift` must not match `xswift`.
        #expect(!FolderToolHelpers.matchesPattern("xswift", pattern: "*.swift"))
    }

    @Test func fileSearch_filePatternWithMetacharacters() async throws {
        let root = tmpRoot()
        try "needle here\n".write(
            to: root.appendingPathComponent("notes (draft).txt"),
            atomically: true,
            encoding: .utf8
        )
        try "needle here\n".write(
            to: root.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"pattern": "needle", "file_pattern": "notes (draft).*"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("notes (draft).txt"))
        #expect(!text.contains("other.txt"))
    }

    @Test func fileSearch_reportsSkippedFiles() async throws {
        let root = tmpRoot()
        // Binary-extension file: never searched, must be COUNTED.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("image.png"))
        try "nothing relevant\n".write(
            to: root.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"pattern": "zzz-no-match"}"#)
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("No matches found"))
        #expect(text.contains("1 file(s) skipped"))
        #expect(warnings(result).contains(where: { $0.contains("skipped") }))
    }

    @Test func fileSearch_filesTargetMatchesPathPrefix() async throws {
        // Regression (E4B loop, kitchen-sink): `pattern: "orders/"` in files
        // mode matched NOTHING for three existing orders/*.txt files (the
        // matcher only saw basenames) — the model then asked the user
        // instead of finishing. Slash-bearing queries must match the
        // relative path.
        let root = tmpRoot()
        let ordersDir = root.appendingPathComponent("orders")
        try FileManager.default.createDirectory(at: ordersDir, withIntermediateDirectories: true)
        for i in 1 ... 3 {
            try "id=A\(i)\namount=\(i)\n".write(
                to: ordersDir.appendingPathComponent("order\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        try "other\n".write(
            to: root.appendingPathComponent("readme.md"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"pattern": "orders/", "target": "files"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        // Files-mode returns structured `entries[]`, not prose text —
        // assert against the raw envelope.
        #expect(result.contains("order1.txt"))
        #expect(result.contains("order2.txt"))
        #expect(result.contains("order3.txt"))
        #expect(!result.contains("readme.md"))
    }

    @Test func fileSearch_filesTargetBasenameStillWorks() async throws {
        let root = tmpRoot()
        try "x\n".write(
            to: root.appendingPathComponent("quarterly_q4.csv"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"pattern": "q4", "target": "files"}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        #expect(result.contains("quarterly_q4.csv"))
    }

    @Test func fileSearch_structuredTruncationWarning() async throws {
        let root = tmpRoot()
        let body = (1 ... 20).map { "match line \($0)" }.joined(separator: "\n")
        try body.write(
            to: root.appendingPathComponent("hits.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"pattern": "match line", "max_results": 5}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("Found 5 match(es)"))
        #expect(warnings(result).contains(where: { $0.contains("truncated at 5") }))
    }

    // MARK: - 5. shell_run idle-timeout clamp

    @Test func shellRun_timeoutClamp() {
        #expect(ShellRunTool.clampIdleTimeout(nil) == nil)
        #expect(ShellRunTool.clampIdleTimeout(0) == nil)
        #expect(ShellRunTool.clampIdleTimeout(-30) == nil)
        #expect(ShellRunTool.clampIdleTimeout(1) == 1)
        #expect(ShellRunTool.clampIdleTimeout(300) == 300)
        #expect(ShellRunTool.clampIdleTimeout(3600) == 3600)
        #expect(ShellRunTool.clampIdleTimeout(99999) == 3600)
    }

    @Test func shellRun_idleKillEnvelopeIsHonest() async throws {
        let root = tmpRoot()
        let tool = ShellRunTool(rootPath: root)
        // Emits once then sleeps far past the 1s idle ceiling.
        let result = try await tool.execute(
            argumentsJSON: #"{"command": "echo started; sleep 30; echo done", "timeout": 1}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["killed_by"] as? String == "idle_timeout")
        #expect(payload?["idle_timeout_seconds"] as? Int == 1)
        #expect((payload?["stdout"] as? String)?.contains("started") == true)
        #expect((payload?["stdout"] as? String)?.contains("done") != true)
        #expect(warnings(result).contains(where: { $0.contains("idle-timeout watchdog") }))
    }

    @Test func shellRun_headlessDefaultIdleTimeoutApplies() async throws {
        let root = tmpRoot()
        let tool = ShellRunTool(rootPath: root)
        // No `timeout` argument: the task-local default (bound by headless
        // drivers) supplies the idle ceiling.
        let result = try await ChatExecutionContext.$defaultShellIdleTimeout.withValue(1) {
            try await tool.execute(argumentsJSON: #"{"command": "echo hi; sleep 30"}"#)
        }
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["killed_by"] as? String == "idle_timeout")
    }

    @Test func shellRun_explicitTimeoutBeatsHeadlessDefault() async throws {
        let root = tmpRoot()
        let tool = ShellRunTool(rootPath: root)
        // Model passed `timeout: 5`; the 1s default must NOT pre-empt it —
        // a 2s-quiet command finishes normally.
        let result = try await ChatExecutionContext.$defaultShellIdleTimeout.withValue(1) {
            try await tool.execute(argumentsJSON: #"{"command": "sleep 2; echo done", "timeout": 5}"#)
        }
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["killed_by"] == nil)
        #expect((payload?["stdout"] as? String)?.contains("done") == true)
        #expect(payload?["exit_code"] as? Int == 0)
    }

    // MARK: - 6. file_read partial-line accounting

    @Test func fileRead_partialLineCutIsReportedAsPartial() async throws {
        let root = tmpRoot()
        // Line 1 fits under the cap; line 2 gets cut mid-way.
        let content = "short line one\n" + String(repeating: "B", count: 300) + "\nline three\n"
        try content.write(
            to: root.appendingPathComponent("wide.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(
            argumentsJSON: #"{"path": "wide.txt", "max_chars": 60}"#
        )
        #expect(ToolEnvelope.isSuccess(result))
        let payload = EnvelopeAssertions.successPayload(result)
        // Line 2 was only partially shown — it must NOT be counted as
        // included; line 1 is the last complete line.
        #expect(payload?["end_line"] as? Int == 1)
        #expect(payload?["partial_line"] as? Int == 2)
        #expect(payload?["truncated"] as? Bool == true)
        let text = (payload?["text"] as? String) ?? ""
        #expect(text.contains("PARTIALLY"))
        #expect(text.contains("line 2"))
    }

    @Test func fileRead_cleanLineBoundaryHasNoPartialMarker() async throws {
        let root = tmpRoot()
        let content = (1 ... 50).map { "line \($0)" }.joined(separator: "\n")
        try content.write(
            to: root.appendingPathComponent("plain.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path": "plain.txt"}"#)
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["partial_line"] == nil)
        #expect(payload?["end_line"] as? Int == 50)
    }

    // MARK: - 7. file_read trailing-newline metadata

    // Regression (E4B loop, ordered-procedure): the numbered gutter can't
    // express whether the last line is `\n`-terminated, so a byte-exact
    // copy reconstructed from a read was one byte short. The payload now
    // states it outright.

    @Test func fileRead_reportsTrailingNewlinePresent() async throws {
        let root = tmpRoot()
        try "alpha\nbeta\n".write(
            to: root.appendingPathComponent("terminated.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path": "terminated.txt"}"#)
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["ends_with_newline"] as? Bool == true)
    }

    @Test func fileRead_reportsTrailingNewlineAbsent() async throws {
        let root = tmpRoot()
        try "alpha\nbeta".write(
            to: root.appendingPathComponent("unterminated.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path": "unterminated.txt"}"#)
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["ends_with_newline"] as? Bool == false)
    }
}
