//
//  WorkflowFlowLayoutTests.swift
//  OsaurusCoreTests
//
//  The graph layout shared by the Architect's sidebar graph and the full
//  view: rows ordered to cross fewer lines, the cycle fallback, focus
//  sets, keyboard movement, fit zoom, line hits, and branches not taken.
//

import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowFlowLayoutTests {

    // MARK: - Fixtures

    private static func graph(_ ids: [String], _ edges: [(String, String)]) -> WorkflowDefinition {
        WorkflowDefinition(
            nodes: ids.map { WF.code($0) },
            edges: edges.map { WorkflowEdge(from: $0.0, to: $0.1) })
    }

    private static func run(_ def: WorkflowDefinition, status: WorkflowRunStatus, _ steps: [String: NodeRunStatus])
        -> WorkflowRun
    {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Flow", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: def.nodes.map(\.id))
        run.status = status
        for (id, state) in steps { run.update(id) { $0.status = state } }
        return run
    }

    // MARK: - Rows

    @Test func rows_placeEachStepOneRowBelowItsDeepestParent() {
        let def = Self.graph(["a", "b", "c", "d"], [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"), ("a", "d")])
        let rows = WorkflowFlowLayout.rows(def)
        #expect(rows.count == 3)
        #expect(rows[0] == ["a"])
        #expect(Set(rows[1]) == ["b", "c"])
        #expect(rows[2] == ["d"])
    }

    @Test func rows_uncrossTwoRootsFeedingSwappedChildren() {
        let def = Self.graph(["a", "b", "c", "d"], [("a", "d"), ("b", "c")])
        #expect(WorkflowFlowLayout.crossings([["a", "b"], ["c", "d"]], def: def) == 1)
        let rows = WorkflowFlowLayout.rows(def)
        #expect(WorkflowFlowLayout.crossings(rows, def: def) == 0)
        #expect(Set(rows.flatMap { $0 }) == ["a", "b", "c", "d"])
    }

    @Test func rows_uncrossAWideParallelFanOut() {
        let branches = (1...6).map { "c\($0)" }
        let leaves = (1...6).reversed().map { "g\($0)" }
        let def = Self.graph(
            ["root"] + branches + leaves,
            branches.map { ("root", $0) } + (1...6).map { ("c\($0)", "g\($0)") })
        let declared = [["root"], branches, leaves]
        #expect(WorkflowFlowLayout.crossings(declared, def: def) == 15)
        let rows = WorkflowFlowLayout.rows(def)
        #expect(rows.count == 3)
        #expect(rows[1].count == 6)
        #expect(WorkflowFlowLayout.crossings(rows, def: def) == 0)
    }

    @Test func rows_keepAFanOutAndJoinFreeOfCrossings() {
        let def = Self.graph(
            ["a", "b", "c", "d", "e"], [("a", "b"), ("a", "c"), ("a", "d"), ("b", "e"), ("c", "e"), ("d", "e")])
        let rows = WorkflowFlowLayout.rows(def)
        #expect(rows.map(\.count) == [1, 3, 1])
        #expect(WorkflowFlowLayout.crossings(rows, def: def) == 0)
    }

    @Test func rows_fallBackToOneStepPerRowForACycle() {
        let def = Self.graph(["a", "b", "c"], [("a", "b"), ("b", "a"), ("b", "c")])
        #expect(WorkflowFlowLayout.rows(def) == [["a"], ["b"], ["c"]])
    }

    @Test @MainActor func cachedRows_followTheGraphNotTheStepContents() {
        var def = Self.graph(["a", "b", "c"], [("a", "b"), ("a", "c")])
        #expect(WorkflowFlowLayout.cachedRows(def) == WorkflowFlowLayout.rows(def))
        def.nodes[0].name = "Renamed"
        #expect(WorkflowFlowLayout.cachedRows(def) == WorkflowFlowLayout.rows(def))
        def.edges.append(WorkflowEdge(from: "b", to: "c"))
        #expect(WorkflowFlowLayout.cachedRows(def) == [["a"], ["b"], ["c"]])
    }

    @Test func cappedArguments_cutALongPatchAtALine() {
        let short = "{\n  \"op\": \"update_node\"\n}"
        #expect(PreviewGenerator.cappedArguments(short) == short)
        let long = (0 ..< 2_000).map { "  \"line\($0)\": \"value\"," }.joined(separator: "\n")
        let capped = PreviewGenerator.cappedArguments(long, limit: 1_000)
        #expect(capped.count < 1_100)
        #expect(capped.hasSuffix("more characters)"))
        #expect(capped.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasSuffix(",") })
    }

    @Test func rows_neverMakeCrossingsWorseThanTheStart() {
        let def = WF.intake()
        let rows = WorkflowFlowLayout.rows(def)
        let start = WorkflowFlowLayout.crossings([["classify"], ["onboard", "lookup"], ["notify"]], def: def)
        #expect(WorkflowFlowLayout.crossings(rows, def: def) <= start)
    }

    // MARK: - Focus

    @Test func upstreamAndDownstream_followEveryPath() {
        let def = WF.intake()
        #expect(WorkflowFlowLayout.upstream(of: "notify", in: def) == ["classify", "onboard", "lookup"])
        #expect(WorkflowFlowLayout.downstream(of: "classify", in: def) == ["onboard", "lookup", "notify"])
        #expect(WorkflowFlowLayout.upstream(of: "classify", in: def).isEmpty)
        #expect(WorkflowFlowLayout.focus(on: "onboard", in: def) == ["classify", "onboard", "notify"])
    }

    @Test func focus_survivesACycle() {
        let def = Self.graph(["a", "b"], [("a", "b"), ("b", "a")])
        #expect(WorkflowFlowLayout.focus(on: "a", in: def) == ["a", "b"])
    }

    // MARK: - Moving

    @Test func neighbor_followsLinesSidewaysAndStaysInTheColumnUpAndDown() {
        let def = WF.intake()
        let rows = WorkflowFlowLayout.rows(def)
        let middle = rows[1]
        #expect(WorkflowFlowLayout.neighbor(of: "classify", .right, rows: rows, def: def) == middle[0])
        #expect(WorkflowFlowLayout.neighbor(of: middle[0], .down, rows: rows, def: def) == middle[1])
        #expect(WorkflowFlowLayout.neighbor(of: middle[1], .up, rows: rows, def: def) == middle[0])
        #expect(WorkflowFlowLayout.neighbor(of: middle[0], .up, rows: rows, def: def) == nil)
        #expect(WorkflowFlowLayout.neighbor(of: "notify", .left, rows: rows, def: def) == middle[0])
        #expect(WorkflowFlowLayout.neighbor(of: "notify", .right, rows: rows, def: def) == nil)
        #expect(WorkflowFlowLayout.neighbor(of: "classify", .left, rows: rows, def: def) == nil)
        #expect(WorkflowFlowLayout.neighbor(of: "missing", .right, rows: rows, def: def) == nil)
    }

    // MARK: - Zoom

    @Test func fitZoom_showsEverythingButNeverEnlargesOrGoesPastTheFloor() {
        let viewport = CGSize(width: 1000, height: 800)
        #expect(WorkflowFlowLayout.fitZoom(content: CGSize(width: 2000, height: 800), viewport: viewport) == 0.5)
        #expect(WorkflowFlowLayout.fitZoom(content: CGSize(width: 1000, height: 1600), viewport: viewport) == 0.5)
        #expect(WorkflowFlowLayout.fitZoom(content: CGSize(width: 300, height: 200), viewport: viewport) == 1)
        #expect(
            WorkflowFlowLayout.fitZoom(content: CGSize(width: 40000, height: 800), viewport: viewport)
                == WorkflowFlowLayout.minimumZoom)
        #expect(WorkflowFlowLayout.fitZoom(content: .zero, viewport: viewport) == 1)
        #expect(WorkflowFlowLayout.fitZoom(content: CGSize(width: 10, height: 10), viewport: .zero) == 1)
    }

    @Test func clampZoom_staysInRange() {
        #expect(WorkflowFlowLayout.clampZoom(5) == WorkflowFlowLayout.maximumZoom)
        #expect(WorkflowFlowLayout.clampZoom(0.01) == WorkflowFlowLayout.minimumZoom)
        #expect(WorkflowFlowLayout.clampZoom(0.8) == 0.8)
    }

    // MARK: - Lines

    @Test func hitEdge_findsTheLineUnderAPointAndNothingAwayFromIt() {
        let def = Self.graph(["a", "b", "c"], [("a", "b"), ("a", "c")])
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 100, width: 100, height: 40),
            "b": CGRect(x: 240, y: 0, width: 100, height: 40),
            "c": CGRect(x: 240, y: 200, width: 100, height: 40),
        ]
        let toC = WorkflowFlowLayout.curve(from: frames["a"]!, to: frames["c"]!, inset: 4)
        #expect(WorkflowFlowLayout.hitEdge(at: toC.midpoint, edges: def.edges, frames: frames, inset: 4) == 1)
        let toB = WorkflowFlowLayout.curve(from: frames["a"]!, to: frames["b"]!, inset: 4)
        #expect(WorkflowFlowLayout.hitEdge(at: toB.point(at: 0.8), edges: def.edges, frames: frames, inset: 4) == 0)
        #expect(WorkflowFlowLayout.hitEdge(at: CGPoint(x: 600, y: 600), edges: def.edges, frames: frames) == nil)
    }

    @Test func curve_runsFromTheRightEdgeOfOneStepToTheLeftEdgeOfTheNext() {
        let line = WorkflowFlowLayout.curve(
            from: CGRect(x: 0, y: 0, width: 100, height: 40), to: CGRect(x: 200, y: 60, width: 100, height: 40))
        #expect(line.start == CGPoint(x: 100, y: 20))
        #expect(line.end == CGPoint(x: 200, y: 80))
        #expect(line.control1.y == line.start.y)
        #expect(line.control2.y == line.end.y)
        #expect(line.point(at: 0) == line.start)
        #expect(line.point(at: 1) == line.end)

        let ported = WorkflowFlowLayout.curve(
            from: CGRect(x: 0, y: 0, width: 100, height: 40), to: CGRect(x: 200, y: 60, width: 100, height: 40),
            inset: 5)
        #expect(ported.start == CGPoint(x: 105, y: 20))
        #expect(ported.end == CGPoint(x: 195, y: 80))
    }

    // MARK: - Runs

    @Test func notTaken_marksSkippedStepsAndStepsAFinishedRunNeverReached() {
        let def = WF.intake()
        let finished = Self.run(
            def, status: .completed, ["classify": .done, "onboard": .done, "lookup": .skipped, "notify": .done])
        #expect(WorkflowFlowLayout.notTaken(def, run: finished) == ["lookup"])

        let stopped = Self.run(def, status: .failed, ["classify": .done, "onboard": .failed])
        #expect(WorkflowFlowLayout.notTaken(def, run: stopped) == ["lookup", "notify"])
    }

    @Test func notTaken_leavesPendingStepsAloneWhileTheRunGoes() {
        let def = WF.intake()
        let going = Self.run(def, status: .running, ["classify": .done, "onboard": .running, "lookup": .skipped])
        #expect(WorkflowFlowLayout.notTaken(def, run: going) == ["lookup"])
        #expect(WorkflowFlowLayout.notTaken(def, run: nil).isEmpty)
    }

    // MARK: - Words and search

    @Test func branchLines_wordConditionsAndStaySilentForAPlainChain() {
        let def = WF.intake()
        let lines = WorkflowFlowLayout.branchLines(def.node("classify")!, in: def)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("If ") })
        #expect(lines[0].hasSuffix("Onboard"))
        #expect(WorkflowFlowLayout.branchLines(def.node("onboard")!, in: def).isEmpty)
    }

    @Test func matches_findStepsByNameInRowOrderIgnoringCase() {
        let def = WF.intake()
        let rows = WorkflowFlowLayout.rows(def)
        #expect(WorkflowFlowLayout.matches("LOOK", in: def, rows: rows) == ["lookup"])
        #expect(WorkflowFlowLayout.matches("  ", in: def, rows: rows).isEmpty)
        let all = WorkflowFlowLayout.matches("o", in: def, rows: rows)
        #expect(all == rows.flatMap { $0 }.filter { all.contains($0) })
    }
}
