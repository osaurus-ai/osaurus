//
//  ComputerUseLoopSurfaceTests.swift
//  OsaurusCoreTests — Computer Use
//
//  `ComputerUseLoop.run` coverage for the screenshot-addressed surface with
//  `MockMacDriver`: a `target.point` lands at the mapped screen point and is
//  gated by the element it hits, `zoom` is read-only and re-bases later
//  points, `hover` / `select` / key repeat reach the driver, and `batch` gates
//  every step and stops at the first one that doesn't go through.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopSurfaceTests: XCTestCase {

    private let pid: Int32 = 4242
    /// The window the screenshot shows, in screen points; the frame is half size.
    private let window = CUScreenRegion(x: 0, y: 0, w: 800, h: 600)

    private var elements: [CUElement] {
        [
            CUElement(id: "go", role: "button", label: "Go", x: 100, y: 100, w: 80, h: 30),
            CUElement(id: "delete", role: "button", label: "Delete", x: 300, y: 200, w: 80, h: 30),
            CUElement(id: "size", role: "popupbutton", label: "Size", value: "Small", x: 100, y: 300, w: 120, h: 30),
        ]
    }

    private func driver(withFrame: Bool = true, elements override: [CUElement]? = nil) -> MockMacDriver {
        let elements = override ?? self.elements
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: withFrame ? .som : .ax,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: elements,
            image: withFrame
                ? CUImage(base64: "", mimeType: "image/png", width: 400, height: 300, region: window)
                : nil
        )
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snapshot]]
        )
    }

    /// A populated AX view starts without pixels; `screenshot` attaches the
    /// frame that points are read in.
    private let shot = AgentAction(verb: .screenshot)

    private let localVision = VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)

    private func run(
        _ driver: MockMacDriver,
        _ actions: [AgentAction],
        vision: VisionContext? = nil,
        gate: ComputerUseGating = HardwiredGate(),
        confirm: @escaping @Sendable (ActionPreview) async -> Bool = { _ in true },
        results: ToolResultLog = ToolResultLog()
    ) async -> ComputerUseRunResult {
        let script = ComputerUseLoop.scriptedProvider(actions + [AgentAction(verb: .giveUp, reason: "end")])
        return await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: driver,
            gate: gate,
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal"),
            interrupt: InterruptToken(),
            confirm: confirm,
            limits: RunLimits(wallClockSeconds: 30),
            vision: vision ?? localVision,
            sessionId: "cu-surface",
            nextAction: { input in
                await results.record(input.lastToolResult)
                return try await script(input)
            }
        )
    }

    // MARK: - target.point

    func testPointClickLandsAtTheMappedScreenPoint() async {
        let d = driver()
        let result = await run(
            d,
            [shot, AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 70, y: 57)))]
        )
        let clicks = await d.coordinateActions
        guard case .click(let x, let y, _, _, let clickPid)? = clicks.first else {
            return XCTFail("Expected a coordinate click; got \(clicks)")
        }
        XCTAssertEqual(x, 140)
        XCTAssertEqual(y, 114)
        XCTAssertEqual(clickPid, pid)
        XCTAssertEqual(result.metrics.confirmsRequested, 0, "A point on the Go button is a navigate click")
    }

    /// Live finding: Calculator (SwiftUI, in the background) drops a click posted to its pid, while AXPress on the
    /// same button lands. A plain click whose point hits a control that presses goes through the element.
    func testPointClickOnAPressableControlPressesIt() async {
        var pressable = elements
        pressable[0] = CUElement(
            id: "go", role: "button", label: "Go", x: 100, y: 100, w: 80, h: 30, actions: ["press"])
        let d = driver(elements: pressable)
        _ = await run(d, [shot, AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 70, y: 57)))])
        let pressed = await d.elementActions
        guard case .click(let id, _, false)? = pressed.first else {
            return XCTFail("Expected an element click; got \(pressed)")
        }
        XCTAssertEqual(id, "go")
        let clicks = await d.coordinateActions
        XCTAssertTrue(clicks.isEmpty, "the click is not also posted at the point: \(clicks)")
    }

    func testOnlyPlainClicksOnPressableRolesPress() {
        let button = CUElement(id: "b", role: "button", actions: ["press"])
        XCTAssertTrue(ComputerUseLoop.pressesAsElement(.click, button))
        XCTAssertFalse(ComputerUseLoop.pressesAsElement(.doubleClick, button))
        XCTAssertFalse(ComputerUseLoop.pressesAsElement(.rightClick, button))
        XCTAssertFalse(ComputerUseLoop.pressesAsElement(.click, CUElement(id: "b", role: "button")))
        XCTAssertFalse(
            ComputerUseLoop.pressesAsElement(.click, CUElement(id: "t", role: "textfield", actions: ["press"])),
            "a click in a text field places the caret at the point")
        XCTAssertFalse(ComputerUseLoop.pressesAsElement(.click, nil))
    }

    func testPointClickIsGatedByTheElementItHits() async {
        let d = driver()
        let result = await run(
            d,
            [
                shot,
                AgentAction(
                    verb: .click,
                    target: AgentTarget(describe: "the Go button", point: AgentPoint(x: 170, y: 107))
                ),
            ],
            confirm: { _ in false }
        )
        XCTAssertEqual(result.metrics.confirmsRequested, 1, "The point hits Delete, whatever `describe` says")
        let clicks = await d.coordinateActions
        XCTAssertTrue(clicks.isEmpty, "A declined click must not post")
    }

    func testPointOnNothingNeedsApproval() async {
        let d = driver()
        let result = await run(
            d,
            [shot, AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 350, y: 250)))],
            confirm: { _ in false }
        )
        XCTAssertEqual(result.metrics.confirmsRequested, 1, "A click on no known element is escalated")
    }

    func testPointWithoutAScreenshotIsRefused() async {
        let d = driver(withFrame: false)
        let log = ToolResultLog()
        _ = await run(
            d,
            [AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 10, y: 10)))],
            vision: VisionContext.none,
            results: log
        )
        let clicks = await d.coordinateActions
        XCTAssertTrue(clicks.isEmpty)
        let last = await log.results.last ?? nil
        XCTAssertTrue(last?.contains("needs a screenshot") ?? false, "got: \(last ?? "nil")")
    }

    // MARK: - zoom / hover / select / repeat

    func testZoomIsReadOnlyAndRebasesLaterPoints() async {
        let d = driver()
        let result = await run(
            d,
            [
                shot,
                AgentAction(verb: .zoom, region: AgentRegion(x: 100, y: 50, width: 100, height: 50)),
                AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 10, y: 10))),
            ],
            confirm: { _ in false }
        )
        let zooms = await d.zoomCalls
        XCTAssertEqual(zooms, [CUScreenRegion(x: 200, y: 100, w: 200, h: 100)])
        let clicks = await d.coordinateActions
        XCTAssertTrue(clicks.isEmpty, "Point (10, 10) of the close-up is blank screen; the click was declined")
        XCTAssertEqual(result.metrics.confirmsRequested, 1, "Only the click is gated, never the zoom")
    }

    func testZoomedPointHitsTheElementUnderIt() async {
        let d = driver()
        _ = await run(
            d,
            [
                shot,
                AgentAction(verb: .zoom, region: AgentRegion(x: 0, y: 0, width: 200, height: 150)),
                // The close-up is 400×300 at one pixel per point: (120, 110) is on Go.
                AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 120, y: 110))),
            ]
        )
        let clicks = await d.coordinateActions
        guard case .click(let x, let y, _, _, _)? = clicks.first else {
            return XCTFail("Expected a coordinate click; got \(clicks)")
        }
        XCTAssertEqual(x, 120)
        XCTAssertEqual(y, 110)
    }

    func testHoverAtAPointMovesThePointer() async {
        let d = driver()
        _ = await run(d, [shot, AgentAction(verb: .hover, target: AgentTarget(point: AgentPoint(x: 70, y: 57)))])
        let moves = await d.coordinateActions
        guard case .move(let x, let y, let movePid)? = moves.first else {
            return XCTFail("Expected a pointer move; got \(moves)")
        }
        XCTAssertEqual(x, 140)
        XCTAssertEqual(y, 114)
        XCTAssertEqual(movePid, pid)
    }

    func testSelectPicksTheOptionOnTheResolvedControl() async {
        let d = driver()
        _ = await run(d, [AgentAction(verb: .select, target: AgentTarget(mark: 3), option: "Large")])
        let actions = await d.elementActions
        guard case .selectOption(let id, let option)? = actions.first else {
            return XCTFail("Expected a select; got \(actions)")
        }
        XCTAssertEqual(id, "size")
        XCTAssertEqual(option, "Large")
    }

    func testPressKeyRepeatsTheKey() async {
        let d = driver()
        _ = await run(d, [AgentAction(verb: .pressKey, key: "down", repeatCount: 3)])
        let presses = await d.elementActions.filter {
            if case .pressKey(_, "down", _) = $0 { return true }
            return false
        }
        XCTAssertEqual(presses.count, 3)
    }

    // MARK: - batch

    func testBatchRunsStepsInOrderWithOneVerify() async {
        let d = driver()
        let capturesBefore = await d.captureCount
        let result = await run(
            d,
            [
                AgentAction(
                    verb: .batch,
                    actions: [
                        AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                        AgentAction(verb: .pressKey, key: "tab"),
                        AgentAction(verb: .pressKey, key: "tab"),
                    ]
                )
            ],
            gate: RunEverythingGate()
        )
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 3)
        guard case .click(let id, _, _)? = actions.first else { return XCTFail("click first; got \(actions)") }
        XCTAssertEqual(id, "go")
        XCTAssertEqual(result.metrics.actsAttempted, 3)
        let capturesAfter = await d.captureCount
        XCTAssertLessThanOrEqual(capturesAfter - capturesBefore, 4, "One verify capture, not one per step")
    }

    func testBatchStopsAtTheFirstFailure() async {
        let d = driver()
        await d.enqueueActionResults([.ok(), .failure("nope")])
        let log = ToolResultLog()
        _ = await run(
            d,
            [
                AgentAction(
                    verb: .batch,
                    actions: [
                        AgentAction(verb: .pressKey, key: "a"),
                        AgentAction(verb: .pressKey, key: "b"),
                        AgentAction(verb: .pressKey, key: "c"),
                    ]
                )
            ],
            gate: RunEverythingGate(),
            results: log
        )
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 2, "The step after the failure must not run")
        let batchResult = await log.results.last ?? nil
        XCTAssertTrue(batchResult?.contains("2. ") ?? false)
        XCTAssertTrue(batchResult?.contains("failed. nope") ?? false, "got: \(batchResult ?? "nil")")
        XCTAssertTrue(batchResult?.contains("Not run: step(s) 3") ?? false, "got: \(batchResult ?? "nil")")
    }

    func testBatchGatesEachStepAndStopsAtADecline() async {
        let d = driver()
        let result = await run(
            d,
            [
                AgentAction(
                    verb: .batch,
                    actions: [
                        AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                        AgentAction(verb: .click, target: AgentTarget(mark: 2)),
                        AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                    ]
                )
            ],
            confirm: { _ in false }
        )
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1, "Only Go runs; Delete is declined and the rest is skipped")
        XCTAssertEqual(result.metrics.confirmsRequested, 1)
        XCTAssertEqual(result.metrics.confirmsDeclined, 1)
    }

    func testBatchStopsAfterAnApprovedStep() async {
        let d = driver()
        let log = ToolResultLog()
        let result = await run(
            d,
            [
                AgentAction(
                    verb: .batch,
                    actions: [
                        AgentAction(verb: .click, target: AgentTarget(mark: 2)),
                        AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                    ]
                )
            ],
            confirm: { _ in true },
            results: log
        )
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1, "The approved step runs; the model checks it before the rest")
        XCTAssertEqual(result.metrics.confirmsApproved, 1)
        let batchResult = await log.results.last ?? nil
        XCTAssertTrue(batchResult?.contains("Stopped after this approved step") ?? false, "got: \(batchResult ?? "nil")")
    }
}

/// Runs every action, so batch-flow tests don't stop at approvals.
struct RunEverythingGate: ComputerUseGating {
    func evaluate(
        action: AgentAction,
        effect: EffectClass,
        appName: String?,
        targetLabel: String?
    ) async -> GateDecision { .run }
}

/// The tool result each decision saw, in order.
actor ToolResultLog {
    private(set) var results: [String?] = []

    func record(_ result: String?) { results.append(result) }
}
