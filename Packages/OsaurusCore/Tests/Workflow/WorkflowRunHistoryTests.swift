//
//  WorkflowRunHistoryTests.swift
//  OsaurusCoreTests
//
//  The History lens's Runs tab: which runs each agent sees, the recent-runs
//  query and its live overlay, day grouping, filters, and how a run reads.
//

import Foundation
import Testing

@testable import OsaurusCore

private func makeRun(
    workflowID: UUID = UUID(),
    name: String = "Intake",
    caller: WorkflowCaller = WorkflowCaller(kind: .user),
    status: WorkflowRunStatus = .completed,
    startedAt: Date = Date(timeIntervalSince1970: 1_000),
    nodeIDs: [String] = ["a", "b"]
) -> WorkflowRun {
    var run = WorkflowRun(
        workflowID: workflowID,
        workflowName: name,
        templateID: UUID(),
        templateVersion: 1,
        caller: caller,
        input: .object([:]),
        nodeIDs: nodeIDs,
        startedAt: startedAt
    )
    run.status = status
    return run
}

@Suite
struct WorkflowRunHistoryScopeTests {
    private typealias Model = WorkflowRunHistoryModel

    @Test
    func architectSeesEveryRunButTests() {
        let agentRun = makeRun(caller: WorkflowCaller(kind: .agent, agentID: UUID()))
        let userRun = makeRun()
        let test = makeRun(caller: WorkflowCaller(kind: .test))
        let shown = Model.scope([agentRun, userRun, test], agentId: Agent.architectId, agentWorkflowIDs: [])
        #expect(shown.map(\.id) == [agentRun.id, userRun.id])
    }

    @Test
    func customAgentSeesItsOwnRunsAndItsWorkflowsRuns() {
        let agent = UUID()
        let other = UUID()
        let mineWorkflow = UUID()
        let started = makeRun(caller: WorkflowCaller(kind: .agent, agentID: agent))
        let ofMyWorkflow = makeRun(workflowID: mineWorkflow, caller: WorkflowCaller(kind: .agent, agentID: other))
        let unrelated = makeRun(caller: WorkflowCaller(kind: .agent, agentID: other))
        let myTest = makeRun(workflowID: mineWorkflow, caller: WorkflowCaller(kind: .test))
        let shown = Model.scope(
            [started, ofMyWorkflow, unrelated, myTest],
            agentId: agent,
            agentWorkflowIDs: [mineWorkflow]
        )
        #expect(shown.map(\.id) == [started.id, ofMyWorkflow.id])
    }

    @Test
    func orchestratorOwnsRunsWithNoAgent() {
        let anonymous = makeRun(caller: WorkflowCaller(kind: .user))
        let orchestrated = makeRun(caller: WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId))
        let custom = makeRun(caller: WorkflowCaller(kind: .agent, agentID: UUID()))
        let shown = Model.scope([anonymous, orchestrated, custom], agentId: Agent.defaultId, agentWorkflowIDs: [])
        #expect(shown.map(\.id) == [anonymous.id, orchestrated.id])
    }
}

@Suite
@MainActor
struct WorkflowRunHistoryListTests {
    private typealias Model = WorkflowRunHistoryModel

    @Test
    func daysBucketByCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        func ago(days: Int, hours: Int = 1) -> Date {
            calendar.date(byAdding: .hour, value: hours, to: calendar.date(byAdding: .day, value: -days, to: today)!)!
        }
        #expect(Model.day(of: ago(days: 0), now: now, calendar: calendar) == .today)
        #expect(Model.day(of: ago(days: 1), now: now, calendar: calendar) == .yesterday)
        #expect(Model.day(of: ago(days: 6), now: now, calendar: calendar) == .thisWeek)
        #expect(Model.day(of: ago(days: 7), now: now, calendar: calendar) == .older)

        let runs = [ago(days: 7), ago(days: 0, hours: 1), ago(days: 0, hours: 3), ago(days: 2)].map {
            makeRun(startedAt: $0)
        }
        let sections = Model.sections(runs, now: now, calendar: calendar)
        #expect(sections.map(\.day) == [.today, .thisWeek, .older])
        #expect(sections[0].runs.map(\.id) == [runs[2].id, runs[1].id])
    }

    @Test
    func filtersByStatusWorkflowAndSearch() {
        let wf = UUID()
        let failed = makeRun(workflowID: wf, name: "Invoice Sender", status: .failed)
        let waiting = makeRun(name: "Social Post", status: .awaitingUser)
        let setup = makeRun(name: "Social Post", status: .needsSetup)
        let done = makeRun(workflowID: wf, name: "Invoice Sender", status: .completed)
        let all = [failed, waiting, setup, done]
        func ids(_ status: Model.StatusFilter, _ workflow: UUID? = nil, _ query: String = "") -> [UUID] {
            Model.filter(all, status: status, workflowID: workflow, query: query) { $0.workflowName }.map(\.id)
        }
        #expect(ids(.all).count == 4)
        #expect(ids(.needsYou) == [waiting.id, setup.id])
        #expect(ids(.failed) == [failed.id])
        #expect(ids(.all, wf) == [failed.id, done.id])
        #expect(ids(.completed, wf) == [done.id])
        #expect(ids(.all, nil, "invoice") == [failed.id, done.id])

        let choices = Model.workflowChoices(all)
        #expect(choices.map(\.name) == ["Invoice Sender", "Social Post", "Social Post"])
        #expect(choices.first { $0.id == wf }?.count == 2)
    }

    @Test
    func outcomeAndStartedByReadPlainly() {
        var running = makeRun(status: .running, nodeIDs: ["a", "b", "c"])
        running.nodes[0].status = .done
        running.nodes[1].status = .skipped
        #expect(Model.outcome(running, definition: nil) == "2 of 3 steps")

        var failed = makeRun(status: .failed)
        failed.error = WorkflowRunError(nodeID: "download", reason: "timed out")
        #expect(Model.outcome(failed, definition: nil) == "Failed at a step")
        #expect(Model.fixPrompt(failed, definition: nil).contains("“download”"))
        #expect(Model.fixPrompt(failed, definition: nil).contains("timed out"))

        var done = makeRun(status: .completed)
        done.output = .string("First line\nSecond line")
        #expect(Model.outcome(done, definition: nil) == "First line")

        let agent = UUID()
        let byAgent = makeRun(caller: WorkflowCaller(kind: .agent, agentID: agent, agentName: "Old Name"))
        #expect(Model.startedBy(byAgent) { $0 == agent ? "Scout" : nil } == "Scout")
        #expect(Model.startedBy(byAgent) { _ in nil } == "Old Name")
        #expect(Model.startedBy(makeRun()) { _ in nil } == "You")
        let scheduled = makeRun(caller: WorkflowCaller(kind: .agent, agentID: agent, isUnattendedDispatch: true))
        #expect(Model.startedBy(scheduled) { _ in "Scout" } == "Scheduled")
    }

    @Test
    func runsBadgePrefersAttentionOverActivity() {
        #expect(ChatHistoryPaneView.runsBadge([makeRun()]) == nil)
        #expect(ChatHistoryPaneView.runsBadge([makeRun(status: .running)]) == .activity)
        #expect(
            ChatHistoryPaneView.runsBadge([makeRun(status: .running), makeRun(status: .awaitingUser)]) == .attention
        )
    }
}

@Suite
@MainActor
struct WorkflowRunHistoryStoreTests {
    @Test
    func recentRunsSpanWorkflowsNewestFirstWithoutTests() throws {
        let db = WorkflowRunDatabase()
        try db.openInMemory()
        let old = makeRun(startedAt: Date(timeIntervalSince1970: 1_000))
        let new = makeRun(startedAt: Date(timeIntervalSince1970: 2_000))
        let test = makeRun(caller: WorkflowCaller(kind: .test), startedAt: Date(timeIntervalSince1970: 3_000))
        for run in [old, test, new] { try db.upsert(run) }
        #expect(try db.recentRuns().map(\.id) == [new.id, old.id])
        #expect(try db.recentRuns(limit: 1).map(\.id) == [new.id])
    }

    /// Generated images live in each run's files folder; dropping a run
    /// (trimmed test, retention, deleted draft) must take them with it.
    @Test
    func droppedRunsTakeTheirFilesWithThem() throws {
        let db = WorkflowRunDatabase()
        try db.openInMemory()
        let store = WorkflowRunStore(database: db)
        let workflowID = UUID()
        func files(_ run: WorkflowRun) throws -> URL {
            let dir = OsaurusPaths.workflowRunArtifacts(workflowID: workflowID, runID: run.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: dir.appendingPathComponent("a.png"))
            return dir
        }
        let done = makeRun(workflowID: workflowID, startedAt: Date(timeIntervalSince1970: 1_000))
        let going = makeRun(workflowID: workflowID, status: .running, startedAt: Date(timeIntervalSince1970: 2_000))
        store.record(done)
        store.record(going)
        let doneFiles = try files(done)
        let goingFiles = try files(going)

        store.deleteRuns(ids: [done.id, going.id])
        #expect(!FileManager.default.fileExists(atPath: doneFiles.path))
        #expect(store.run(id: done.id) == nil)
        #expect(FileManager.default.fileExists(atPath: goingFiles.path))
        #expect(store.run(id: going.id) != nil)

        // Past retention, the oldest run's record and files go together.
        var oldest = makeRun(workflowID: workflowID, startedAt: Date(timeIntervalSince1970: 0))
        oldest.status = .completed
        store.record(oldest)
        let oldestFiles = try files(oldest)
        for i in 0 ..< WorkflowRunDatabase.retentionPerWorkflow {
            store.record(makeRun(workflowID: workflowID, startedAt: Date(timeIntervalSince1970: 10_000 + Double(i))))
        }
        #expect(!FileManager.default.fileExists(atPath: oldestFiles.path))
        #expect(try db.run(id: oldest.id) == nil)
        try? FileManager.default.removeItem(at: OsaurusPaths.workflowDirectory(workflowID))
    }

    @Test
    func liveRunsOverlayPersistedOnes() async throws {
        let db = WorkflowRunDatabase()
        try db.openInMemory()
        let store = WorkflowRunStore(database: db)
        var run = makeRun(status: .running, startedAt: Date(timeIntervalSince1970: 1_000))
        try db.upsert(run)
        #expect(store.recentPersisted == nil)
        await store.loadRecentRunsIfNeeded()
        #expect(store.recentPersisted?.map(\.status) == [.running])

        run.status = .completed
        store.record(run)
        let fresh = makeRun(startedAt: Date(timeIntervalSince1970: 2_000))
        store.record(fresh)
        store.record(makeRun(caller: WorkflowCaller(kind: .test), startedAt: Date(timeIntervalSince1970: 3_000)))

        let merged = store.recentRuns()
        #expect(merged.map(\.id) == [fresh.id, run.id])
        #expect(merged.last?.status == .completed)

        // Loaded once a launch: later loads keep the snapshot rather than
        // reloading it under a list on screen.
        try db.upsert(makeRun(startedAt: Date(timeIntervalSince1970: 4_000)))
        await store.loadRecentRunsIfNeeded()
        #expect(store.recentPersisted?.count == 1)

        store.deleteRuns(workflowID: run.workflowID)
        #expect(store.recentRuns().map(\.id) == [fresh.id])
    }

    @Test
    func listItemsInterleaveDayHeadersWithStableIDs() {
        let a = makeRun()
        let b = makeRun()
        let items = WorkflowRunHistoryModel.items([.init(day: .today, runs: [a]), .init(day: .older, runs: [b])])
        #expect(items.map(\.id) == ["day-0", a.id.uuidString, "day-3", b.id.uuidString])
    }
}
