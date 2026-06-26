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
        let snap = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: elements,
            image: nil
        )
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snap]]
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
        let d = driver([el("go", "button", "Go")])
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
        // marks 1 (card) and 2 (trash).
        let d = driver([el("card", "cell", "Card"), el("trash", "button", "Trash")])
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

private struct TestInferenceError: Error {}
