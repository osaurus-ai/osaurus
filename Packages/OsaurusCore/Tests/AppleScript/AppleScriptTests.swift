//
//  AppleScriptTests.swift
//  OsaurusCoreTests — AppleScript Computer Use
//
//  Deterministic coverage for the AppleScript subagent seams that don't need a
//  live model:
//   • `AppleScriptAction.decode` — JSON → script / re-ask reason, incl. fence
//     stripping and blank-script rejection.
//   • `AppleScriptExecutor` — real in-process `NSAppleScript` mapping for the
//     three outcomes a pure (no-automation) script can produce: success output,
//     compile error, runtime error + error number. (Permission `-1743` and
//     timeout are environment-dependent and proven live, not here.)
//   • `AppleScriptLoop` — the gate/feed/termination logic over injected model +
//     executor seams: confirm-each approve/deny, auto-run-with-warning, natural
//     completion on a no-tool-call turn, bounded invalid re-ask, step cap, and
//     interrupt.
//   • Capability gating — `visibleDelegationToolNames` withholds `applescript`
//     until BOTH the per-agent/global switch is on AND a model is installed, and
//     `AppleScriptExecutionMode` decodes leniently.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Decode

@Suite("AppleScriptAction.decode")
struct AppleScriptActionDecodeTests {
    @Test("a well-formed call decodes to the trimmed script")
    func validScript() {
        let decoded = AppleScriptAction.decode(argumentsJSON: #"{"script":"return 1"}"#)
        #expect(decoded == .script("return 1"))
    }

    @Test("a Markdown code fence around the script is stripped")
    func stripsFence() {
        let decoded = AppleScriptAction.decode(
            argumentsJSON: #"{"script":"```applescript\nreturn 1\n```"}"#
        )
        #expect(decoded == .script("return 1"))
    }

    @Test("a blank script is rejected with a re-ask reason")
    func blankScriptInvalid() {
        let decoded = AppleScriptAction.decode(argumentsJSON: #"{"script":"   "}"#)
        guard case .invalid = decoded else {
            Issue.record("expected .invalid, got \(decoded)")
            return
        }
    }

    @Test("a missing script field is rejected")
    func missingScriptInvalid() {
        let decoded = AppleScriptAction.decode(argumentsJSON: "{}")
        guard case .invalid = decoded else {
            Issue.record("expected .invalid, got \(decoded)")
            return
        }
    }

    @Test("non-JSON arguments are rejected")
    func nonJSONInvalid() {
        let decoded = AppleScriptAction.decode(argumentsJSON: "not json at all")
        guard case .invalid = decoded else {
            Issue.record("expected .invalid, got \(decoded)")
            return
        }
    }

    @Test("a pre-validated _error envelope surfaces its message")
    func errorEnvelopeSurfacesMessage() {
        let decoded = AppleScriptAction.decode(
            argumentsJSON:
                #"{"_error":"invalid_tool_arguments","_message":"script must be a string"}"#
        )
        guard case .invalid(let reason) = decoded else {
            Issue.record("expected .invalid, got \(decoded)")
            return
        }
        #expect(reason == "script must be a string")
    }
}

// MARK: - Executor (real NSAppleScript, no automation)

// `.serialized`: these drive the real, process-wide single OSA scripting
// component. The executor already serializes internally, but running the suite
// serially keeps the proof clean and documents that NSAppleScript is a shared,
// non-concurrent resource.
@Suite("AppleScriptExecutor mapping", .serialized)
struct AppleScriptExecutorMappingTests {
    @Test("a string-returning script succeeds and coerces its output")
    func successOutput() async {
        let result = await AppleScriptExecutor.run(
            source: "return \"hello world\"",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "hello world")
        #expect(result.errorNumber == nil)
    }

    @Test("a syntax error maps to compileError")
    func compileError() async {
        // Unterminated string literal — never compiles.
        let result = await AppleScriptExecutor.run(
            source: "return \"unterminated",
            timeout: 15
        )
        #expect(result.status == .compileError)
    }

    @Test("a runtime error maps to runtimeError and carries the error number")
    func runtimeError() async {
        let result = await AppleScriptExecutor.run(
            source: "error \"boom\" number 42",
            timeout: 15
        )
        #expect(result.status == .runtimeError)
        #expect(result.errorNumber == 42)
    }

    @Test("an integer result coerces to its text value")
    func integerOutput() async {
        let result = await AppleScriptExecutor.run(source: "return 42", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "42")
    }

    @Test("a boolean result coerces to true/false")
    func booleanOutput() async {
        let result = await AppleScriptExecutor.run(source: "return true", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "true")
    }

    @Test("a numeric list coerces to a comma-joined string")
    func listOutput() async {
        let result = await AppleScriptExecutor.run(source: "return {1, 2, 3}", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "1, 2, 3")
    }

    @Test("a string list coerces to a comma-joined string")
    func stringListOutput() async {
        let result = await AppleScriptExecutor.run(source: "return {\"a\", \"b\"}", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "a, b")
    }
}

// MARK: - Literal placeholders (deterministic substitution)

@Suite("AppleScriptLiterals")
struct AppleScriptLiteralsTests {
    @Test("escaper escapes backslash, quote, and whitespace controls; preserves UTF-8")
    func escaper() {
        // Input chars: a \ b " c <newline> d <tab> e — ’(U+2019)
        let escaped = AppleScriptLiterals.escapeForAppleScriptLiteral("a\\b\"c\nd\te—\u{2019}")
        #expect(escaped == "a\\\\b\\\"c\\nd\\te—\u{2019}")
    }

    @Test("expand replaces a token with a complete quoted, escaped literal")
    func expandBasic() {
        let literals = AppleScriptLiterals(["content": "he said \"hi\"\nbye"])
        let out = literals.expand("set body to {{content}}")
        #expect(out.undefinedName == nil)
        #expect(out.script == "set body to \"he said \\\"hi\\\"\\nbye\"")
    }

    @Test("expand absorbs the model's surrounding quotes so it isn't double-quoted")
    func expandAbsorbsQuotes() {
        let literals = AppleScriptLiterals(["content": "x"])
        let out = literals.expand("set body to \"{{content}}\"")
        #expect(out.script == "set body to \"x\"")
    }

    @Test("expand replaces every occurrence and handles multiple names")
    func expandRepeatsAndMultiple() {
        let literals = AppleScriptLiterals(["a": "1", "b": "2"])
        let out = literals.expand("{{a}} {{b}} {{a}}")
        #expect(out.script == "\"1\" \"2\" \"1\"")
        #expect(out.undefinedName == nil)
    }

    @Test("expand reports the first unknown token and leaves it in place")
    func expandUnknown() {
        let literals = AppleScriptLiterals(["content": "x"])
        let out = literals.expand("set body to {{missing}}")
        #expect(out.undefinedName == "missing")
        #expect(out.script.contains("{{missing}}"))
    }

    @Test("expand is a no-op when the script has no tokens")
    func expandNoTokens() {
        let literals = AppleScriptLiterals(["content": "x"])
        let out = literals.expand("return 1")
        #expect(out.script == "return 1")
        #expect(out.undefinedName == nil)
    }

    @Test("empty names/values are dropped so no unusable placeholder is advertised")
    func dropsEmpties() {
        let literals = AppleScriptLiterals(["content": "", "": "x", "ok": "y"])
        #expect(literals.names == ["ok"])
        #expect(!literals.isEmpty)
        #expect(AppleScriptLiterals().isEmpty)
    }
}

// MARK: - Tool dispatch: literal merge (content + contents)

@Suite("AppleScriptToolDispatch.literals")
struct AppleScriptToolDispatchLiteralsTests {
    @Test("a single `content` string becomes the {{content}} literal")
    func singleContent() {
        let lits = AppleScriptToolDispatch.literals(from: ["content": "hello world"])
        #expect(lits.names == ["content"])
        #expect(lits.value(for: "content") == "hello world")
    }

    @Test("a `contents` map becomes one literal per named entry")
    func contentsMap() {
        let lits = AppleScriptToolDispatch.literals(
            from: ["contents": ["subject": "Q3 Report", "body": "the body"]]
        )
        #expect(lits.names == ["body", "subject"])
        #expect(lits.value(for: "subject") == "Q3 Report")
        #expect(lits.value(for: "body") == "the body")
    }

    @Test("`contents` wins over `content` on the reserved `content` key")
    func contentsWinsOnContentKey() {
        let lits = AppleScriptToolDispatch.literals(
            from: [
                "content": "from-string",
                "contents": ["content": "from-map", "extra": "E"],
            ]
        )
        #expect(lits.value(for: "content") == "from-map")
        #expect(lits.value(for: "extra") == "E")
    }

    @Test("`content` fills in when `contents` didn't define it")
    func contentFillsWhenAbsentFromMap() {
        let lits = AppleScriptToolDispatch.literals(
            from: ["content": "single", "contents": ["body": "B"]]
        )
        #expect(lits.value(for: "content") == "single")
        #expect(lits.value(for: "body") == "B")
    }

    @Test("blank values and empty names are skipped")
    func skipsBlankAndEmptyNames() {
        let lits = AppleScriptToolDispatch.literals(
            from: ["contents": ["a": "   ", "b": "x", "": "y"]]
        )
        #expect(lits.names == ["b"])
    }

    @Test("no literal args yields an empty store")
    func emptyWhenNoArgs() {
        #expect(AppleScriptToolDispatch.literals(from: ["task": "do it"]).isEmpty)
        #expect(AppleScriptToolDispatch.literals(from: ["content": "   "]).isEmpty)
    }

    // A verbatim value that LOOKS like JSON can be re-parsed into a native
    // object / scalar by an upstream normalization pass; `literals(from:)` must
    // recover its string form rather than silently drop the content.
    @Test("a JSON-object-looking literal value survives as a re-serialized string")
    func jsonObjectValueSurvives() {
        let lits = AppleScriptToolDispatch.literals(from: ["contents": ["j": ["a": 1]]])
        #expect(lits.value(for: "j") == #"{"a":1}"#)
    }

    @Test("numeric and boolean literal values survive as their text form")
    func scalarValuesSurvive() {
        #expect(
            AppleScriptToolDispatch.literals(from: ["contents": ["n": 42]]).value(for: "n") == "42"
        )
        #expect(
            AppleScriptToolDispatch.literals(from: ["contents": ["flag": true]]).value(for: "flag")
                == "true"
        )
    }
}

// MARK: - Effect classifier

@Suite("AppleScriptEffectClassifier")
struct AppleScriptEffectClassifierTests {
    @Test("pure reads (incl. local var assignment from a read) classify as .read")
    func reads() {
        #expect(AppleScriptEffectClassifier.classify("return 1") == .read)
        #expect(AppleScriptEffectClassifier.classify("get name of current track") == .read)
        #expect(AppleScriptEffectClassifier.classify("count windows") == .read)
        // `set <var> to <read>` is a LOCAL assignment — still read-only.
        #expect(
            AppleScriptEffectClassifier.classify("set t to name of current track\nreturn t") == .read
        )
    }

    @Test("state mutations classify as .edit")
    func edits() {
        #expect(AppleScriptEffectClassifier.classify("set volume output volume 50") == .edit)
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Finder\" to make new folder"
            ) == .edit
        )
        // `set <property> of <thing> to …` is an app-state write.
        #expect(AppleScriptEffectClassifier.classify("set name of window 1 to \"x\"") == .edit)
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"System Events\" to keystroke \"a\""
            ) == .edit
        )
        // A `{{content}}` placeholder classifies on the STRUCTURE, not the
        // (hidden) content — so the loop can classify before substituting and
        // user text can't escalate the effect.
        #expect(
            AppleScriptEffectClassifier.classify("set body of note \"X\" to {{content}}") == .edit
        )
    }

    @Test("destructive / boundary commits classify as .consequential")
    func consequential() {
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Finder\" to delete folder \"x\""
            ) == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Mail\" to send outgoing message"
            ) == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify("tell application \"Music\" to quit") == .consequential
        )
    }
}

// MARK: - Loop (injected seams)

@Suite("AppleScriptLoop gate + termination")
struct AppleScriptLoopTests {
    private static let validArgs = #"{"script":"do something"}"#
    private static let invalidArgs = "{}"

    private func validCall(_ id: String = "c") -> ModelActionCall {
        ModelActionCall(id: id, arguments: Self.validArgs)
    }

    private func successResult(_ output: String? = "ok") -> AppleScriptExecutionResult {
        AppleScriptExecutionResult(status: .success, output: output, errorNumber: nil, errorMessage: nil)
    }

    @Test("confirm-each: approval runs the script and the no-call turn completes")
    func confirmEachApprove() async {
        let feed = SubagentFeed(toolCallId: "t-approve", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("done-output"))
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([validCall(), nil])

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.outcome.isSuccess)
        #expect(result.scriptsExecuted == 1)
        #expect(result.lastOutput == "done-output")
        #expect(await exec.count == 1)
        #expect(await confirm.count == 1)
        #expect(feed.currentEvents().contains { $0.kind == .verify && $0.success == true })
    }

    @Test("confirm-each: denial skips execution and feeds the refusal back")
    func confirmEachDeny() async {
        let feed = SubagentFeed(toolCallId: "t-deny", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: false)
        let seq = ScriptSequencer([validCall(), nil])

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 0)
        #expect(await exec.count == 0)
        #expect(await confirm.count == 1)
        #expect(feed.currentEvents().contains { $0.kind == .denied })
    }

    @Test("auto-run-with-warning never asks to confirm and emits a warning event")
    func autoRunWithWarning() async {
        let feed = SubagentFeed(toolCallId: "t-auto", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([validCall(), nil])

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        #expect(await exec.count == 1)
        #expect(await confirm.count == 0)
        #expect(
            feed.currentEvents().contains { $0.kind == .error && $0.title.contains("Auto-running") }
        )
    }

    @Test("an invalid call is re-asked, then the model completes")
    func invalidThenComplete() async {
        let feed = SubagentFeed(toolCallId: "t-invalid", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([ModelActionCall(id: "bad", arguments: Self.invalidArgs), nil])

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.outcome.isSuccess)
        #expect(result.scriptsExecuted == 0)
        #expect(await exec.count == 0)
        #expect(feed.currentEvents().contains { $0.kind == .retry })
    }

    @Test("the step cap terminates a model that keeps proposing scripts")
    func stepCapReached() async {
        let feed = SubagentFeed(toolCallId: "t-cap", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        // Always proposes a valid script (never signals completion).
        let seq = ScriptSequencer(repeating: validCall())

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in await confirm.confirm() },
            limits: RunLimits(maxSteps: 1),
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        if case .stepCapReached = result.outcome {
            // expected
        } else {
            Issue.record("expected .stepCapReached, got \(result.outcome)")
        }
        #expect(result.scriptsExecuted == 1)
    }

    /// Build a `run_applescript` call carrying `script` (JSON-encoded so quotes
    /// and newlines are safe).
    private func call(_ script: String, id: String = "c") -> ModelActionCall {
        let data = try! JSONSerialization.data(withJSONObject: ["script": script])
        return ModelActionCall(id: id, arguments: String(data: data, encoding: .utf8)!)
    }

    @Test("a successful run records the returned value + a per-step transcript")
    func transcriptOnSuccess() async {
        let feed = SubagentFeed(toolCallId: "t-ts", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("Song X"))
        let seq = ScriptSequencer([call("get name of current track"), nil])

        let result = await AppleScriptLoop.run(
            task: "advance the slideshow",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.outcome.isSuccess)
        #expect(result.scriptsExecuted == 1)
        #expect(result.succeeded == 1)
        #expect(result.failed == 0)
        #expect(result.lastOutput == "Song X")
        #expect(result.steps.count == 1)
        #expect(result.steps.first?.status == "success")
        #expect(result.steps.first?.output == "Song X")
        #expect(result.steps.first?.intent == "read")
    }

    @Test("a runtime error is captured in the transcript with its message + number")
    func transcriptOnRuntimeError() async {
        let feed = SubagentFeed(toolCallId: "t-err", kindId: "applescript", title: "task")
        let exec = ExecRecorder(
            result: AppleScriptExecutionResult(
                status: .runtimeError,
                output: nil,
                errorNumber: -1728,
                errorMessage: "Can’t get name"
            )
        )
        let seq = ScriptSequencer([call("get name of window 1"), nil])

        let result = await AppleScriptLoop.run(
            task: "advance the slideshow",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        #expect(result.succeeded == 0)
        #expect(result.failed == 1)
        #expect(result.steps.first?.status == "runtime_error")
        #expect(result.steps.first?.errorNumber == -1728)
        #expect(result.steps.first?.error == "Can’t get name")
    }

    @Test("query mode runs the verification read-back to capture a value")
    func verificationReadBack() async {
        let feed = SubagentFeed(toolCallId: "t-verify", kindId: "applescript", title: "q")
        let exec = ScriptedExec(results: [successResult(nil), successResult("60")])
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([
            call("get volume"), nil, call("get volume settings"), nil,
        ])

        let result = await AppleScriptLoop.run(
            task: "what is the volume",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .query,
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.lastOutput == "60")
        #expect(result.scriptsExecuted == 2)
        #expect(result.succeeded == 2)
        // Query mode never prompts for confirmation (reads auto-run).
        #expect(await confirm.count == 0)
        #expect(feed.currentEvents().contains { $0.kind == .retry && $0.title.contains("Verif") })
    }

    @Test("query mode blocks a state-changing script and never executes it")
    func queryModeBlocksWrite() async {
        let feed = SubagentFeed(toolCallId: "t-block", kindId: "applescript", title: "q")
        let exec = ExecRecorder(result: successResult("should not run"))
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([call("set volume output volume 50"), nil])

        let result = await AppleScriptLoop.run(
            task: "what is the volume",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .query,
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 0)
        #expect(await exec.count == 0)
        #expect(await confirm.count == 0)
        #expect(result.steps.contains { $0.status == "blocked" })
        #expect(feed.currentEvents().contains { $0.kind == .error && $0.title.contains("Blocked") })
    }

    @Test("a {{content}} placeholder is expanded to the exact escaped text before execution")
    func literalPlaceholderExpanded() async {
        let feed = SubagentFeed(toolCallId: "t-lit", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("ok"))
        // Verbatim content a small model would struggle to reproduce/escape: an
        // em dash, an apostrophe, a double quote, and a newline.
        let content = "Line one — an apostrophe's curl and a \"quote\".\nLine two."
        let seq = ScriptSequencer([
            call("tell application \"Notes\" to set body of note \"X\" to {{content}}"),
            nil,
        ])

        let result = await AppleScriptLoop.run(
            task: "set the note body to the provided content",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            literals: AppleScriptLiterals(["content": content]),
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        let ran = await exec.scripts.first ?? ""
        // The token is gone; the exact text is present with quotes/newlines escaped.
        #expect(!ran.contains("{{content}}"))
        #expect(ran.contains("Line one — an apostrophe's curl"))
        #expect(ran.contains("a \\\"quote\\\"."))
        #expect(ran.contains("\\nLine two."))
    }

    @Test("referencing an unknown placeholder is re-asked, not executed")
    func unknownPlaceholderReAsk() async {
        let feed = SubagentFeed(toolCallId: "t-unk", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        // References {{body}} but only {{content}} was provided → re-ask, then finish.
        let seq = ScriptSequencer([
            call("set body of note \"X\" to {{body}}"),
            nil,
        ])

        let result = await AppleScriptLoop.run(
            task: "set the note body",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            literals: AppleScriptLiterals(["content": "hi"]),
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 0)
        #expect(await exec.count == 0)
        #expect(result.steps.contains { $0.status == "invalid" })
        #expect(
            feed.currentEvents().contains {
                $0.kind == .retry && $0.title.contains("Unknown placeholder")
            }
        )
    }

    @Test("multiple named placeholders ({{subject}} + {{body}}) each expand before execution")
    func multiLiteralPlaceholdersExpanded() async {
        let feed = SubagentFeed(toolCallId: "t-multi", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("ok"))
        let subject = "Q3 Report — final"
        let body = "Hello,\nThe \"numbers\" are in.\nThanks."
        let seq = ScriptSequencer([
            call(
                "tell application \"Mail\"\nset theSubject to {{subject}}\nset theBody to {{body}}\nend tell"
            ),
            nil,
        ])

        let result = await AppleScriptLoop.run(
            task: "draft the mail with the provided subject and body",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            literals: AppleScriptLiterals(["subject": subject, "body": body]),
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        let ran = await exec.scripts.first ?? ""
        // Both tokens are gone; each exact text is present, correctly escaped.
        #expect(!ran.contains("{{subject}}"))
        #expect(!ran.contains("{{body}}"))
        #expect(ran.contains("Q3 Report — final"))
        #expect(ran.contains("The \\\"numbers\\\" are in."))
        #expect(ran.contains("\\nThanks."))
    }

    @Test("an already-tripped interrupt ends the run before any work")
    func interruptedImmediately() async {
        let feed = SubagentFeed(toolCallId: "t-int", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let token = InterruptToken()
        let callId = "call-int-\(UUID().uuidString)"
        SubagentInterruptCenter.shared.register(token, for: callId)
        defer { SubagentInterruptCenter.shared.unregister(callId) }
        _ = SubagentInterruptCenter.shared.interrupt(callId)
        let seq = ScriptSequencer(repeating: validCall())

        let result = await AppleScriptLoop.run(
            task: "do it",
            modelId: "applescript-test",
            feed: feed,
            interrupt: token,
            executionMode: .autoRunWithWarning,
            confirm: { _ in true },
            sessionId: "s",
            execute: { await exec.run($0) },
            nextScript: { _ in await seq.next() }
        )

        if case .interrupted = result.outcome {
            // expected
        } else {
            Issue.record("expected .interrupted, got \(result.outcome)")
        }
        #expect(await exec.count == 0)
    }
}

// MARK: - mapOutcome (rich payload + honest status)

@Suite("AppleScriptKind.mapOutcome")
struct AppleScriptMapOutcomeTests {
    private func step(
        _ n: Int,
        _ status: String,
        output: String? = nil,
        error: String? = nil,
        errorNumber: Int? = nil
    ) -> AppleScriptStepRecord {
        AppleScriptStepRecord(
            n: n,
            intent: "action",
            status: status,
            output: output,
            error: error,
            errorNumber: errorNumber,
            scriptPreview: "script \(n)"
        )
    }

    @Test("a failed run that executed scripts returns the transcript instead of throwing")
    func failedWithScriptsReturnsTranscript() throws {
        let result = AppleScriptRunResult(
            outcome: .failed(reason: "boom"),
            scriptsExecuted: 2,
            succeeded: 1,
            failed: 1,
            modelTokens: 0,
            lastOutput: "42",
            steps: [
                step(1, "success", output: "42"),
                step(2, "runtime_error", error: "no", errorNumber: -1),
            ]
        )
        let mapped = try AppleScriptKind.mapOutcome(result, model: "m", mode: .automate)
        // Some succeeded, some failed → honest `partial`, with the value + transcript.
        #expect(mapped.payload["status"] as? String == "partial")
        #expect(mapped.payload["values"] as? String == "42")
        #expect(mapped.payload["scripts_run"] as? Int == 2)
        #expect((mapped.payload["steps"] as? [[String: Any]])?.count == 2)
        #expect((mapped.payload["errors"] as? [[String: Any]])?.count == 1)
    }

    @Test("a failed run that executed NOTHING throws executionFailed")
    func failedWithNoScriptsThrows() {
        let result = AppleScriptRunResult(
            outcome: .failed(reason: "no valid script"),
            scriptsExecuted: 0,
            modelTokens: 0,
            lastOutput: nil
        )
        #expect(throws: SubagentError.self) {
            _ = try AppleScriptKind.mapOutcome(result, model: "m", mode: .automate)
        }
    }

    @Test("a clean done run reports succeeded + the returned values + the mode")
    func doneReportsValues() throws {
        let result = AppleScriptRunResult(
            outcome: .done(summary: "Did it."),
            scriptsExecuted: 1,
            succeeded: 1,
            failed: 0,
            modelTokens: 0,
            lastOutput: "100",
            steps: [step(1, "success", output: "100")]
        )
        let mapped = try AppleScriptKind.mapOutcome(result, model: "m", mode: .query)
        #expect(mapped.payload["status"] as? String == "succeeded")
        #expect(mapped.payload["mode"] as? String == "query")
        #expect(mapped.payload["values"] as? String == "100")
        #expect(mapped.payload["failed"] as? Int == 0)
    }
}

// MARK: - Capability gating + execution mode

@Suite("AppleScript capability gating")
struct AppleScriptCapabilityGatingTests {
    private func snapshot(agentId: UUID, appleScript: Bool) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false,
            appleScriptEnabled: appleScript
        )
    }

    @Test("a custom agent gets `applescript` only when enabled AND a model is installed")
    func customAgentGatedOnEnableAndModel() {
        let agentId = UUID()
        let config = SubagentConfiguration()

        let enabledWithModel = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: agentId,
            snapshot: snapshot(agentId: agentId, appleScript: true),
            config: config,
            hasReadyImageModel: false,
            hasReadyAppleScriptModel: true
        )
        #expect(enabledWithModel.contains(AppleScriptTool.toolName))

        let enabledNoModel = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: agentId,
            snapshot: snapshot(agentId: agentId, appleScript: true),
            config: config,
            hasReadyImageModel: false,
            hasReadyAppleScriptModel: false
        )
        #expect(!enabledNoModel.contains(AppleScriptTool.toolName))

        let disabledWithModel = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: agentId,
            snapshot: snapshot(agentId: agentId, appleScript: false),
            config: config,
            hasReadyImageModel: false,
            hasReadyAppleScriptModel: true
        )
        #expect(!disabledWithModel.contains(AppleScriptTool.toolName))
    }

    @Test("the Default agent is gated by the global switch, not the snapshot flag")
    func defaultAgentUsesGlobalSwitch() {
        let config = SubagentConfiguration(appleScriptDelegationEnabled: true)
        let names = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: Agent.defaultId,
            snapshot: snapshot(agentId: Agent.defaultId, appleScript: false),
            config: config,
            hasReadyImageModel: false,
            hasReadyAppleScriptModel: true
        )
        #expect(names.contains(AppleScriptTool.toolName))
    }

    @Test("the applescript capability gates both sibling tools (applescript + mac_query)")
    func capabilityMetadata() {
        let cap = SubagentCapabilityRegistry.appleScript
        #expect(cap.id == "applescript")
        #expect(cap.toolNames == [AppleScriptTool.toolName, MacQueryTool.toolName])
        #expect(cap.primaryToolName == AppleScriptTool.toolName)
        #expect(cap.perAgentFlag == .appleScript)
        #expect(cap.supportsModelOverride == false)
        #expect(SubagentCapabilityRegistry.delegationFamily.contains { $0.id == "applescript" })
        // Both tools gate together: enabling AppleScript exposes both.
        let names = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: Agent.defaultId,
            snapshot: snapshot(agentId: Agent.defaultId, appleScript: false),
            config: SubagentConfiguration(appleScriptDelegationEnabled: true),
            hasReadyImageModel: false,
            hasReadyAppleScriptModel: true
        )
        #expect(names.contains(AppleScriptTool.toolName))
        #expect(names.contains(MacQueryTool.toolName))
    }

    @Test("execution mode decodes leniently and defaults to confirm-each")
    func executionModeDecode() {
        #expect(AppleScriptExecutionMode.default == .confirmEach)
        #expect(AppleScriptExecutionMode(storedValue: "autoRunWithWarning") == .autoRunWithWarning)
        #expect(AppleScriptExecutionMode(storedValue: "confirmEach") == .confirmEach)
        #expect(AppleScriptExecutionMode(storedValue: "garbage") == .confirmEach)
        #expect(AppleScriptExecutionMode(storedValue: nil) == .confirmEach)
    }
}

// MARK: - Test doubles

/// Hands the loop a scripted sequence of model calls. `nil` signals the model
/// finished (no tool call), the loop's natural completion path. After the array
/// is exhausted it keeps returning `nil`.
private actor ScriptSequencer {
    private let calls: [ModelActionCall?]
    private let repeated: ModelActionCall?
    private var index = 0

    init(_ calls: [ModelActionCall?]) {
        self.calls = calls
        self.repeated = nil
    }

    /// Always returns the same call (never completes) — for step-cap / interrupt.
    init(repeating call: ModelActionCall) {
        self.calls = []
        self.repeated = call
    }

    func next() -> ModelActionCall? {
        if let repeated { return repeated }
        guard index < calls.count else { return nil }
        defer { index += 1 }
        return calls[index]
    }
}

/// Records the scripts the loop asked to execute and returns a canned result.
private actor ExecRecorder {
    private(set) var count = 0
    private(set) var scripts: [String] = []
    private let result: AppleScriptExecutionResult

    init(result: AppleScriptExecutionResult) { self.result = result }

    func run(_ script: String) -> AppleScriptExecutionResult {
        count += 1
        scripts.append(script)
        return result
    }
}

/// Returns a scripted SEQUENCE of execution results (one per call), so a test
/// can model e.g. a first read with no value then a verification read that
/// finally returns one. After the sequence is exhausted it repeats the last.
private actor ScriptedExec {
    private let results: [AppleScriptExecutionResult]
    private(set) var count = 0

    init(results: [AppleScriptExecutionResult]) { self.results = results }

    func run(_ script: String) -> AppleScriptExecutionResult {
        defer { count += 1 }
        if count < results.count { return results[count] }
        return results.last
            ?? AppleScriptExecutionResult(
                status: .success,
                output: nil,
                errorNumber: nil,
                errorMessage: nil
            )
    }
}

/// Counts confirm prompts and answers with a fixed decision.
private actor ConfirmCounter {
    private(set) var count = 0
    private let approve: Bool

    init(approve: Bool) { self.approve = approve }

    func confirm() -> Bool {
        count += 1
        return approve
    }
}
