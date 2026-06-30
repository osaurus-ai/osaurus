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

    @Test("the applescript capability is registered in the delegation family")
    func capabilityMetadata() {
        let cap = SubagentCapabilityRegistry.appleScript
        #expect(cap.id == "applescript")
        #expect(cap.toolNames == [AppleScriptTool.toolName])
        #expect(cap.perAgentFlag == .appleScript)
        #expect(cap.supportsModelOverride == false)
        #expect(SubagentCapabilityRegistry.delegationFamily.contains { $0.id == "applescript" })
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
