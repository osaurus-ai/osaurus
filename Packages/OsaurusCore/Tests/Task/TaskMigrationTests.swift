//
//  TaskMigrationTests.swift
//  osaurusTests
//
//  The import of legacy `agent_runs` rows as finished tasks: field mapping,
//  automation runs left to the `event_runs` import, and the table retired
//  (renamed, rows kept, recreated empty for older builds) only after the
//  import commits.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct TaskMigrationTests {
    static func run(
        _ kind: AgentRunTriggerKind, status: AgentRunStatus, instructions: String = "Check the inbox\nthen reply",
        error: String? = nil
    ) -> AgentRunRecord {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        return AgentRunRecord(
            id: UUID(), agentId: UUID(), triggerKind: kind, instructions: instructions, startedAt: started,
            endedAt: status == .running ? nil : started.addingTimeInterval(30), status: status, tokensIn: 12,
            error: error)
    }

    @Test func selfScheduledRunsBecomeAgentOwnedTasks() throws {
        let run = Self.run(.schedule, status: .success)
        let task = try #require(TaskMigration.task(from: run))
        #expect(task.id == run.id)
        #expect(task.origin == .selfSchedule)
        #expect(task.createdBy == .agent(run.agentId))
        #expect(task.agentId == run.agentId)
        #expect(task.state == .succeeded)
        #expect(task.title == "Check the inbox")
        #expect(task.startedAt == run.startedAt)
        #expect(task.finishedAt == run.endedAt)
        #expect(task.result?.tokensIn == 12)
    }

    @Test func statusesMapToTaskStates() throws {
        let cases: [(AgentRunStatus, TaskState)] = [
            (.success, .succeeded), (.error, .failed), (.cancelled, .cancelled), (.clamped, .suppressed),
            (.running, .interrupted),
        ]
        for (status, state) in cases {
            let task = try #require(TaskMigration.task(from: Self.run(.user, status: status, error: "boom")))
            #expect(task.state == state)
            #expect(task.origin == .manual)
            #expect(task.lastError == "boom")
            #expect(task.state.isTerminal)
            #expect(task.finishedAt != nil)
        }
        let running = try #require(TaskMigration.task(from: Self.run(.user, status: .running)))
        #expect(running.reason == "interrupted")
    }

    @Test func automationRunsAreLeftToTheEventRunsImport() {
        for kind in [AgentRunTriggerKind.recurringSchedule, .watcher, .webhook, .email, .automation] {
            #expect(TaskMigration.task(from: Self.run(kind, status: .success)) == nil)
        }
    }

    @Test func importRetiresTheLegacyTableAndPicksUpDowngradeRows() async throws {
        let schedulerDB = SchedulerDatabase()
        try schedulerDB.openInMemory()
        let runs = [Self.run(.schedule, status: .success), Self.run(.user, status: .error), Self.run(.watcher, status: .success)]
        try schedulerDB.seedLegacyRunsForTesting(runs)
        #expect(try schedulerDB.legacyRuns(limit: 10).count == 3)

        let taskDB = TaskDatabase()
        try taskDB.openInMemory()
        let store = TaskStore(database: taskDB)
        await store.start()

        await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
        let imported = await store.tasks(TaskQuery())
        #expect(Set(imported.map(\.id)) == Set(runs.prefix(2).map(\.id)))
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)
        #expect(try schedulerDB.rowCountForTesting("agent_runs_legacy") == 3)
        #expect(store.didImportForTesting(TaskMigration.agentRunsKey))

        await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)
        #expect(await store.tasks(TaskQuery()).count == 2)

        let afterDowngrade = Self.run(.schedule, status: .success)
        try schedulerDB.seedLegacyRunsForTesting([afterDowngrade])
        await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
        #expect(await store.tasks(TaskQuery()).contains { $0.id == afterDowngrade.id })
        #expect(await store.tasks(TaskQuery()).count == 3)
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)
    }

    @Test func freshInstallNeverCreatesTheSchedulerStore() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-task-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
            }
            let taskDB = TaskDatabase()
            try taskDB.openInMemory()
            let store = TaskStore(database: taskDB)
            await store.start()

            let schedulerDB = SchedulerDatabase()
            await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
            #expect(!schedulerDB.isOpen)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.schedulerDatabaseFile().path))
            #expect(!store.didImportForTesting(TaskMigration.agentRunsKey))
        }
    }

    @Test func failedImportKeepsTheLegacyTableForTheNextLaunch() async throws {
        let schedulerDB = SchedulerDatabase()
        try schedulerDB.openInMemory()
        let runs = [Self.run(.schedule, status: .success), Self.run(.user, status: .success)]
        try schedulerDB.seedLegacyRunsForTesting(runs)

        let taskDB = TaskDatabase()
        try taskDB.openInMemory()
        let store = TaskStore(database: taskDB)
        await store.start()
        taskDB.close()

        await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
        #expect(try schedulerDB.legacyRuns(limit: 10).count == 2)
        #expect(try schedulerDB.rowCountForTesting("agent_runs_legacy") == nil)
        #expect(!store.didImportForTesting(TaskMigration.agentRunsKey))

        try taskDB.openInMemory()
        await TaskMigration.importAgentRuns(into: store, database: schedulerDB)
        #expect(try schedulerDB.legacyRuns(limit: 10).isEmpty)
        #expect(store.didImportForTesting(TaskMigration.agentRunsKey))
        #expect(Set(try taskDB.tasks(TaskQuery()).map(\.id)) == Set(runs.map(\.id)))
    }

    @Test func retiringTwiceKeepsBothCopies() throws {
        let schedulerDB = SchedulerDatabase()
        try schedulerDB.openInMemory()
        try schedulerDB.seedLegacyRunsForTesting([Self.run(.user, status: .success)])
        try schedulerDB.retireLegacyTable("agent_runs")
        try schedulerDB.seedLegacyRunsForTesting([Self.run(.user, status: .success), Self.run(.user, status: .error)])
        try schedulerDB.retireLegacyTable("agent_runs")
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)
        #expect(try schedulerDB.rowCountForTesting("agent_runs_legacy") == 1)
        #expect(try schedulerDB.legacyRuns(limit: 10).isEmpty)
    }

    @Test func retiredTablesAreRecreatedEmptyForOlderBuilds() throws {
        let schedulerDB = SchedulerDatabase()
        try schedulerDB.openInMemory()
        try schedulerDB.seedLegacyRunsForTesting([Self.run(.user, status: .success)])
        try schedulerDB.retireLegacyTable("agent_runs")
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)

        try schedulerDB.seedLegacyRunsForTesting([Self.run(.user, status: .error)])
        #expect(try schedulerDB.legacyRuns(limit: 10).count == 1)
    }

    @Test func emptyTablesAreNotRetired() throws {
        let schedulerDB = SchedulerDatabase()
        try schedulerDB.openInMemory()
        try schedulerDB.seedLegacyRunsForTesting([])
        try schedulerDB.retireLegacyTable("agent_runs")
        try schedulerDB.retireLegacyTable("agent_next_run")
        #expect(try schedulerDB.rowCountForTesting("agent_runs") == 0)
        #expect(try schedulerDB.rowCountForTesting("agent_runs_legacy") == nil)
        #expect(try schedulerDB.rowCountForTesting("agent_next_run") == nil)
    }
}
