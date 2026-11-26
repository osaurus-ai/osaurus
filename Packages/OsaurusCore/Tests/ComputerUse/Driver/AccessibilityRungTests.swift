//
//  AccessibilityRungTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The pure decisions behind the AX-first rung (caret insertion, slider
//  stepping) and the loop's scroll routing: a scroll at
//  a slider steps it through AX, any other scroll lands at its target or the
//  focused window's center instead of under the user's cursor.
//

import XCTest

@testable import OsaurusCore

final class AccessibilityRungTests: XCTestCase {

    func testTextInsertionEligibility() {
        XCTAssertTrue(AXTextInsertion.isEligible(text: "hello world", isChromium: false))
        XCTAssertFalse(AXTextInsertion.isEligible(text: "hello", isChromium: true), "web content needs key events")
        XCTAssertFalse(AXTextInsertion.isEligible(text: "line\n", isChromium: false), "Return acts as a key")
        XCTAssertFalse(AXTextInsertion.isEligible(text: "a\tb", isChromium: false), "Tab moves focus")
        XCTAssertFalse(AXTextInsertion.isEligible(text: "", isChromium: false))
    }

    func testInsertionCountsOnlyWhenTheReadBackShowsIt() {
        XCTAssertTrue(AXTextInsertion.landed(before: "ab", after: "abhi", text: "hi"))
        XCTAssertFalse(AXTextInsertion.landed(before: "ab", after: "ab", text: "hi"), "success without change")
        XCTAssertFalse(AXTextInsertion.landed(before: "ab", after: nil, text: "hi"), "unreadable value")
        XCTAssertFalse(AXTextInsertion.landed(before: "ab", after: "abx", text: "hi"))
    }

    func testAdjustmentMapping() {
        XCTAssertEqual(AXAdjustment.action(for: .up), AXAdjustment.increment)
        XCTAssertEqual(AXAdjustment.action(for: .right), AXAdjustment.increment)
        XCTAssertEqual(AXAdjustment.action(for: .down), AXAdjustment.decrement)
        XCTAssertEqual(AXAdjustment.action(for: .left), AXAdjustment.decrement)
        XCTAssertTrue(AXAdjustment.supports(["AXIncrement", "AXDecrement"]))
        XCTAssertFalse(AXAdjustment.supports(["AXIncrement"]))
        XCTAssertFalse(AXAdjustment.supports([]))
    }

    // MARK: - Loop scroll routing

    private func snapshot(_ elements: [CUElement]) -> CUSnapshot {
        CUSnapshot(
            snapshotId: 1,
            pid: 4242,
            app: "Demo",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 100, y: 40, w: 800, h: 600)],
            elements: elements,
            image: nil
        )
    }

    private func act(_ action: AgentAction, element: CUElement?, driver: MockMacDriver) async -> String {
        var tier = CaptureTier.ax
        var frame: CUImage?
        var view: AgentView?
        var snap: CUSnapshot? = snapshot(element.map { [$0] } ?? [])
        var metrics = ComputerUseRunMetrics()
        return await ComputerUseLoop.act(
            action: action,
            element: element,
            pid: 4242,
            driver: driver,
            availability: MacDriverAvailability(accessibility: true, screenRecording: false, skyLight: true),
            currentTier: &tier,
            pendingFrameImage: &frame,
            lastView: &view,
            lastSnapshot: &snap,
            metrics: &metrics,
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "t"),
            step: 1
        )
    }

    func testScrollOnASliderStepsItThroughAX() async {
        let slider = CUElement(
            id: "vol",
            role: "slider",
            label: "Volume",
            x: 10,
            y: 10,
            w: 100,
            h: 20,
            actions: ["AXIncrement", "AXDecrement"]
        )
        let driver = MockMacDriver(snapshots: [4242: [snapshot([slider])]])
        _ = await act(AgentAction(verb: .scroll, target: AgentTarget(mark: 1), direction: .up, amount: 3), element: slider, driver: driver)

        let performed = await driver.elementActions
        let coordinates = await driver.coordinateActions
        XCTAssertTrue(coordinates.isEmpty, "no wheel event at a slider")
        guard case .adjust(let id, let increment, let steps)? = performed.first else {
            return XCTFail("expected an adjust; got \(performed)")
        }
        XCTAssertEqual(id, "vol")
        XCTAssertTrue(increment)
        XCTAssertEqual(steps, 3)
    }

    func testUntargetedScrollLandsAtTheFocusedWindowCenter() async {
        let driver = MockMacDriver(snapshots: [4242: [snapshot([])]])
        _ = await act(AgentAction(verb: .scroll, direction: .down), element: nil, driver: driver)

        let coordinates = await driver.coordinateActions
        guard case .scroll(_, _, let x, let y, let pid)? = coordinates.first else {
            return XCTFail("expected a scroll; got \(coordinates)")
        }
        XCTAssertEqual(x, 500)
        XCTAssertEqual(y, 340)
        XCTAssertEqual(pid, 4242)
    }

    func testTargetedScrollLandsAtTheElementCenter() async {
        let list = CUElement(id: "list", role: "list", label: "Inbox", x: 200, y: 100, w: 300, h: 400)
        let driver = MockMacDriver(snapshots: [4242: [snapshot([list])]])
        _ = await act(
            AgentAction(verb: .scroll, target: AgentTarget(mark: 1), direction: .down),
            element: list,
            driver: driver
        )

        let coordinates = await driver.coordinateActions
        guard case .scroll(_, _, let x, let y, _)? = coordinates.first else {
            return XCTFail("expected a scroll; got \(coordinates)")
        }
        XCTAssertEqual(x, 350)
        XCTAssertEqual(y, 300)
    }
}
