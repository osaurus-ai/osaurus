//
//  TargetResolverTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The one place mark→id resolution + staleness handling lives. These cover
//  the three outcomes the loop's retry/escalation policy keys off:
//   • resolved   — a confident unique element (by mark, then describe),
//   • reobserve  — probably exists but this view can't pin it (out-of-range
//                  mark, stale mark, ambiguous/zero describe), and
//   • deadEnd    — unusable as given (empty target).
//
//  Pure + model-free: build a view/snapshot in memory and resolve against it.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class TargetResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func el(_ id: String, _ role: String, _ label: String?, value: String? = nil) -> CUElement {
        CUElement(id: id, role: role, label: label, value: value)
    }

    private func make(_ elements: [CUElement]) -> (view: AgentView, snapshot: CUSnapshot) {
        let snap = CUSnapshot(
            snapshotId: 1,
            pid: 1,
            app: "App",
            focusedWindow: nil,
            tier: .ax,
            truncated: false,
            windows: [],
            elements: elements,
            image: nil
        )
        return (AgentView.build(from: snap, previous: nil), snap)
    }

    private func assertResolved(
        _ res: TargetResolution,
        id expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .resolved(let elementId, _) = res else {
            return XCTFail("Expected resolved \(expected); got \(res)", file: file, line: line)
        }
        XCTAssertEqual(elementId, expected, file: file, line: line)
    }

    private func reobserveReason(_ res: TargetResolution) -> String? {
        if case .reobserve(let r) = res { return r }
        return nil
    }

    private func deadEndReason(_ res: TargetResolution) -> String? {
        if case .deadEnd(let r) = res { return r }
        return nil
    }

    // MARK: - Mark resolution

    func testResolvesByMark() {
        let (view, snap) = make([el("a", "button", "Go"), el("b", "textfield", "Search")])
        assertResolved(TargetResolver.resolve(AgentTarget(mark: 1), view: view, snapshot: snap), id: "a")
        assertResolved(TargetResolver.resolve(AgentTarget(mark: 2), view: view, snapshot: snap), id: "b")
    }

    func testOutOfRangeMarkReobserves() {
        let (view, snap) = make([el("a", "button", "Go")])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(mark: 99), view: view, snapshot: snap)
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("current view") ?? false)
    }

    func testStaleMarkReobserves() {
        // Mark exists in the (older) view, but the live snapshot no longer has
        // its id — the signature stale case the loop re-perceives on.
        let (view, _) = make([el("a", "button", "Go")])
        let liveSnap = CUSnapshot(
            snapshotId: 2,
            pid: 1,
            app: "App",
            focusedWindow: nil,
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [el("z", "button", "Go")],  // different id
            image: nil
        )
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(mark: 1), view: view, snapshot: liveSnap)
        )
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("stale") ?? false, "got: \(reason ?? "nil")")
    }

    func testOutOfRangeMarkWithDescribeFallbackResolves() {
        let (view, snap) = make([el("a", "button", "Send")])
        // Mark is bogus but the describe rescues it.
        assertResolved(
            TargetResolver.resolve(AgentTarget(mark: 99, describe: "Send"), view: view, snapshot: snap),
            id: "a"
        )
    }

    // MARK: - Describe resolution

    func testDescribeUniqueResolves() {
        let (view, snap) = make([el("a", "button", "Go"), el("b", "textfield", "Search")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Search"), view: view, snapshot: snap),
            id: "b"
        )
    }

    func testExactLabelBeatsSubstring() {
        // "Save" must resolve to the exact "Save", not the "Save As" substring.
        let (view, snap) = make([el("a", "button", "Save"), el("b", "button", "Save As")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Save"), view: view, snapshot: snap),
            id: "a"
        )
    }

    func testAmbiguousDescribeReobserves() {
        let (view, snap) = make([
            el("a", "button", "Reply to all"),
            el("b", "button", "Reply to sender"),
        ])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(describe: "reply"), view: view, snapshot: snap)
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("matches 2") ?? false, "got: \(reason ?? "nil")")
    }

    func testZeroMatchDescribeReobserves() {
        let (view, snap) = make([el("a", "button", "Go")])
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(describe: "nonexistent"), view: view, snapshot: snap)
        )
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("nothing matches") ?? false)
    }

    // MARK: - Dead ends

    func testNilTargetDeadEnds() {
        let (view, snap) = make([el("a", "button", "Go")])
        XCTAssertNotNil(deadEndReason(TargetResolver.resolve(nil, view: view, snapshot: snap)))
    }

    func testEmptyTargetDeadEnds() {
        let (view, snap) = make([el("a", "button", "Go")])
        let res = TargetResolver.resolve(AgentTarget(mark: nil, describe: ""), view: view, snapshot: snap)
        XCTAssertNotNil(deadEndReason(res))
    }
}
