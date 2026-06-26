//
//  ComputerUseLoopActTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coverage for the act-time robustness added for Electron apps (Slack):
//   • the coordinate fallback fired when a click resolves against the snapshot
//     value copy but fails at the LIVE AX layer (stale/removed ref — the
//     signature Electron failure), and
//   • the capture-tier escalation when even that fallback can't land, and
//   • the snapshot-cache retention depth that keeps a just-shown mark
//     resolvable across the several captures the loop makes per turn.
//
//  Driven through `ComputerUseLoop.act` directly with `MockMacDriver`, so no
//  live model is needed.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopActTests: XCTestCase {

    /// A cell at (100,200) sized 80x20 → center (140,210). The fallback should
    /// click that center.
    private func makeElement() -> CUElement {
        CUElement(id: "s1-13", role: "cell", label: "Jared", x: 100, y: 200, w: 80, h: 20)
    }

    private func clickAction() -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(mark: 13), note: "Open Jared")
    }

    private func grantedAvailability(screenRecording: Bool = true) -> MacDriverAvailability {
        MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true)
    }

    func testClickRetriesAtElementCenterWhenLiveRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // The AX-addressed click fails because the live ref is gone (Electron);
        // the coordinate fallback at the element's last-known center succeeds.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult.ok(),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        let out = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        XCTAssertEqual(coordActions.count, 1, "Exactly one coordinate-click fallback expected")
        guard case let .click(x, y, _, _, clickPid)? = coordActions.first else {
            return XCTFail("Expected a coordinate click fallback")
        }
        XCTAssertEqual(x, 140)
        XCTAssertEqual(y, 210)
        XCTAssertEqual(clickPid, pid)
        XCTAssertEqual(metrics.coordinateFallbacks, 1)
        XCTAssertTrue(out.contains("Action succeeded"), "Fallback success should be reported; got: \(out)")
        // A landed fallback means no need to escalate.
        XCTAssertEqual(currentTier, .ax)
    }

    func testPersistentStaleEscalatesCaptureTier() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // Both the AX click and the coordinate fallback fail removed.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult(success: false, error: "still gone", removed: true),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        XCTAssertEqual(metrics.coordinateFallbacks, 1)
        XCTAssertEqual(currentTier, .som, "A click still stale after the fallback should escalate ax→som")
        XCTAssertEqual(metrics.maxTier, .som)
    }

    func testSetValueRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        // set_value fails (live ref removed), the focus click lands, the
        // pid-context type that replaces the value lands too.
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // setValue
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        let out = await ComputerUseLoop.act(
            action: AgentAction(verb: .setValue, target: AgentTarget(mark: 13), text: "Jared"),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        XCTAssertEqual(coordActions.count, 1, "A focus coordinate-click should precede the retry")
        let elementActions = await driver.elementActions
        XCTAssertEqual(elementActions.count, 2, "set_value then the pid-context type retry")
        guard case let .typeText(id, typePid, text, replace) = elementActions.last else {
            return XCTFail("Expected a typeText retry; got \(elementActions)")
        }
        XCTAssertNil(id, "The retry must drop the stale id and type in pid context")
        XCTAssertEqual(typePid, pid)
        XCTAssertEqual(text, "Jared")
        XCTAssertTrue(replace)
        XCTAssertEqual(metrics.coordinateFallbacks, 1)
        XCTAssertTrue(out.contains("Action succeeded"), "Fallback success should be reported; got: \(out)")
        XCTAssertEqual(currentTier, .ax, "A landed fallback means no need to escalate")
    }

    func testClearRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // clearField
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText("") retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .clear, target: AgentTarget(mark: 13)),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let elementActions = await driver.elementActions
        guard case let .typeText(id, _, text, replace) = elementActions.last else {
            return XCTFail("Expected a typeText retry; got \(elementActions)")
        }
        XCTAssertNil(id)
        XCTAssertEqual(text, "", "clear is a wholesale replace with empty text")
        XCTAssertTrue(replace)
        XCTAssertEqual(metrics.coordinateFallbacks, 1)
    }

    func testTypeRetriesViaCoordinateFocusWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // typeText(id)
            CUActionResult.ok(),  // focus coordinate click
            CUActionResult.ok(),  // typeText(nil) retry
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .type, target: AgentTarget(mark: 13), text: "hi", replace: false),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        let coordActions = await driver.coordinateActions
        XCTAssertEqual(coordActions.count, 1)
        let elementActions = await driver.elementActions
        guard case let .typeText(id, _, text, replace) = elementActions.last else {
            return XCTFail("Expected a typeText retry; got \(elementActions)")
        }
        XCTAssertNil(id, "The retry types into the focused field in pid context")
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(replace, "The original append (replace=false) semantics are preserved")
        XCTAssertEqual(metrics.coordinateFallbacks, 1)
    }

    // MARK: - New verbs (Phase 2)

    private func actNoFallbackHelper(_ action: AgentAction, destination: CUElement? = nil) async -> (
        driver: MockMacDriver, out: String
    ) {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")
        let out = await ComputerUseLoop.act(
            action: action,
            element: makeElement(),
            destinationElement: destination,
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )
        return (driver, out)
    }

    func testDoubleClickPerformsDoubleClickOnElement() async {
        let (driver, out) = await actNoFallbackHelper(
            AgentAction(verb: .doubleClick, target: AgentTarget(mark: 13))
        )
        let actions = await driver.elementActions
        guard case let .click(id, button, double)? = actions.first else {
            return XCTFail("Expected an element click; got \(actions)")
        }
        XCTAssertEqual(id, "s1-13")
        XCTAssertEqual(button, .left)
        XCTAssertTrue(double, "double_click must set doubleClick:true")
        XCTAssertTrue(out.contains("Action succeeded"))
    }

    func testRightClickPerformsRightClickOnElement() async {
        let (driver, _) = await actNoFallbackHelper(
            AgentAction(verb: .rightClick, target: AgentTarget(mark: 13))
        )
        let actions = await driver.elementActions
        guard case let .click(_, button, double)? = actions.first else {
            return XCTFail("Expected an element click; got \(actions)")
        }
        XCTAssertEqual(button, .right, "right_click must use the right button")
        XCTAssertFalse(double)
    }

    func testDragUsesCoordinateDragBetweenCenters() async {
        // start center (140,210); destination cell at (300,400) 80x20 → (340,410).
        let dest = CUElement(id: "s1-20", role: "cell", label: "Trash", x: 300, y: 400, w: 80, h: 20)
        let (driver, out) = await actNoFallbackHelper(
            AgentAction(verb: .drag, target: AgentTarget(mark: 13), to: AgentTarget(mark: 20)),
            destination: dest
        )
        let coords = await driver.coordinateActions
        guard case let .drag(sx, sy, ex, ey, dragPid)? = coords.first else {
            return XCTFail("Expected a coordinate drag; got \(coords)")
        }
        XCTAssertEqual(sx, 140)
        XCTAssertEqual(sy, 210)
        XCTAssertEqual(ex, 340)
        XCTAssertEqual(ey, 410)
        XCTAssertEqual(dragPid, 4242)
        XCTAssertTrue(out.contains("Action succeeded"))
    }

    func testDoubleClickRetriesAtCenterWhenRefRemoved() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),  // element double-click
            CUActionResult.ok(),  // coordinate fallback
        ])
        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")
        _ = await ComputerUseLoop.act(
            action: AgentAction(verb: .doubleClick, target: AgentTarget(mark: 13)),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )
        let coords = await driver.coordinateActions
        guard case let .click(x, y, button, double, _)? = coords.first else {
            return XCTFail("Expected a coordinate-click fallback; got \(coords)")
        }
        XCTAssertEqual(x, 140)
        XCTAssertEqual(y, 210)
        XCTAssertEqual(button, .left)
        XCTAssertTrue(double, "The double_click fallback must preserve doubleClick:true")
        XCTAssertEqual(metrics.coordinateFallbacks, 1)
    }

    func testNoEscalationWithoutScreenRecording() async {
        let pid: Int32 = 4242
        let driver = MockMacDriver()
        await driver.enqueueActionResults([
            CUActionResult(success: false, error: "gone", removed: true),
            CUActionResult(success: false, error: "still gone", removed: true),
        ])

        var currentTier: CaptureTier = .ax
        var pendingFrame: CUImage?
        var lastView: AgentView?
        var lastSnapshot: CUSnapshot?
        var metrics = ComputerUseRunMetrics()
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "g")

        _ = await ComputerUseLoop.act(
            action: clickAction(),
            element: makeElement(),
            pid: pid,
            driver: driver,
            availability: grantedAvailability(screenRecording: false),
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrame,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: 1
        )

        XCTAssertEqual(currentTier, .ax, "No Screen Recording means there is no tier to escalate to")
    }
}

final class AccessibilityManagerRetentionTests: XCTestCase {
    func testRetainsSixSnapshotGenerations() {
        let mgr = AccessibilityManager.shared
        var ids: [Int] = []
        for _ in 0 ..< 7 { ids.append(mgr.beginNewSnapshot(pid: 31337)) }

        // The oldest of seven consecutive generations rotates out (retain 6),
        // so the whole snapshot is gone → stale.
        guard case .stale = mgr.lookup(id: "s\(ids[0])-1") else {
            return XCTFail("Oldest snapshot should have been evicted (stale)")
        }

        // The newest six are retained. Element 1 was never stored in these
        // empty snapshots, so lookup reports `removed` (snapshot present, id
        // absent) — the signal that the generation is still cached, distinct
        // from the evicted `stale` above.
        for id in ids.suffix(6) {
            guard case .removed = mgr.lookup(id: "s\(id)-1") else {
                return XCTFail("Retained snapshot \(id) should report removed, not stale")
            }
        }
    }
}
