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
        let feed = ComputerUseFeed(toolCallId: "t", goal: "g")

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
        let feed = ComputerUseFeed(toolCallId: "t", goal: "g")

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
        let feed = ComputerUseFeed(toolCallId: "t", goal: "g")

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
