//
//  TargetResolverTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The one place mark→id resolution + staleness handling lives. These cover
//  the three outcomes the loop's retry/escalation policy keys off:
//   • resolved   — a confident unique element (by mark, then describe),
//   • ambiguous  — multiple visible candidates; the model must choose a mark,
//   • reobserve  — probably exists but this view can't pin it (out-of-range
//                  mark, stale mark, zero describe), and
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
        strategy: TargetResolutionStrategy? = nil,
        minimumConfidence: Double? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .resolved(let elementId, _, let evidence) = res else {
            return XCTFail("Expected resolved \(expected); got \(res)", file: file, line: line)
        }
        XCTAssertEqual(elementId, expected, file: file, line: line)
        if let strategy {
            XCTAssertEqual(evidence.strategy, strategy, file: file, line: line)
        }
        if let minimumConfidence {
            XCTAssertGreaterThanOrEqual(evidence.confidence, minimumConfidence, file: file, line: line)
        }
        XCTAssertFalse(evidence.matchedMarks.isEmpty, file: file, line: line)
    }

    private func reobserveReason(_ res: TargetResolution) -> String? {
        if case .reobserve(let r) = res { return r }
        return nil
    }

    private func ambiguousCandidates(_ res: TargetResolution) -> [TargetResolutionCandidate]? {
        if case .ambiguous(_, let candidates) = res { return candidates }
        return nil
    }

    private func deadEndReason(_ res: TargetResolution) -> String? {
        if case .deadEnd(let r) = res { return r }
        return nil
    }

    // MARK: - Mark resolution

    func testResolvesByMark() {
        let (view, snap) = make([el("a", "button", "Go"), el("b", "textfield", "Search")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(mark: 1), view: view, snapshot: snap),
            id: "a",
            strategy: .mark,
            minimumConfidence: 1.0
        )
        assertResolved(
            TargetResolver.resolve(AgentTarget(mark: 2), view: view, snapshot: snap),
            id: "b",
            strategy: .mark,
            minimumConfidence: 1.0
        )
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
            id: "b",
            strategy: .exactLabel,
            minimumConfidence: 0.95
        )
    }

    func testExactLabelBeatsSubstring() {
        // "Save" must resolve to the exact "Save", not the "Save As" substring.
        let (view, snap) = make([el("a", "button", "Save"), el("b", "button", "Save As")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Save"), view: view, snapshot: snap),
            id: "a",
            strategy: .exactLabel
        )
    }

    func testExactValueResolvesWithEvidence() {
        let (view, snap) = make([el("a", "textfield", "Status", value: "Submitted")])
        assertResolved(
            TargetResolver.resolve(AgentTarget(describe: "Submitted"), view: view, snapshot: snap),
            id: "a",
            strategy: .exactValue,
            minimumConfidence: 0.9
        )
    }

    func testStaleScoredMatchReobserves() {
        let (view, _) = make([el("a", "textfield", "Status", value: "Submitted")])
        let liveSnap = CUSnapshot(
            snapshotId: 2,
            pid: 1,
            app: "App",
            focusedWindow: nil,
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [el("z", "textfield", "Other", value: "Submitted")],
            image: nil
        )
        let reason = reobserveReason(
            TargetResolver.resolve(AgentTarget(describe: "Submitted"), view: view, snapshot: liveSnap)
        )
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("went stale") ?? false, "got: \(reason ?? "nil")")
    }

    func testAmbiguousDescribeReturnsCandidates() {
        let (view, snap) = make([
            el("a", "button", "Reply to all"),
            el("b", "button", "Reply to sender"),
        ])
        let result = TargetResolver.resolve(AgentTarget(describe: "reply"), view: view, snapshot: snap)
        guard case .ambiguous(let reason, let candidates) = result else {
            return XCTFail("Expected ambiguity; got \(result)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("matches 2"), "got: \(reason)")
        XCTAssertEqual(candidates.map(\.mark), [1, 2])
        XCTAssertTrue(candidates.allSatisfy { $0.confidence > 0 })
    }

    func testAmbiguousDescribeCapsCandidatesAndNamesTopList() {
        let elements = (1 ... 7).map { index in
            el("reply-\(index)", "button", "Reply option \(index)")
        }
        let (view, snap) = make(elements)
        let result = TargetResolver.resolve(AgentTarget(describe: "reply"), view: view, snapshot: snap)
        guard case .ambiguous(let reason, let candidates) = result else {
            return XCTFail("Expected ambiguity; got \(result)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("matches 7"), "got: \(reason)")
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("top 6"), "got: \(reason)")
        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(candidates.map(\.mark), [1, 2, 3, 4, 5, 6])
    }

    func testDuplicateExactLabelsAreAmbiguous() {
        let (view, snap) = make([
            el("a", "button", "Delete"),
            el("b", "button", "Delete"),
        ])
        let candidates = ambiguousCandidates(
            TargetResolver.resolve(AgentTarget(describe: "Delete"), view: view, snapshot: snap)
        )
        XCTAssertEqual(candidates?.map(\.mark), [1, 2])
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
