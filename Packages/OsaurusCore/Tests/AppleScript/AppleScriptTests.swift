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

    @Test("the language discriminator decodes leniently and defaults to AppleScript")
    func languageDecodes() {
        // Absent → AppleScript.
        #expect(
            AppleScriptAction.decode(argumentsJSON: #"{"script":"return 1"}"#)
                == .script("return 1", .appleScript)
        )
        // Explicit JXA spellings.
        #expect(
            AppleScriptAction.decode(
                argumentsJSON: #"{"script":"6*7","language":"javascript"}"#
            ) == .script("6*7", .javascript)
        )
        #expect(AppleScriptLanguage(callValue: "jxa") == .javascript)
        #expect(AppleScriptLanguage(callValue: "JS") == .javascript)
        // Unrecognized → the AppleScript default, not a rejection.
        #expect(AppleScriptLanguage(callValue: "garbage") == .appleScript)
        #expect(AppleScriptLanguage(callValue: nil) == .appleScript)
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

    @Test("a user record surfaces its REAL keys as key: value pairs")
    func userRecordOutput() async {
        // AE regroups record fields: RESERVED labels (name, locked) become
        // coded keyword fields ahead of the user-label block (battery), so
        // the rendered order is grouped, not source order.
        let result = await AppleScriptExecutor.run(
            source: "return {name:\"Front Door\", battery:87, locked:true}",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "name: Front Door, locked: true, battery: 87")
    }

    @Test("a nested user record renders recursively with its keys")
    func nestedRecordOutput() async {
        let result = await AppleScriptExecutor.run(
            source: "return {device:{name:\"Hub\", port:8080}, ok:true}",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "device: {name: Hub, port: 8080}, ok: true")
    }

    @Test("a JXA script runs via the JavaScript OSA component and returns its value")
    func jxaSuccess() async {
        let result = await AppleScriptExecutor.run(
            source: "(function () { return 6 * 7; })()",
            language: .javascript,
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "42")
    }

    @Test("a JXA syntax error maps to compileError")
    func jxaCompileError() async {
        let result = await AppleScriptExecutor.run(
            source: "function ( { nope",
            language: .javascript,
            timeout: 15
        )
        #expect(result.status == .compileError)
        #expect(result.errorMessage != nil)
    }

    @Test("a JXA thrown error maps to runtimeError with the real message")
    func jxaRuntimeError() async {
        let result = await AppleScriptExecutor.run(
            source: "throw new Error(\"boom\")",
            language: .javascript,
            timeout: 15
        )
        #expect(result.status == .runtimeError)
        #expect(result.errorMessage?.contains("boom") == true)
    }

    @Test("compileCheck: a compiling script returns nil (no objection)")
    func compileCheckPasses() async {
        let result = await AppleScriptExecutor.compileCheck(
            source: "return 1 + 1",
            timeout: 15
        )
        #expect(result == nil)
    }

    @Test("compileCheck: a syntax error returns the real compileError, without executing")
    func compileCheckCatchesSyntaxError() async {
        let result = await AppleScriptExecutor.compileCheck(
            source: "return \"unterminated",
            timeout: 15
        )
        #expect(result?.status == .compileError)
        #expect(result?.errorMessage?.isEmpty == false)
    }

    @Test("compileCheck: a runtime error is NOT a compile objection (returns nil)")
    func compileCheckIgnoresRuntimeError() async {
        // Compiles fine; would only fail when run. The dry run must not
        // block it — runtime truth belongs to the executor.
        let result = await AppleScriptExecutor.compileCheck(
            source: "error \"boom\" number 42",
            timeout: 15
        )
        #expect(result == nil)
    }

    @Test("compileCheck: JXA syntax errors are caught via the JavaScript component")
    func compileCheckJXA() async {
        let bad = await AppleScriptExecutor.compileCheck(
            source: "function ( { nope",
            language: .javascript,
            timeout: 15
        )
        #expect(bad?.status == .compileError)
        let good = await AppleScriptExecutor.compileCheck(
            source: "(function () { return 6 * 7; })()",
            language: .javascript,
            timeout: 15
        )
        #expect(good == nil)
    }

    // The heartbeat keeps the MAIN run loop turning while any script is in
    // flight — headless hosts otherwise never deliver AE replies (observed
    // live: a Finder probe "timed out" 15s+ on a granted machine, wedging
    // the eval suite's main actor afterwards). The refcount must return to
    // zero (timer removed) after every completion path, including a
    // watchdog-abandoned run, or the process would wake 4×/s forever.
    @Test("heartbeat: armed during a run, disarmed after it completes")
    func heartbeatLifecycleAroundRun() async {
        _ = await AppleScriptExecutor.run(source: "return 1", timeout: 15)
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == false)
    }

    @Test("heartbeat: a watchdog-abandoned run still disarms once the worker finishes")
    func heartbeatDisarmsAfterAbandonedRun() async {
        // 1-second busy script vs a 0.05s timeout: the caller resumes via
        // the watchdog (timedOut) while the worker is still running. The
        // heartbeat must stay armed for the in-flight worker, then clear.
        let result = await AppleScriptExecutor.run(
            source: "delay 1\nreturn 2",
            timeout: 0.05
        )
        #expect(result.status == .timedOut)
        // Worker still holds its heartbeat ref while `delay 1` runs.
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == true)
        // After the abandoned worker completes, the ref drains to zero.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == false)
    }

    @Test("heartbeat: compileCheck arms and disarms it too")
    func heartbeatLifecycleAroundCompileCheck() async {
        _ = await AppleScriptExecutor.compileCheck(source: "return 1 + 1", timeout: 15)
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == false)
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

    @Test("a read-only `do shell script` classifies as .read so mac_query can run it")
    func shellReadIsRead() {
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"pmset -g batt\"") == .read
        )
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"system_profiler SPHardwareDataType\"")
                == .read
        )
        // A pipe is common in reads and must not escalate on its own.
        #expect(
            AppleScriptEffectClassifier.classify(
                "do shell script \"system_profiler SPHardwareDataType | grep Memory\""
            ) == .read
        )
        #expect(AppleScriptEffectClassifier.classify("do shell script \"sw_vers\"") == .read)
    }

    @Test("a destructive / writing `do shell script` classifies as .consequential")
    func shellWriteIsConsequential() {
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"rm -rf /tmp/x\"") == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"sudo pmset -a hibernatemode 0\"")
                == .consequential
        )
        // Output redirection is a write even with an otherwise benign command.
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"echo hi > /tmp/x\"") == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"defaults write com.x k v\"")
                == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"killall Dock\"") == .consequential
        )
    }

    @Test("a `do shell script` never lowers a mutating AppleScript verb")
    func shellDoesNotLowerVerb() {
        // The AppleScript `delete` is consequential; a benign shell read in the
        // same script can't demote it (max wins).
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Finder\" to delete folder \"x\"\ndo shell script \"sw_vers\""
            ) == .consequential
        )
    }

    @Test("running a user Shortcut classifies as .consequential (opaque effect)")
    func runShortcutIsConsequential() {
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Shortcuts Events\" to run shortcut \"Morning Routine\""
            ) == .consequential
        )
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Shortcuts Events\" to run shortcut \"Log Water\" with input \"12\""
            ) == .consequential
        )
        // The shell route escalates the same way.
        #expect(
            AppleScriptEffectClassifier.classify(
                "do shell script \"shortcuts run 'Morning Routine'\""
            ) == .consequential
        )
        // Listing shortcuts is a plain read — only RUNNING one is a commit.
        #expect(
            AppleScriptEffectClassifier.classify(
                "tell application \"Shortcuts Events\" to get name of every shortcut"
            ) == .read
        )
        #expect(
            AppleScriptEffectClassifier.classify("do shell script \"shortcuts list\"") == .read
        )
    }

    @Test("a JXA script floors at .edit and still escalates on destructive names")
    func jxaFloorsAtEdit() {
        // A read-looking JXA script is statically opaque → never `.read`.
        #expect(
            AppleScriptEffectClassifier.classify(
                "Application('Safari').windows[0].currentTab.url()",
                language: .javascript
            ) == .edit
        )
        // Destructive tokens still escalate.
        #expect(
            AppleScriptEffectClassifier.classify(
                "Application('Finder').delete(item)",
                language: .javascript
            ) == .consequential
        )
        // The AppleScript path is unchanged by the overload.
        #expect(
            AppleScriptEffectClassifier.classify(
                "return 1 + 1",
                language: .appleScript
            ) == .read
        )
    }
}

// MARK: - Target-app extraction (scoped approve)

@Suite("AppleScriptLoop.targetAppName")
struct AppleScriptTargetAppNameTests {
    @Test("extracts the app from `tell application \"Name\"`")
    func extractsTellApplication() {
        #expect(
            AppleScriptLoop.targetAppName("tell application \"Safari\" to activate") == "Safari"
        )
        #expect(
            AppleScriptLoop.targetAppName(
                "tell application \"System Events\"\n  keystroke \"a\"\nend tell"
            ) == "System Events"
        )
    }

    @Test("matches case-insensitively and the short `tell app` form")
    func caseInsensitiveAndShortForm() {
        #expect(AppleScriptLoop.targetAppName("TELL APPLICATION \"Notes\"") == "Notes")
        #expect(AppleScriptLoop.targetAppName("tell app \"Music\" to play") == "Music")
    }

    @Test("returns the FIRST targeted app when several are addressed")
    func firstAppWins() {
        #expect(
            AppleScriptLoop.targetAppName(
                "tell application \"Finder\"\nend tell\ntell application \"Safari\"\nend tell"
            ) == "Finder"
        )
    }

    @Test("returns nil for a script that targets no named app")
    func nilWhenNoApp() {
        #expect(AppleScriptLoop.targetAppName("set volume output volume 40") == nil)
        #expect(AppleScriptLoop.targetAppName("return 1 + 1") == nil)
    }

    @Test("extracts the app from the JXA Application('Name') form")
    func extractsJXAApplication() {
        #expect(
            AppleScriptLoop.targetAppName("Application('Safari').windows[0].name()") == "Safari"
        )
        #expect(
            AppleScriptLoop.targetAppName("Application(\"Notes\").notes.length") == "Notes"
        )
    }
}

// MARK: - Loop (injected seams)

@Suite("AppleScriptLoop gate + termination")
struct AppleScriptLoopTests {
    // A MUTATING script so the confirm / deny / auto-run-with-warning gate
    // tests below exercise the gate: a pure read now auto-runs in automate mode
    // (see `automateReadAutoRuns`), so the shared "valid" script must be an edit
    // for the confirmation paths to fire.
    private static let validArgs = #"{"script":"set volume output volume 30"}"#
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 0)
        #expect(await exec.count == 0)
        #expect(await confirm.count == 1)
        #expect(feed.currentEvents().contains { $0.kind == .denied })
    }

    @Test("automate confirm-each auto-runs a classified READ without prompting")
    func automateReadAutoRuns() async {
        let feed = SubagentFeed(toolCallId: "t-read", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("Song X"))
        let confirm = ConfirmCounter(approve: true)
        // A pure read (get + return) in a state-changing `applescript` run.
        let seq = ScriptSequencer([call("get name of current track"), nil])

        let result = await AppleScriptLoop.run(
            task: "what track is playing",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .automate,
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        #expect(result.lastOutput == "Song X")
        // The read ran without a confirmation prompt.
        #expect(await confirm.count == 0)
    }

    @Test("automate confirm-each still confirms a mutating (edit) script")
    func automateEditConfirms() async {
        let feed = SubagentFeed(toolCallId: "t-edit", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult(nil))
        let confirm = ConfirmCounter(approve: true)
        let seq = ScriptSequencer([call("set volume output volume 40"), nil])

        let result = await AppleScriptLoop.run(
            task: "set the volume to 40",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .automate,
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        // A mutation still pauses for approval.
        #expect(await confirm.count == 1)
    }

    private static let uiScriptingScript =
        #"tell application "System Events" to tell process "Safari" to click menu item "Save" of menu "File" of menu bar 1"#

    @Test("accessibility preflight: a UI script is stopped before the gate, recovery fired once")
    func accessibilityPreflightBlocks() async {
        let feed = SubagentFeed(toolCallId: "t-ax", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        let prompts = SyncCounter()
        let seq = ScriptSequencer([call(Self.uiScriptingScript), nil])

        let result = await AppleScriptLoop.run(
            task: "save via the menu",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .automate,
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() },
            accessibilityGranted: { false },
            requestAccessibility: { prompts.increment() }
        )

        // Never executed and never surfaced for approval: the user must not be
        // asked to approve a script that cannot run.
        #expect(await exec.count == 0)
        #expect(await confirm.count == 0)
        // The OS grant dialog (first-class recovery) fired exactly once.
        #expect(prompts.value == 1)
        #expect(result.steps.contains { $0.status == "permission_required" })
        #expect(
            feed.currentEvents().contains { $0.title == "Accessibility permission needed" }
        )
    }

    @Test("repeated accessibility blocks terminate naming the missing permission")
    func accessibilityPreflightTerminates() async {
        let feed = SubagentFeed(toolCallId: "t-ax-term", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let prompts = SyncCounter()
        let seq = ScriptSequencer(repeating: call(Self.uiScriptingScript))

        let result = await AppleScriptLoop.run(
            task: "save via the menu",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in true },
            sessionId: "s",
            mode: .automate,
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() },
            accessibilityGranted: { false },
            requestAccessibility: { prompts.increment() }
        )

        guard case .failed(let reason) = result.outcome else {
            Issue.record("expected a failed outcome, got \(result.outcome)")
            return
        }
        #expect(reason.contains("Accessibility"))
        #expect(await exec.count == 0)
        // Still only one grant dialog across the repeats.
        #expect(prompts.value == 1)
    }

    @Test("accessibility granted: the UI script proceeds to the normal confirm gate")
    func accessibilityGrantedProceeds() async {
        let feed = SubagentFeed(toolCallId: "t-ax-ok", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        let prompts = SyncCounter()
        let seq = ScriptSequencer([call(Self.uiScriptingScript), nil])

        let result = await AppleScriptLoop.run(
            task: "save via the menu",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .automate,
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() },
            accessibilityGranted: { true },
            requestAccessibility: { prompts.increment() }
        )

        #expect(result.scriptsExecuted == 1)
        // A UI-scripting mutation still pauses at the normal gate.
        #expect(await confirm.count == 1)
        #expect(prompts.value == 0)
    }

    @Test("a JXA call gates as an edit (confirms) and the executor receives the language")
    func jxaCallGatesAndRoutesLanguage() async {
        let feed = SubagentFeed(toolCallId: "t-jxa", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult("Safari"))
        let confirm = ConfirmCounter(approve: true)
        let languages = LanguageLog()
        // A read-LOOKING JXA script: were it AppleScript it would auto-run as a
        // read; as JXA it must floor at .edit and pause for approval.
        let args = try! JSONSerialization.data(
            withJSONObject: [
                "script": "Application('Safari').windows[0].name()",
                "language": "javascript",
            ]
        )
        let call = ModelActionCall(id: "c", arguments: String(data: args, encoding: .utf8)!)
        let seq = ScriptSequencer([call, nil])

        let result = await AppleScriptLoop.run(
            task: "front window name",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            mode: .automate,
            execute: { script, language in
                languages.append(language)
                return await exec.run(script)
            },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        // JXA never auto-runs as a read — the gate paused for approval.
        #expect(await confirm.count == 1)
        #expect(languages.all() == [.javascript])
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
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        #expect(await exec.count == 1)
        #expect(await confirm.count == 0)
        #expect(
            feed.currentEvents().contains { $0.kind == .error && $0.title.contains("Auto-running") }
        )
    }

    @Test("a consequential script still confirms under auto-run-with-warning")
    func consequentialAlwaysConfirms() async {
        let feed = SubagentFeed(toolCallId: "t-conseq", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        // `delete` classifies .consequential — auto-run-with-warning must NOT
        // run it on a warning banner alone; the gate pauses for approval.
        let call = ModelActionCall(
            id: "c",
            arguments:
                #"{"script":"tell application \"Finder\" to delete folder \"x\""}"#
        )
        let seq = ScriptSequencer([call, nil])

        let result = await AppleScriptLoop.run(
            task: "delete the folder",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .autoRunWithWarning,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() }
        )

        #expect(result.scriptsExecuted == 1)
        #expect(await confirm.count == 1)
        #expect(
            !feed.currentEvents().contains { $0.kind == .error && $0.title.contains("Auto-running") }
        )
    }

    @Test("compile-before-confirm: a syntax error is fed back, the user is never asked")
    func compileFailureSkipsConfirm() async {
        let feed = SubagentFeed(toolCallId: "t-dryc", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let confirm = ConfirmCounter(approve: true)
        // First proposal "fails to compile" (per the injected checker), the
        // corrected second one compiles and is confirmed + executed.
        let badCall = ModelActionCall(
            id: "c1",
            arguments: #"{"script":"set volume output volume"}"#
        )
        let seq = ScriptSequencer([badCall, validCall("c2"), nil])
        let compileFailure = AppleScriptExecutionResult(
            status: .compileError,
            output: nil,
            errorNumber: -2741,
            errorMessage: "Expected expression but found end of script."
        )
        let checked = MutableTexts()

        let result = await AppleScriptLoop.run(
            task: "set the volume",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in await confirm.confirm() },
            sessionId: "s",
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() },
            compileCheck: { script, _ in
                checked.append(script)
                return script.hasSuffix("volume") ? compileFailure : nil
            }
        )

        #expect(result.outcome.isSuccess)
        // The broken script never reached the user or the executor.
        #expect(await confirm.count == 1)
        #expect(result.scriptsExecuted == 1)
        #expect(checked.all().count == 2)
        #expect(result.steps.contains { $0.status == "compile_error" })
        #expect(
            feed.currentEvents().contains {
                $0.kind == .retry && $0.title.contains("did not compile")
            }
        )
    }

    @Test("compile-before-confirm: repeated syntax failures terminate with the real reason")
    func compileFailureBudgetTerminates() async {
        let feed = SubagentFeed(toolCallId: "t-dryc2", kindId: "applescript", title: "task")
        let exec = ExecRecorder(result: successResult())
        let seq = ScriptSequencer(repeating: validCall())
        let compileFailure = AppleScriptExecutionResult(
            status: .compileError,
            output: nil,
            errorNumber: -2741,
            errorMessage: "Expected expression but found end of script."
        )

        let result = await AppleScriptLoop.run(
            task: "set the volume",
            modelId: "applescript-test",
            feed: feed,
            interrupt: InterruptToken(),
            executionMode: .confirmEach,
            confirm: { _ in true },
            sessionId: "s",
            execute: { script, _ in await exec.run(script) },
            nextScript: { _ in await seq.next() },
            compileCheck: { _, _ in compileFailure }
        )

        guard case .failed(let reason) = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        #expect(reason.contains("compile"))
        #expect(await exec.count == 0)
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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
            execute: { script, _ in await exec.run(script) },
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

    @Test("token/s + elapsed are reported when measured, never fabricated")
    func tokensPerSecondReported() throws {
        // A live-model run: tokens + model time measured → token/s present.
        let live = AppleScriptRunResult(
            outcome: .done(summary: "Done."),
            scriptsExecuted: 1,
            succeeded: 1,
            failed: 0,
            modelTokens: 300,
            elapsedSeconds: 12.5,
            modelSeconds: 10.0,
            lastOutput: nil,
            steps: [step(1, "success")]
        )
        let mapped = try AppleScriptKind.mapOutcome(live, model: "m", mode: .automate)
        #expect(mapped.payload["elapsed_seconds"] as? Double == 12.5)
        #expect(mapped.payload["model_tokens"] as? Int == 300)
        #expect(mapped.payload["tokens_per_second"] as? Double == 30.0)

        // A scripted/injected run (no tokens, no model time) → NO token/s key.
        let scripted = AppleScriptRunResult(
            outcome: .done(summary: "Done."),
            scriptsExecuted: 1,
            succeeded: 1,
            failed: 0,
            modelTokens: 0,
            elapsedSeconds: 0.4,
            modelSeconds: 0,
            lastOutput: nil,
            steps: [step(1, "success")]
        )
        let scriptedMapped = try AppleScriptKind.mapOutcome(scripted, model: "m", mode: .automate)
        #expect(scriptedMapped.payload["tokens_per_second"] == nil)
    }

    @Test("the engine's decode rate wins over counter division (tool-call turns count 0)")
    func engineDecodeRatePreferred() throws {
        // Tool-call-only turns report completion_tokens == 0 by contract, so
        // the counter division would understate; the engine's own per-step
        // decode hint is authoritative.
        let live = AppleScriptRunResult(
            outcome: .done(summary: "Done."),
            scriptsExecuted: 1,
            succeeded: 1,
            failed: 0,
            modelTokens: 300,
            elapsedSeconds: 12.5,
            modelSeconds: 10.0,
            engineDecodeTokensPerSecond: 8.4,
            lastOutput: nil,
            steps: [step(1, "success")]
        )
        #expect(live.tokensPerSecond == 8.4)
        let mapped = try AppleScriptKind.mapOutcome(live, model: "m", mode: .automate)
        #expect(mapped.payload["tokens_per_second"] as? Double == 8.4)
    }
}

// MARK: - Keep-warm residency coordinator

@Suite("AppleScriptWarmResidencyCoordinator")
struct AppleScriptWarmResidencyCoordinatorTests {
    private func lease(_ names: String...) -> ChatResidencyLease {
        ChatResidencyLease(unloadedModelNames: names)
    }

    /// A never-firing sleep so the deferred restore stays parked for the
    /// adopt/replace/flush tests (each cancels or supersedes it explicitly).
    private let parkedSleep: @Sendable (Int) async -> Void = { _ in
        try? await Task.sleep(nanoseconds: 100 * 1_000_000_000)
    }

    @Test("a follow-up run for the SAME model adopts the held lease and skips restore")
    func adoptsSameModel() async {
        let restored = RestoreCollector()
        let coord = AppleScriptWarmResidencyCoordinator(
            restore: { await restored.record($0) },
            sleep: parkedSleep
        )
        let held = lease("chat-A")
        await coord.endRun(lease: held, model: "AS-16B", keepWarmSeconds: 90)
        #expect(await coord.heldModelForTesting() == "AS-16B")

        let adopted = await coord.beginRun(model: "AS-16B")
        #expect(adopted == held)
        // Adopting reuses the unloaded lease — nothing is restored.
        #expect(await restored.all().isEmpty)
        #expect(await coord.heldModelForTesting() == nil)
    }

    @Test("a run for a DIFFERENT model restores the held lease and does not adopt")
    func replacesDifferentModel() async {
        let restored = RestoreCollector()
        let coord = AppleScriptWarmResidencyCoordinator(
            restore: { await restored.record($0) },
            sleep: parkedSleep
        )
        let held = lease("chat-A")
        await coord.endRun(lease: held, model: "AS-16B", keepWarmSeconds: 90)

        let adopted = await coord.beginRun(model: "AS-Other")
        #expect(adopted == nil)
        #expect(await restored.all() == [held])
    }

    @Test("flush restores the held lease immediately")
    func flushRestores() async {
        let restored = RestoreCollector()
        let coord = AppleScriptWarmResidencyCoordinator(
            restore: { await restored.record($0) },
            sleep: parkedSleep
        )
        await coord.endRun(lease: lease("chat-A"), model: "AS-16B", keepWarmSeconds: 90)
        await coord.flush()
        #expect(await restored.all() == [lease("chat-A")])
        #expect(await coord.heldModelForTesting() == nil)
    }

    @Test("keepWarmSeconds == 0 restores immediately (single-residency policy)")
    func zeroWindowRestoresNow() async {
        let restored = RestoreCollector()
        let coord = AppleScriptWarmResidencyCoordinator(
            restore: { await restored.record($0) },
            sleep: parkedSleep
        )
        await coord.endRun(lease: lease("chat-A"), model: "AS-16B", keepWarmSeconds: 0)
        #expect(await restored.all() == [lease("chat-A")])
        #expect(await coord.heldModelForTesting() == nil)
    }

    @Test("the deferred restore fires when the keep-warm window elapses")
    func deferredRestoreFires() async {
        let restored = RestoreCollector()
        // Immediate sleep → the window "elapses" at once, so the deferred
        // restore runs on the scheduled task.
        let coord = AppleScriptWarmResidencyCoordinator(
            restore: { await restored.record($0) },
            sleep: { _ in }
        )
        await coord.endRun(lease: lease("chat-A"), model: "AS-16B", keepWarmSeconds: 90)
        let fired = await restored.waitForOne()
        #expect(fired == lease("chat-A"))
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

// MARK: - Mock app world (evals executor double)

@Suite("MockAppleScriptWorld")
struct MockAppleScriptWorldTests {
    /// Distinctive fallback so "the mock didn't recognize it" is observable.
    private let fallback = AppleScriptExecutionResult(
        status: .success,
        output: "FALLBACK",
        errorNumber: nil,
        errorMessage: nil
    )

    @Test("Safari: open location records the URL; the read answers it verbatim")
    func safariRoundTrip() {
        var world = MockAppleScriptWorld()
        _ = world.handle(
            "tell application \"Safari\" to open location \"https://example.com/osaurus\"",
            fallback: fallback
        )
        #expect(world.snapshot()["safari:url"] == "https://example.com/osaurus")
        let read = world.handle(
            "tell application \"Safari\" to return URL of front document",
            fallback: fallback
        )
        #expect(read.output == "https://example.com/osaurus")
    }

    @Test("Safari: `set URL of front document to …` is the write form")
    func safariSetURLWrite() {
        var world = MockAppleScriptWorld(safariURL: "about:blank")
        _ = world.handle(
            "tell application \"Safari\" to set URL of front document to \"https://osaurus.ai\"",
            fallback: fallback
        )
        #expect(world.snapshot()["safari:url"] == "https://osaurus.ai")
    }

    @Test("Mail: `unread count of inbox` answers the seeded count")
    func mailUnreadRead() {
        var world = MockAppleScriptWorld(mailUnread: 6)
        let read = world.handle(
            "tell application \"Mail\" to return unread count of inbox",
            fallback: fallback
        )
        #expect(read.output == "6")
    }

    @Test("System Events: the frontmost READ answers; `set frontmost` does not")
    func frontmostReadNotWrite() {
        var world = MockAppleScriptWorld(frontmostApp: "Xcode")
        let read = world.handle(
            "tell application \"System Events\" to get name of first application process "
                + "whose frontmost is true",
            fallback: fallback
        )
        #expect(read.output == "Xcode")
        // `set frontmost to true` is an (unmodeled) write — the mock must NOT
        // answer it with the stored name; it falls back.
        let write = world.handle(
            "tell application \"System Events\" to tell process \"Notes\" to set frontmost to true",
            fallback: fallback
        )
        #expect(write.output == "FALLBACK")
    }

    @Test("Finder: exists reads false, create records, exists reads true")
    func folderCreateAndExists() {
        var world = MockAppleScriptWorld()
        let missing = world.handle(
            "tell application \"Finder\" to exists folder \"Osaurus Drops\" of desktop",
            fallback: fallback
        )
        #expect(missing.output == "false")
        _ = world.handle(
            "tell application \"Finder\" to make new folder at desktop "
                + "with properties {name:\"Osaurus Drops\"}",
            fallback: fallback
        )
        #expect(world.snapshot()["folder:Osaurus Drops"] == "true")
        let exists = world.handle(
            "tell application \"Finder\" to exists folder \"Osaurus Drops\" of desktop",
            fallback: fallback
        )
        #expect(exists.output == "true")
    }

    @Test("a create-if-missing compound script resolves as the CREATE")
    func createIfMissingCompound() {
        var world = MockAppleScriptWorld()
        let script = """
            tell application "Finder"
                if not (exists folder "Osaurus Drops" of desktop) then
                    make new folder at desktop with properties {name:"Osaurus Drops"}
                end if
            end tell
            """
        _ = world.handle(script, fallback: fallback)
        #expect(world.snapshot()["folder:Osaurus Drops"] == "true")
    }

    @Test("a MULTI-APP combined script records every recognized write")
    func multiAppCombinedScriptRecordsAllWrites() {
        // The live 16B emits exactly this hoisted-identifier, two-app shape —
        // both writes must land, not just the first parser's.
        var world = MockAppleScriptWorld()
        let script = """
            set targetURL to "https://example.com/osaurus"
            set folderName to "Osaurus Drops"

            tell application "Safari"
                activate
                if (count of windows) is 0 then
                    make new document with properties {URL:targetURL}
                else
                    set URL of current tab of front window to targetURL
                end if
            end tell

            tell application "Finder"
                if not (exists folder folderName of desktop) then
                    make new folder at desktop with properties {name:folderName}
                end if
            end tell
            """
        _ = world.handle(script, fallback: fallback)
        #expect(world.snapshot()["safari:url"] == "https://example.com/osaurus")
        #expect(world.snapshot()["folder:Osaurus Drops"] == "true")
    }

    @Test("`set URL of current tab of front window to <identifier>` resolves the binding")
    func safariCurrentTabIdentifierWrite() {
        var world = MockAppleScriptWorld(safariURL: "about:blank")
        let script = """
            set targetURL to "https://osaurus.ai/docs"
            tell application "Safari"
                set URL of current tab of front window to targetURL
            end tell
            """
        _ = world.handle(script, fallback: fallback)
        #expect(world.snapshot()["safari:url"] == "https://osaurus.ai/docs")
    }

    @Test("Mail: the manual `read status is false` filter answers the unread count")
    func mailManualUnreadFilterRead() {
        var world = MockAppleScriptWorld(mailUnread: 6)
        let read = world.handle(
            """
            tell application "Mail"
                set unreadCount to count of messages of inbox whose read status is false
            end tell
            return unreadCount
            """,
            fallback: fallback
        )
        #expect(read.output == "6")
    }

    @Test("an unrecognized script falls back — the mock never invents an answer")
    func unrecognizedFallsBack() {
        var world = MockAppleScriptWorld(mailUnread: 3)
        let result = world.handle(
            "tell application \"Music\" to playpause",
            fallback: fallback
        )
        #expect(result.output == "FALLBACK")
        // And the seeded state is untouched.
        #expect(world.snapshot()["mail:unread"] == "3")
    }
}

// MARK: - Accessibility preflight (System Events UI scripting)

@Suite("AppleScriptAccessibility")
struct AppleScriptAccessibilityTests {
    @Test("System Events UI scripting is detected; plain scripting is not")
    func requiresAccessibilityDetection() {
        // UI scripting forms → need the grant.
        #expect(
            AppleScriptAccessibility.requiresAccessibility(
                #"tell application "System Events" to keystroke "v" using command down"#
            )
        )
        #expect(
            AppleScriptAccessibility.requiresAccessibility(
                #"tell application "System Events" to tell process "Safari" to click menu item "Save" of menu "File" of menu bar 1"#
            )
        )
        #expect(
            AppleScriptAccessibility.requiresAccessibility(
                #"tell application "System Events" to get value of text field 1 of window 1 of process "Notes""#
            )
        )
        // Process-level reads via System Events work WITHOUT Accessibility.
        #expect(
            !AppleScriptAccessibility.requiresAccessibility(
                #"tell application "System Events" to return name of first process whose frontmost is true"#
            )
        )
        // Plain app scripting (no System Events) never needs the grant — even
        // when an app's own dictionary has a `click` verb.
        #expect(
            !AppleScriptAccessibility.requiresAccessibility(
                #"tell application "Safari" to return URL of front document"#
            )
        )
        #expect(!AppleScriptAccessibility.requiresAccessibility("set volume output volume 30"))
    }

    @Test("assistive-access denials map by number and by message; -1743 does not")
    func denialMapping() {
        #expect(
            AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: -25211,
                errorMessage: nil
            )
        )
        #expect(
            AppleScriptAccessibility.isAccessibilityDenial(errorNumber: 1002, errorMessage: nil)
        )
        #expect(
            AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: nil,
                errorMessage: "osascript is not allowed assistive access."
            )
        )
        #expect(
            AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: nil,
                errorMessage: "Osaurus is not allowed to send keystrokes."
            )
        )
        // The Automation denial has its own recovery path.
        #expect(
            !AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: -1743,
                errorMessage: "Not authorized to send Apple events to Safari."
            )
        )
        #expect(
            !AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: -1728,
                errorMessage: "Can't get window 1."
            )
        )
    }
}

// MARK: - App knowledge (dictionary distill + recipes + target detection)

@Suite("AppleScriptDictionaryService.distill")
struct AppleScriptDictionaryDistillTests {
    /// A miniature sdef exercising every element the distiller renders:
    /// a skipped Standard Suite, a class with typed/read-only properties and
    /// elements, an `application` class-extension, and a command with a direct
    /// parameter, named parameters (one optional), and a result.
    private var sdef: Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <dictionary title="TestApp Terminology">
          <suite name="Standard Suite" code="core" description="Generic verbs.">
            <command name="open" code="aevtodoc"/>
            <class name="window" code="cwin">
              <property name="bounds" code="pbnd" type="rectangle"/>
            </class>
          </suite>
          <suite name="TestApp Suite" code="test" description="App-specific.">
            <class name="track" code="trck">
              <property name="name" code="pnam" type="text"/>
              <property name="duration" code="durn" type="real" access="r"/>
              <element type="artwork"/>
            </class>
            <class-extension extends="application">
              <property name="player state" code="pPlS" type="player state"/>
            </class-extension>
            <command name="refresh" code="testrfsh">
              <direct-parameter type="track"/>
              <parameter name="force" code="frce" type="boolean" optional="yes"/>
              <result type="boolean"/>
            </command>
          </suite>
        </dictionary>
        """.data(using: .utf8)!
    }

    @Test("app-specific classes, extensions, and commands are rendered; Standard Suite is skipped")
    func distillsAppSpecificVocabulary() {
        let summary = AppleScriptDictionaryService.distill(sdefData: sdef, appName: "TestApp")
        let text = try! #require(summary)
        #expect(text.hasPrefix("TestApp scripting dictionary (app-specific):"))
        #expect(text.contains("class track — properties: name (text), duration (real, r/o); elements: artwork"))
        #expect(text.contains("class application (extended) — properties: player state (player state)"))
        #expect(text.contains("command refresh — direct: track; params: force (boolean)?; returns boolean"))
        // Standard Suite content must NOT leak in.
        #expect(!text.contains("class window"))
        #expect(!text.contains("command open"))
    }

    @Test("the summary is truncated at the char budget on line boundaries")
    func truncatesAtBudget() {
        // Budget fits the header + first class line but not the extension line.
        let summary = AppleScriptDictionaryService.distill(
            sdefData: sdef,
            appName: "TestApp",
            maxChars: 140
        )
        let text = try! #require(summary)
        #expect(text.count <= 140)
        #expect(text.contains("class track"))
        #expect(!text.contains("class application"))

        // A budget too small for even one line yields nil, not a bare header.
        #expect(
            AppleScriptDictionaryService.distill(sdefData: sdef, appName: "TestApp", maxChars: 50)
                == nil
        )
    }

    @Test("a dictionary with only Standard Suite distills to nil")
    func standardOnlyIsNil() {
        let standardOnly = """
            <?xml version="1.0" encoding="UTF-8"?>
            <dictionary>
              <suite name="Standard Suite" code="core">
                <command name="open" code="aevtodoc"/>
              </suite>
            </dictionary>
            """.data(using: .utf8)!
        #expect(
            AppleScriptDictionaryService.distill(sdefData: standardOnly, appName: "X") == nil
        )
    }

    @Test("malformed XML distills to nil")
    func malformedIsNil() {
        let junk = Data("not xml at all".utf8)
        #expect(AppleScriptDictionaryService.distill(sdefData: junk, appName: "X") == nil)
    }
}

@Suite("AppleScriptAppKnowledge")
struct AppleScriptAppKnowledgeTests {
    @Test("apps named in the task are detected in task order, capped at the limit")
    func detectsNamedApps() {
        let apps = AppleScriptAppKnowledge.detectTargetApps(
            task: "Copy the URL from Safari into a new note in Notes, then open Mail",
            frontmost: "Finder",
            runningAppNames: ["Safari", "Finder"]
        )
        #expect(apps == ["Safari", "Notes"])
    }

    @Test("matching is word-bounded: 'take notes' should not target the Notes app twice-removed")
    func wordBoundedMatch() {
        // "Notes" appears only inside "Keynotes" — no word-boundary match.
        let apps = AppleScriptAppKnowledge.detectTargetApps(
            task: "Summarize my Keynotes deck",
            frontmost: nil,
            runningAppNames: []
        )
        #expect(apps.isEmpty)
    }

    @Test("catalog apps match even when not running (the model may launch them)")
    func catalogAppsMatchWhenNotRunning() {
        let apps = AppleScriptAppKnowledge.detectTargetApps(
            task: "Create a reminder in Reminders for tomorrow 9am",
            frontmost: nil,
            runningAppNames: []
        )
        #expect(apps == ["Reminders"])
    }

    @Test("frontmost fallback applies only when the task refers to the frontmost app")
    func frontmostFallback() {
        let withCue = AppleScriptAppKnowledge.detectTargetApps(
            task: "What is the frontmost app doing?",
            frontmost: "Safari",
            runningAppNames: ["Safari"]
        )
        #expect(withCue == ["Safari"])

        let withoutCue = AppleScriptAppKnowledge.detectTargetApps(
            task: "What is the battery percentage?",
            frontmost: "Safari",
            runningAppNames: ["Safari"]
        )
        #expect(withoutCue.isEmpty)
    }

    @Test("recipe catalog matches by app name, case-insensitively")
    func recipeMatching() {
        #expect(!AppleScriptRecipeCatalog.recipes(for: "safari").isEmpty)
        #expect(!AppleScriptRecipeCatalog.recipes(for: "Shortcuts Events").isEmpty)
        #expect(AppleScriptRecipeCatalog.recipes(for: "NoSuchApp").isEmpty)
    }

    @Test("a task phrased 'run my … shortcut' surfaces the Shortcuts recipe")
    func shortcutTaskGetsShortcutsRecipe() {
        let apps = AppleScriptAppKnowledge.detectTargetApps(
            task: "Run my Morning Routine shortcut",
            frontmost: nil,
            runningAppNames: []
        )
        #expect(apps == ["Shortcut"])
        let sections = AppleScriptAppKnowledge.compose(apps: apps, runningApps: [])
        let recipes = try! #require(sections.recipes)
        #expect(recipes.contains("run shortcut"))
        #expect(recipes.contains("Shortcuts Events"))
    }

    @Test("compose emits recipe tips for a matched app and nothing for empty targets")
    func composeSections() {
        let sections = AppleScriptAppKnowledge.compose(apps: ["Safari"], runningApps: [])
        let recipes = try! #require(sections.recipes)
        #expect(recipes.hasPrefix("Safari AppleScript tips:"))
        #expect(recipes.contains("URL of front document"))

        #expect(AppleScriptAppKnowledge.compose(apps: [], runningApps: []) == .empty)
    }

    @Test("environment context parses back into frontmost + running names")
    func parseEnvironmentContext() {
        let context = "Frontmost app: Safari\nRunning apps: Safari, Notes, Finder"
        let parsed = AppleScriptAppKnowledge.parseEnvironmentContext(context)
        #expect(parsed.frontmost == "Safari")
        #expect(parsed.runningNames == ["Safari", "Notes", "Finder"])

        let empty = AppleScriptAppKnowledge.parseEnvironmentContext(nil)
        #expect(empty.frontmost == nil)
        #expect(empty.runningNames.isEmpty)
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

/// Lock-guarded log of strings recorded from `@Sendable` seams (e.g. the
/// scripts handed to the compile checker).
private final class MutableTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ text: String) {
        lock.lock()
        items.append(text)
        lock.unlock()
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Lock-guarded log of the languages the loop handed the executor seam.
private final class LanguageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AppleScriptLanguage] = []

    func append(_ language: AppleScriptLanguage) {
        lock.lock()
        items.append(language)
        lock.unlock()
    }

    func all() -> [AppleScriptLanguage] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Lock-guarded synchronous counter for the loop's `@Sendable () -> Void`
/// seams (the accessibility grant prompt), where an actor's async API can't
/// be called from the synchronous closure.
private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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

/// Collects the leases the warm-residency coordinator restores, and lets a test
/// suspend until the first (deferred) restore fires.
private actor RestoreCollector {
    private var items: [ChatResidencyLease] = []
    private var waiter: CheckedContinuation<ChatResidencyLease, Never>?

    func record(_ lease: ChatResidencyLease) {
        items.append(lease)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: lease)
        }
    }

    func all() -> [ChatResidencyLease] { items }

    func waitForOne() async -> ChatResidencyLease {
        if let first = items.first { return first }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
