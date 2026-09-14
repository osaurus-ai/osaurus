//
//  ComputerUseLoopRunTests.swift
//  OsaurusCoreTests — Computer Use
//
//  End-to-end `ComputerUseLoop.run` coverage WITHOUT a live model, using the
//  injectable `AgentStepProvider` seam + `MockMacDriver`. These pin the loop's
//  control flow — the termination + recovery policy the production run depends
//  on — deterministically:
//   • terminal verbs (done / give_up),
//   • the max-steps cap,
//   • the consecutive-invalid re-ask budget (malformed shape AND no tool call),
//   • reobserve → dead-end,
//   • cancellation via `InterruptToken`,
//   • gate confirm-decline (action is NOT executed), and
//   • a provider recovering from a rejection using the transcript feedback.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopRunTests: XCTestCase {

    // MARK: - Fixtures

    private func el(_ id: String, _ role: String, _ label: String?, value: String? = nil) -> CUElement {
        CUElement(id: id, role: role, label: label, value: value)
    }

    /// A driver with one focused app (so `currentPid` is non-nil from the
    /// start) serving a single steady-state snapshot.
    private func driver(_ elements: [CUElement], pid: Int32 = 4242) -> MockMacDriver {
        driver(sequence: [elements], pid: pid)
    }

    /// A driver serving the given element sets in capture order (the last one
    /// repeats), so a test can make the verify capture after an act differ
    /// from the initial perceive — i.e. a "view changed" signal.
    private func driver(sequence: [[CUElement]], pid: Int32 = 4242) -> MockMacDriver {
        let snaps = sequence.enumerated().map { index, elements in
            CUSnapshot(
                snapshotId: index + 1,
                pid: pid,
                app: "Demo",
                focusedWindow: "Main",
                tier: .ax,
                truncated: false,
                windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
                elements: elements,
                image: nil
            )
        }
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: snaps]
        )
    }

    private func run(
        _ driver: MockMacDriver,
        provider: @escaping AgentStepProvider,
        gate: ComputerUseGating = HardwiredGate(),
        confirm: @escaping @Sendable (ActionPreview) async -> Bool = { _ in true },
        interrupt: InterruptToken = InterruptToken(),
        limits: RunLimits = RunLimits(wallClockSeconds: 30)
    ) async -> ComputerUseRunResult {
        await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: driver,
            gate: gate,
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal"),
            interrupt: interrupt,
            confirm: confirm,
            limits: limits,
            sessionId: "cu-test",
            nextAction: provider
        )
    }

    // MARK: - Terminal verbs

    func testClickThenDoneSucceeds() async {
        // The verify capture after the click shows a changed view (a sheet
        // appeared), so `done` has evidence behind it.
        let d = driver(sequence: [
            [el("go", "button", "Go")],
            [el("go", "button", "Go"), el("ok", "button", "OK")],
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go"),
                AgentAction(verb: .done, reason: "all done"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "Expected done; got \(result.outcome)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 1, "The click should have been executed exactly once")
        XCTAssertGreaterThanOrEqual(result.metrics.actsAttempted, 1)
        XCTAssertEqual(result.metrics.verifyChanged, 1)
        XCTAssertEqual(result.metrics.unverifiedActs, 0)
    }

    // MARK: - Done needs evidence

    /// Synthesized input is fire-and-forget: a click whose verify capture
    /// shows no change is unproven. The loop tells the model so, gives it one
    /// challenge to look again, and a second unproven `done` ends as gaveUp —
    /// never as success.
    func testDoneWithoutVerifiedChangeIsChallengedThenGivesUp() async {
        let d = driver([el("go", "button", "Go")])  // static view: nothing ever changes
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go"),
                AgentAction(verb: .done, reason: "clicked it"),
                AgentAction(verb: .done, reason: "really, clicked it"),
            ])
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("An unverified done must not be reported as success; got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("could not be verified"), "got: \(reason)")
        XCTAssertEqual(result.metrics.actsAttempted, 1)
        XCTAssertEqual(result.metrics.verifyChanged, 0)
        XCTAssertEqual(result.metrics.unverifiedActs, 1, "The posted-but-unchanged click is counted")
    }

    /// A late-rendering app: the verify capture right after the click is
    /// unchanged, but the `observe` the challenge prompts shows the change.
    /// That late evidence is enough for the second `done`.
    func testDoneAfterLateObservedChangeSucceeds() async {
        let d = driver(sequence: [
            [el("go", "button", "Go")],  // initial perceive
            [el("go", "button", "Go")],  // verify after click: unchanged yet
            [el("go", "button", "Go"), el("ok", "button", "OK")],  // observe: rendered
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go"),
                AgentAction(verb: .done, reason: "clicked it"),
                AgentAction(verb: .observe, note: "check"),
                AgentAction(verb: .done, reason: "the sheet is up"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "Late-observed change should satisfy done; got \(result.outcome)")
        XCTAssertEqual(result.metrics.unverifiedActs, 1)
    }

    /// A run that never acted (pure read task) is not subject to the gate.
    func testObserveOnlyDoneIsNotChallenged() async {
        let d = driver([el("title", "statictext", "Report")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .observe, note: "read it"),
                AgentAction(verb: .done, reason: "The report title is Report."),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "got \(result.outcome)")
    }

    /// Eval seam: scripted scenarios that only exercise gate/parse contracts
    /// can switch the completion-evidence gate off.
    func testRequireVerifiedChangeKnobOffAcceptsUnverifiedDone() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go"),
                AgentAction(verb: .done, reason: "clicked"),
            ]),
            limits: RunLimits(wallClockSeconds: 30, requireVerifiedChangeForDone: false)
        )
        XCTAssertTrue(result.outcome.isSuccess, "got \(result.outcome)")
    }

    /// The verify tool-result must not call a posted-but-unobserved input a
    /// success; the model reads that wording as "it worked".
    func testUnverifiedActIsReportedHonestlyToTheModel() async {
        let d = driver([el("go", "button", "Go")])
        let recorder = ModelStepInputRecorder()
        let result = await run(
            d,
            provider: { input in
                let calls = await recorder.record(input)
                if calls == 1 {
                    return ModelActionCall(
                        id: "c1",
                        arguments: AgentAction(verb: .click, target: AgentTarget(mark: 1)).argumentsJSON()
                    )
                }
                return ModelActionCall(
                    id: "c\(calls)",
                    arguments: AgentAction(verb: .giveUp, reason: "stop").argumentsJSON()
                )
            }
        )
        guard case .gaveUp = result.outcome else { return XCTFail("got \(result.outcome)") }
        let inputs = await recorder.inputs
        let toolResults = inputs.flatMap { $0.transcript.filter { $0.role == "tool" }.map(\.text) }
        XCTAssertTrue(
            toolResults.contains { $0.contains("Input was posted") },
            "Expected the honest posted-but-unverified wording; got \(toolResults)"
        )
        XCTAssertFalse(toolResults.contains { $0.contains("Action succeeded") })
    }

    /// No surface can render the confirm card: the gated action fails fast
    /// with the typed reason and the run ends as gaveUp instead of parking on
    /// the card until the wall clock.
    func testConfirmUnavailableFailsFastWithReason() async {
        let d = driver([el("send", "button", "Send")])
        let result = await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: d,
            gate: AlwaysConfirmGate(),
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal"),
            interrupt: InterruptToken(),
            confirm: { _ in
                XCTFail("confirm must not be awaited when no presenter exists")
                return true
            },
            confirmUnavailable: { "no chat window is open to show the approval card" },
            limits: RunLimits(wallClockSeconds: 30),
            sessionId: "cu-test",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "send"),
                AgentAction(verb: .done, reason: "sent"),
            ])
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("Expected fail-fast gaveUp; got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("no chat window is open"), "got: \(reason)")
        XCTAssertEqual(result.metrics.confirmsUnpresentable, 1)
        XCTAssertEqual(result.metrics.confirmsRequested, 0)
        let clicks = await d.elementActions
        XCTAssertTrue(clicks.isEmpty, "The gated action must not run")
    }

    /// Time the user spends on a confirm card is credited back to the wall
    /// clock: a slow approval does not turn into "Reached the time limit".
    func testConfirmWaitDoesNotConsumeWallClock() async {
        let d = driver(sequence: [
            [el("send", "button", "Send")],
            [el("send", "button", "Send"), el("sent", "statictext", "Sent")],
        ])
        let result = await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: d,
            gate: AlwaysConfirmGate(),
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal"),
            interrupt: InterruptToken(),
            confirm: { _ in
                // The user takes longer than the whole run budget to approve.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return true
            },
            limits: RunLimits(wallClockSeconds: 1),
            sessionId: "cu-test",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "send"),
                AgentAction(verb: .done, reason: "sent"),
            ])
        )
        XCTAssertTrue(
            result.outcome.isSuccess,
            "The confirm wait must not count against the run; got \(result.outcome)"
        )
        XCTAssertEqual(result.metrics.confirmsApproved, 1)
    }

    func testGiveUpTerminatesWithReason() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .giveUp, reason: "cannot")])
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertEqual(reason, "cannot")
    }

    // MARK: - Step cap

    func testMaxStepsCapReached() async {
        let d = driver([el("go", "button", "Go")])
        // `observe` never terminates; the scripted cursor repeats it.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .observe)]),
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30)
        )
        guard case .stepCapReached = result.outcome else {
            return XCTFail("Expected stepCapReached; got \(result.outcome)")
        }
        XCTAssertEqual(result.metrics.steps, 3)
    }

    // MARK: - Re-ask budget

    func testConsecutiveInvalidShapesGiveUp() async {
        let d = driver([el("go", "button", "Go")])
        let bad: AgentStepProvider = { _ in ModelActionCall(id: "x", arguments: "{not valid json") }
        let result = await run(
            d,
            provider: bad,
            limits: RunLimits(maxConsecutiveInvalid: 2, wallClockSeconds: 30)
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("valid action"))
    }

    func testNoToolCallGivesUp() async {
        let d = driver([el("go", "button", "Go")])
        let none: AgentStepProvider = { _ in nil }
        let result = await run(
            d,
            provider: none,
            limits: RunLimits(maxConsecutiveInvalid: 2, wallClockSeconds: 30)
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
    }

    // MARK: - Reobserve → dead-end

    func testUnresolvableTargetDeadEnds() async {
        let d = driver([el("go", "button", "Go")])  // mark 1 exists; mark 99 doesn't
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 99), note: "miss")
            ]),
            limits: RunLimits(
                maxSteps: 10,
                maxConsecutiveReobserve: 1,
                maxConsecutiveDeadEnd: 1,
                wallClockSeconds: 30
            )
        )
        guard case .deadEnd = result.outcome else {
            return XCTFail("Expected deadEnd; got \(result.outcome)")
        }
        let clicks = await d.elementActions
        XCTAssertTrue(clicks.isEmpty, "An unresolved target must never reach the driver")
    }

    // MARK: - Cancellation

    func testInterruptTerminatesAsInterrupted() async {
        let d = driver([el("go", "button", "Go")])
        let token = InterruptToken()
        token.interrupt()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .observe)]),
            interrupt: token
        )
        guard case .interrupted = result.outcome else {
            return XCTFail("Expected interrupted; got \(result.outcome)")
        }
    }

    // MARK: - Gate decline

    func testDeclinedActionIsNotExecuted() async {
        let d = driver([el("field", "textfield", "Note", value: "")])
        // `type` is an edit → HardwiredGate confirms it → confirm returns false.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .type, text: "hello", note: "fill note"),
                AgentAction(verb: .giveUp, reason: "declined"),
            ]),
            confirm: { _ in false }
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertEqual(result.metrics.confirmsRequested, 1)
        XCTAssertEqual(result.metrics.confirmsDeclined, 1)
        let edits = await d.elementActions
        XCTAssertTrue(edits.isEmpty, "A declined action must not be sent to the driver")
    }

    // MARK: - Recovery via transcript feedback

    func testProviderRecoversFromRejectionUsingToolResult() async {
        let d = driver([el("go", "button", "Go")])
        // First step: an invalid click (no target). Second step: the provider
        // sees the "rejected" tool result and recovers with `done`.
        let provider: AgentStepProvider = { input in
            if input.lastToolResult?.localizedCaseInsensitiveContains("rejected") ?? false {
                return ModelActionCall(
                    id: "recover",
                    arguments: AgentAction(verb: .done, reason: "recovered").argumentsJSON()
                )
            }
            return ModelActionCall(id: "bad", arguments: AgentAction(verb: .click).argumentsJSON())
        }
        let result = await run(
            d,
            provider: provider,
            limits: RunLimits(maxConsecutiveInvalid: 3, wallClockSeconds: 30)
        )
        XCTAssertTrue(result.outcome.isSuccess, "Provider should recover to done; got \(result.outcome)")
    }

    // MARK: - New verbs (Phase 2)

    func testWaitReperceivesThenContinues() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                // seconds:0 keeps the test instant; the verb still re-perceives.
                AgentAction(verb: .wait, seconds: 0, note: "let it settle"),
                AgentAction(verb: .done, reason: "ok"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "wait then done should succeed; got \(result.outcome)")
        let captures = await d.captureCount
        XCTAssertGreaterThanOrEqual(captures, 2, "wait must re-perceive the app after pausing")
    }

    func testDragResolvesBothEndpointsAndDrives() async {
        // marks 1 (card) and 2 (trash); after the drag the card is gone.
        let d = driver(sequence: [
            [el("card", "cell", "Card"), el("trash", "button", "Trash")],
            [el("trash", "button", "Trash")],
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .drag,
                    target: AgentTarget(mark: 1),
                    to: AgentTarget(mark: 2),
                    note: "card to trash"
                ),
                AgentAction(verb: .done, reason: "moved"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "drag then done should succeed; got \(result.outcome)")
        let coords = await d.coordinateActions
        XCTAssertEqual(coords.count, 1, "drag should issue exactly one coordinate drag")
        guard case .drag = coords.first else {
            return XCTFail("Expected a coordinate drag; got \(coords)")
        }
    }

    func testFindRoutesToDriverAndNarrowsToActionableMatches() async {
        // Three elements; find "Send" should narrow to the one Send button via
        // the driver's server-side query, and that match must stay clickable.
        let d = driver([
            el("go", "button", "Go"),
            el("send", "button", "Send"),
            el("note", "textfield", "Note", value: ""),
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .find, query: "Send", note: "locate send"),
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click the only match"),
                AgentAction(verb: .done, reason: "sent"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "find→click→done should succeed; got \(result.outcome)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 1, "Exactly the matched element should be clicked")
        guard case let .click(id, _, _) = clicks.first else {
            return XCTFail("Expected an element click; got \(clicks)")
        }
        XCTAssertEqual(id, "send", "The narrowed mark 1 must resolve to the Send button from the find result")
    }

    func testFindWithNoMatchesFallsBackToFullView() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .find, query: "Nonexistent", note: "miss"),
                AgentAction(verb: .done, reason: "gave up finding"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess)
    }

    func testDragWithUnresolvableDestinationDoesNotDrive() async {
        let d = driver([el("card", "cell", "Card")])  // only mark 1; destination mark 9 is missing
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .drag, target: AgentTarget(mark: 1), to: AgentTarget(mark: 9), note: "miss"),
                AgentAction(verb: .giveUp, reason: "no destination"),
            ]),
            limits: RunLimits(maxSteps: 10, wallClockSeconds: 30)
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        let coords = await d.coordinateActions
        XCTAssertTrue(coords.isEmpty, "An unresolved drag destination must never reach the driver")
    }

    // MARK: - Loop robustness (Phase 3)

    func testModelStepTimeoutFailsWhenInferenceHangs() async {
        let d = driver([el("go", "button", "Go")])
        // A provider that never returns within the per-step budget.
        let hang: AgentStepProvider = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ModelActionCall(id: "late", arguments: AgentAction(verb: .observe).argumentsJSON())
        }
        let result = await run(
            d,
            provider: hang,
            limits: RunLimits(
                wallClockSeconds: 30,
                modelStepTimeoutSeconds: 0.1,
                maxInferenceRetries: 0
            )
        )
        guard case .failed(let reason) = result.outcome else {
            return XCTFail("Expected failed on timeout; got \(result.outcome)")
        }
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("timed out"),
            "Expected a timeout reason; got: \(reason)"
        )
    }

    func testInferenceRetrySucceedsAfterTransientThrows() async {
        let d = driver([el("go", "button", "Go")])
        let counter = AttemptCounter()
        // Throw on the first two attempts, then return `done`.
        let flaky: AgentStepProvider = { _ in
            let n = await counter.bump()
            if n < 3 { throw TestInferenceError() }
            return ModelActionCall(id: "ok", arguments: AgentAction(verb: .done, reason: "recovered").argumentsJSON())
        }
        let result = await run(
            d,
            provider: flaky,
            limits: RunLimits(wallClockSeconds: 30, modelStepTimeoutSeconds: 0, maxInferenceRetries: 2)
        )
        XCTAssertTrue(result.outcome.isSuccess, "Retries should recover; got \(result.outcome)")
        let attempts = await counter.value
        XCTAssertEqual(attempts, 3, "Two retries after the initial attempt = three tries total")
    }

    func testMissingRequiredAgentActionUsesProtocolReaskInsteadOfBlindInferenceRetry() async {
        let d = driver([el("go", "button", "Go")])
        let recorder = ModelStepInputRecorder()
        let provider: AgentStepProvider = { input in
            let attempt = await recorder.record(input)
            if attempt == 1 {
                throw NSError(
                    domain: "OsaurusToolChoice",
                    code: 422,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The model did not produce a valid required tool call."
                    ]
                )
            }
            return ModelActionCall(
                id: "done",
                arguments: AgentAction(verb: .done, reason: "recovered").argumentsJSON()
            )
        }

        let result = await run(
            d,
            provider: provider,
            limits: RunLimits(
                wallClockSeconds: 30,
                modelStepTimeoutSeconds: 0,
                maxInferenceRetries: 2
            )
        )

        XCTAssertTrue(result.outcome.isSuccess, "The bounded protocol re-ask should recover; got \(result.outcome)")
        let inputs = await recorder.inputs
        XCTAssertEqual(inputs.count, 2, "The protocol error must bypass same-prompt inference retries")
        XCTAssertTrue(
            inputs[1].transcript.last?.text.contains("You must respond by calling the agent_action tool") == true,
            "The second model step must include the Computer Use loop's corrective protocol nudge"
        )
    }

    func testInferenceFailsAfterExhaustingRetries() async {
        let d = driver([el("go", "button", "Go")])
        let counter = AttemptCounter()
        let always: AgentStepProvider = { _ in
            _ = await counter.bump()
            throw TestInferenceError()
        }
        let result = await run(
            d,
            provider: always,
            limits: RunLimits(wallClockSeconds: 30, modelStepTimeoutSeconds: 0, maxInferenceRetries: 2)
        )
        guard case .failed = result.outcome else {
            return XCTFail("Expected failed after exhausting retries; got \(result.outcome)")
        }
        let attempts = await counter.value
        XCTAssertEqual(attempts, 3, "Initial try + two retries before failing")
    }

    func testRepeatedActionStallDeadEnds() async {
        let d = driver([el("go", "button", "Go")])
        // The model keeps clicking the same (resolvable) button forever.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go")
            ]),
            limits: RunLimits(maxSteps: 20, wallClockSeconds: 30, maxRepeatedActions: 3)
        )
        guard case .deadEnd(let reason) = result.outcome else {
            return XCTFail("Expected a stall dead-end; got \(result.outcome)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("repeated"), "got: \(reason)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 2, "Two clicks land before the third identical proposal stalls")
    }

    func testRepeatedScrollDoesNotStall() async {
        let d = driver([el("go", "button", "Go")])
        // Scroll is exempt (paging a list is real progress), so a repeated
        // scroll should ride out to the step cap rather than stall-dead-end.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .scroll, direction: .down, note: "page down")
            ]),
            limits: RunLimits(maxSteps: 5, wallClockSeconds: 30, maxRepeatedActions: 3)
        )
        guard case .stepCapReached = result.outcome else {
            return XCTFail("Repeated scroll should not stall; got \(result.outcome)")
        }
    }

    // MARK: - Empty-AX escalation

    /// A driver that serves an empty AX snapshot first, then a populated one —
    /// the Electron / custom-drawn-UI shape the empty-AX escalation targets.
    private func emptyThenPopulated(screenRecording: Bool, pid: Int32 = 4242) -> MockMacDriver {
        let window = CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)
        let empty = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Electron",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [],
            image: nil
        )
        let populated = CUSnapshot(
            snapshotId: 2,
            pid: pid,
            app: "Electron",
            focusedWindow: "Main",
            tier: .som,
            truncated: false,
            windows: [window],
            elements: [el("send", "button", "Send")],
            image: CUImage(base64: "", mimeType: "image/png", width: 1, height: 1)
        )
        return MockMacDriver(
            availability: MacDriverAvailability(
                accessibility: true,
                screenRecording: screenRecording,
                skyLight: true
            ),
            activeWindow: CUActiveWindow(pid: pid, app: "Electron", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [empty, populated]]
        )
    }

    func testEmptyAXEscalatesToSomWhenPixelsAvailable() async {
        let d = emptyThenPopulated(screenRecording: true)
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .done, reason: "ok")])
        )
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(
            result.metrics.maxTier,
            .som,
            "An empty AX view with Screen Recording should escalate ax→som"
        )
    }

    func testEmptyAXStaysAtAxWithoutScreenRecording() async {
        let d = emptyThenPopulated(screenRecording: false)
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .done, reason: "ok")])
        )
        XCTAssertEqual(
            result.metrics.maxTier,
            .ax,
            "No Screen Recording means there is no tier to escalate an empty view to"
        )
    }
}

// MARK: - Robustness test support

/// Thread-safe attempt counter for the inference-retry tests (the provider is
/// `@Sendable` and may be invoked across hops).
private actor AttemptCounter {
    private(set) var value = 0
    func bump() -> Int {
        value += 1
        return value
    }
}

private actor ModelStepInputRecorder {
    private(set) var inputs: [AgentStepInput] = []

    func record(_ input: AgentStepInput) -> Int {
        inputs.append(input)
        return inputs.count
    }
}

private struct TestInferenceError: Error {}

/// Confirms every action, so tests can exercise the confirm seam with a
/// read-effect click that `HardwiredGate` would otherwise auto-run.
private struct AlwaysConfirmGate: ComputerUseGating {
    func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision {
        .confirm(
            ActionPreview(
                appName: appName,
                actionLabel: action.feedLabel,
                targetLabel: targetLabel,
                effect: effect,
                note: action.note
            )
        )
    }
}
