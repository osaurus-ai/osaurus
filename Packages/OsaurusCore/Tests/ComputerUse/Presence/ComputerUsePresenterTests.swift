//
//  ComputerUsePresenterTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Pins the presence contract the takeover overlay depends on: `end` fires
//  exactly once for every outcome, pointer actions are bracketed by
//  willAct/didAct (so the shield is click-through only while they post),
//  confirm cards flip the pending state on and off, and the target follows
//  the latest snapshot. Also covers the overlay's pure decisions: keyboard
//  guard dispositions, shield mouse pass-through, window matching, and the
//  top-left to AppKit frame conversion.
//

import CoreGraphics
import Foundation
import XCTest

@testable import OsaurusCore

actor SpyPresenter: ComputerUsePresenting {
    enum Event: Equatable {
        case begin
        case target(pid: Int32, app: String)
        case willAct(verb: String, movesPointer: Bool, hasPoint: Bool)
        case didAct
        case confirm(Bool)
        case end(RunOutcome)
    }

    private(set) var events: [Event] = []
    private(set) var heartbeats = 0

    func begin(goal: String) { events.append(.begin) }
    func targetChanged(_ target: ComputerUsePresenceTarget?) {
        guard let target else { return }
        events.append(.target(pid: target.pid, app: target.app))
    }
    func willAct(_ act: ComputerUsePresenceAct) {
        events.append(.willAct(verb: act.verb, movesPointer: act.movesPointer, hasPoint: act.point != nil))
    }
    func didAct() { events.append(.didAct) }
    func confirmPending(_ pending: Bool) { events.append(.confirm(pending)) }
    func heartbeat() { heartbeats += 1 }
    func end(_ outcome: RunOutcome) { events.append(.end(outcome)) }

    var endCount: Int {
        events.filter { if case .end = $0 { return true } else { return false } }.count
    }
}

final class ComputerUsePresenterTests: XCTestCase {

    private func driver(sequence: [[CUElement]], pid: Int32 = 4242) -> MockMacDriver {
        let snaps = sequence.enumerated().map { index, elements in
            CUSnapshot(
                snapshotId: index + 1,
                pid: pid,
                app: "Demo",
                focusedWindow: "Main",
                tier: .ax,
                truncated: false,
                windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 100, y: 50, w: 800, h: 600)],
                elements: elements,
                image: nil
            )
        }
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 100, y: 50, w: 800, h: 600),
            snapshots: [pid: snaps]
        )
    }

    private func run(
        _ driver: MockMacDriver,
        actions: [AgentAction],
        presenter: SpyPresenter,
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
            sessionId: "cu-presence-test",
            nextAction: ComputerUseLoop.scriptedProvider(actions),
            presenter: presenter
        )
    }

    private let button = CUElement(id: "go", role: "button", label: "Go")
    private let ok = CUElement(id: "ok", role: "button", label: "OK")

    func testPointerActIsBracketedAndEndFiresOnce() async {
        let spy = SpyPresenter()
        let result = await run(
            driver(sequence: [[button], [button, ok]]),
            actions: [
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "done"),
            ],
            presenter: spy
        )
        XCTAssertTrue(result.outcome.isSuccess, "got \(result.outcome)")
        let events = await spy.events
        XCTAssertEqual(events.first, .begin)
        XCTAssertEqual(events.last, .end(result.outcome))
        let endCount = await spy.endCount
        XCTAssertEqual(endCount, 1)
        XCTAssertTrue(events.contains(.target(pid: 4242, app: "Demo")))
        guard let willIndex = events.firstIndex(of: .willAct(verb: "click", movesPointer: true, hasPoint: true))
        else { return XCTFail("click should announce itself with a point: \(events)") }
        XCTAssertEqual(events[willIndex + 1], .didAct, "didAct must follow the pointer act directly")
    }

    func testEndFiresOnceForEveryOutcome() async {
        let cases: [(String, [AgentAction], RunLimits, Bool)] = [
            ("gaveUp", [AgentAction(verb: .giveUp, reason: "nope")], RunLimits(wallClockSeconds: 30), false),
            (
                "stepCap", Array(repeating: AgentAction(verb: .observe, note: "look"), count: 6),
                RunLimits(maxSteps: 2, wallClockSeconds: 30), false
            ),
            ("interrupted", [AgentAction(verb: .observe, note: "look")], RunLimits(wallClockSeconds: 30), true),
        ]
        for (label, actions, limits, interrupted) in cases {
            let spy = SpyPresenter()
            let token = InterruptToken()
            if interrupted { token.interrupt() }
            let result = await run(
                driver(sequence: [[button]]),
                actions: actions,
                presenter: spy,
                interrupt: token,
                limits: limits
            )
            let events = await spy.events
            let endCount = await spy.endCount
            XCTAssertEqual(endCount, 1, "\(label): end must fire exactly once; events \(events)")
            XCTAssertEqual(events.last, .end(result.outcome), "\(label): end must be the last event")
            XCTAssertFalse(result.outcome.isSuccess, label)
        }
    }

    func testConfirmCardTogglesPendingAroundTheWait() async {
        let spy = SpyPresenter()
        let result = await run(
            driver(sequence: [[button]]),
            actions: [AgentAction(verb: .click, target: AgentTarget(mark: 1))],
            presenter: spy,
            gate: ConfirmEverythingGate(),
            confirm: { _ in false }
        )
        let events = await spy.events
        guard let on = events.firstIndex(of: .confirm(true)) else {
            return XCTFail("a gated action should mark confirm pending: \(events)")
        }
        XCTAssertEqual(events[on + 1], .confirm(false), "pending must clear as soon as the card resolves")
        XCTAssertFalse(
            events.contains(.willAct(verb: "click", movesPointer: true, hasPoint: true)),
            "a declined action must not be announced as acting"
        )
        XCTAssertEqual(events.last, .end(result.outcome))
    }

    func testKeyboardVerbsDoNotMovePointer() {
        XCTAssertFalse(ComputerUseLoop.movesPointer(.type))
        XCTAssertFalse(ComputerUseLoop.movesPointer(.pressKey))
        XCTAssertFalse(ComputerUseLoop.movesPointer(.open))
        XCTAssertTrue(ComputerUseLoop.movesPointer(.click))
        XCTAssertTrue(ComputerUseLoop.movesPointer(.drag))
        XCTAssertTrue(ComputerUseLoop.movesPointer(.scroll))
    }

    // MARK: - Keyboard guard

    func testKeyboardGuardDispositions() {
        typealias G = KeyboardGuard
        XCTAssertEqual(
            G.disposition(isSynthesized: true, targetIsFrontmost: true, isKeyDown: true, keyCode: 0), .pass,
            "the driver's own keystrokes always pass"
        )
        XCTAssertEqual(
            G.disposition(isSynthesized: false, targetIsFrontmost: false, isKeyDown: true, keyCode: 0), .pass,
            "typing in another app is untouched"
        )
        XCTAssertEqual(
            G.disposition(isSynthesized: false, targetIsFrontmost: true, isKeyDown: true, keyCode: 0), .drop
        )
        XCTAssertEqual(
            G.disposition(isSynthesized: false, targetIsFrontmost: true, isKeyDown: true, keyCode: G.escapeKeyCode),
            .stop
        )
        XCTAssertEqual(
            G.disposition(isSynthesized: false, targetIsFrontmost: true, isKeyDown: false, keyCode: G.escapeKeyCode),
            .drop,
            "only the Esc key-down stops; its key-up is swallowed"
        )
        XCTAssertEqual(
            G.disposition(isSynthesized: false, targetIsFrontmost: false, isKeyDown: true, keyCode: G.escapeKeyCode),
            .pass,
            "Esc in another app is that app's"
        )
    }

    func testEventTagRoundTrips() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertFalse(ComputerUseEventTag.isSynthesized(event))
        ComputerUseEventTag.mark(event)
        XCTAssertTrue(ComputerUseEventTag.isSynthesized(event))
    }

    // MARK: - Controller

    @MainActor
    func testShieldPassesMouseOnlyWhileActingOrUnlocked() {
        let locked = TakeoverController(locksTarget: true, onStop: {})
        XCTAssertFalse(locked.shieldPassesMouse)
        locked.willAct(ComputerUsePresenceAct(verb: "click", point: nil, movesPointer: true))
        XCTAssertFalse(locked.shieldPassesMouse, "events before begin are ignored")
        locked.end()

        let unlocked = TakeoverController(locksTarget: false, onStop: {})
        XCTAssertTrue(unlocked.shieldPassesMouse)
        unlocked.end()
    }

    @MainActor
    func testEndIsIdempotentAndStopRequiresActiveRun() {
        var stops = 0
        let controller = TakeoverController(locksTarget: false, onStop: { stops += 1 })
        controller.requestStop()
        XCTAssertEqual(stops, 0, "stop before begin is ignored")
        controller.end()
        controller.end()
        XCTAssertTrue(controller.isTornDown)
        controller.begin(goal: "g")
        XCTAssertFalse(controller.isActive, "a torn-down controller never comes back")
    }

    @MainActor
    func testMissedHeartbeatsTearDownTheTakeover() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = TakeoverController(locksTarget: false, clock: { now }, onStop: {})
        controller.begin(goal: "g")
        defer { controller.end() }
        XCTAssertTrue(controller.isActive)

        now += TakeoverController.watchdogSeconds - 1
        controller.heartbeat()
        now += TakeoverController.watchdogSeconds - 1
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(controller.isActive, "a heartbeat inside the window keeps the takeover up")

        now += 2
        for _ in 0..<20 where !controller.isTornDown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(controller.isTornDown, "no heartbeat for longer than the watchdog ends the takeover")
        XCTAssertFalse(controller.isActive)
    }

    // MARK: - Window locator

    func testBestMatchPrefersLargestOverlap() {
        let a = WindowServerWindow(id: 1, pid: 1, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0)
        let b = WindowServerWindow(id: 2, pid: 1, bounds: CGRect(x: 100, y: 50, width: 800, height: 600), layer: 0)
        let match = TargetWindowLocator.bestMatch(
            for: CGRect(x: 101, y: 50, width: 799, height: 600),
            among: [a, b]
        )
        XCTAssertEqual(match?.id, 2)
        XCTAssertEqual(TargetWindowLocator.bestMatch(for: nil, among: [a, b])?.id, 1, "no frame: frontmost")
        XCTAssertNil(
            TargetWindowLocator.bestMatch(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), among: [a, b])
        )
    }

    func testAppKitFrameFlipsAgainstPrimaryScreen() {
        let rect = TargetWindowLocator.appKitFrame(
            fromTopLeft: CGRect(x: 100, y: 50, width: 800, height: 600),
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(rect, NSRect(x: 100, y: 350, width: 800, height: 600))
        XCTAssertEqual(
            TargetWindowLocator.localPoint(CGPoint(x: 150, y: 80), in: CGRect(x: 100, y: 50, width: 800, height: 600)),
            CGPoint(x: 50, y: 30)
        )
    }
}

/// Every action needs the user's approval.
private struct ConfirmEverythingGate: ComputerUseGating {
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
