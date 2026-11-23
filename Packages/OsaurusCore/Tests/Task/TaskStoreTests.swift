//
//  TaskStoreTests.swift
//  osaurusTests
//
//  The task store over an in-memory database: journal sequence, terminal
//  stickiness, optimistic versions, queue CRUD, history reads, and launch
//  recovery of tasks the last run left open.
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@MainActor
struct TaskStoreTests {
    static func persistentStore() async throws -> (TaskStore, TaskDatabase) {
        let database = TaskDatabase()
        try database.openInMemory()
        let store = TaskStore(database: database)
        await store.start()
        return (store, database)
    }

    static func task(
        title: String = "Task", queueId: UUID = TaskQueue.defaultID, parentId: UUID? = nil, agentId: UUID? = nil,
        origin: TaskOrigin = .manual, state: TaskState = .running
    ) -> OsaurusTask {
        OsaurusTask(
            title: title, parentId: parentId, queueId: queueId, origin: origin, createdBy: .user,
            work: .agentTurn(AgentTurnWork(agentId: agentId, source: .chat)), state: state)
    }

    @Test func journalSequenceIsPerTaskAndOrdered() async {
        let store = TaskStore(database: nil)
        let a = Self.task()
        let b = Self.task()
        store.record(a, event: TaskEvent(taskId: a.id, kind: .started))
        store.record(b, event: TaskEvent(taskId: b.id, kind: .started))
        store.journal(a.id, .progress, reason: "half")
        store.journal(a.id, .finished)

        let events = await store.events(for: a.id)
        #expect(events.map(\.seq) == [1, 2, 3])
        #expect(events.map(\.kind) == [.started, .progress, .finished])
        #expect(await store.events(for: b.id).map(\.seq) == [1])
    }

    @Test func finishedTasksStayFinished() {
        let store = TaskStore(database: nil)
        let task = Self.task()
        store.record(task)
        store.transition(task.id, to: .succeeded, kind: .finished)
        let late = store.transition(task.id, to: .failed, kind: .finished, reason: "late")

        #expect(late?.state == .succeeded)
        #expect(store.task(id: task.id)?.reason == nil)
        #expect(store.live[task.id] == nil)
        #expect(store.recent.first?.id == task.id)
        #expect(store.task(id: task.id)?.finishedAt != nil)
    }

    @Test func staleVersionWritesAreRefused() {
        let store = TaskStore(database: nil)
        let task = Self.task()
        store.record(task)
        let version = store.task(id: task.id)!.version
        #expect(store.update(task.id, expectedVersion: version) { $0.progressNote = "one" } != nil)
        #expect(store.update(task.id, expectedVersion: version) { $0.progressNote = "two" } == nil)
        #expect(store.task(id: task.id)?.progressNote == "one")
    }

    @Test func heartbeatLeasesAndStalenessFollowsTheLease() {
        let store = TaskStore(database: nil)
        let task = Self.task()
        store.record(task)
        store.heartbeat(task.id, owner: "worker", note: "step 1")
        let leased = store.task(id: task.id)!
        #expect(leased.lease?.owner == "worker")
        #expect(leased.progressNote == "step 1")
        #expect(!leased.isStale())
        #expect(leased.isStale(at: Date().addingTimeInterval(TaskLease.staleAfter + 1)))
    }

    @Test func queueCreateUpdateDelete() {
        let store = TaskStore(database: nil)
        let created = store.createQueue(name: "Research")
        let duplicate = store.createQueue(name: "Research")
        #expect(created.slug == "research")
        #expect(duplicate.slug == "research-2")
        #expect(store.queue(named: "RESEARCH")?.id == created.id)
        #expect(store.queues.first?.isDefault == true)

        var edited = created
        edited.policy.maxConcurrent = 3
        store.updateQueue(edited)
        #expect(store.policy(for: created.id).maxConcurrent == 3)

        let waiting = Self.task(queueId: created.id, state: .queued)
        store.record(waiting)
        #expect(store.deleteQueue(id: created.id))
        #expect(store.queue(id: created.id) == nil)
        #expect(store.task(id: waiting.id)?.queueId == TaskQueue.defaultID)
        #expect(store.policy(for: created.id) == store.defaultQueue.policy)
    }

    @Test func defaultQueueCannotBeDeletedOrRenamedAway() {
        let store = TaskStore(database: nil)
        #expect(!store.deleteQueue(id: TaskQueue.defaultID))
        var renamed = store.defaultQueue
        renamed.slug = "other"
        renamed.policy.paused = true
        store.updateQueue(renamed)
        #expect(store.defaultQueue.slug != "other")
        #expect(store.defaultQueue.policy.paused)
    }

    @Test func historyQueriesMergeStoredAndLiveRows() async throws {
        let (store, _) = try await Self.persistentStore()
        let parent = Self.task(title: "Parent")
        let child = Self.task(title: "Child", parentId: parent.id)
        let agentId = UUID()
        let agentTask = Self.task(title: "Agent", agentId: agentId, origin: .automation, state: .failed)
        store.record(parent)
        store.record(child)
        store.record(agentTask)

        #expect(await store.tasks(TaskQuery(parentId: parent.id)).map(\.id) == [child.id])
        #expect(await store.tasks(TaskQuery(agentId: agentId)).map(\.id) == [agentTask.id])
        #expect(await store.tasks(TaskQuery(origin: .automation)).map(\.id) == [agentTask.id])
        #expect(await store.tasks(TaskQuery(states: [.failed])).map(\.id) == [agentTask.id])
        #expect(await store.loadTask(id: child.id)?.title == "Child")
    }

    @Test func tasksAChatStartedAreFoundByTheChat() async throws {
        let (store, database) = try await Self.persistentStore()
        let chat = UUID()
        var fromChat = Self.task(title: "From chat")
        fromChat.originSessionId = chat
        store.record(fromChat)
        store.record(Self.task(title: "Unattended"))

        #expect(store.originSessionIds == [chat])
        #expect(await store.tasks(TaskQuery(originSessionId: chat)).map(\.id) == [fromChat.id])
        #expect(TaskQuery(originSessionId: chat).matches(fromChat))
        #expect(!TaskQuery(originSessionId: UUID()).matches(fromChat))

        store.flush()
        let relaunched = TaskStore(database: database)
        await relaunched.start()
        #expect(relaunched.originSessionIds == [chat])
    }

    @Test func queueChoiceAppearsOnlyWithASecondQueue() {
        let store = TaskStore(database: nil)
        #expect(!store.hasMultipleQueues)
        let extra = store.createQueue(name: "Overnight")
        #expect(store.hasMultipleQueues)
        #expect(store.deleteQueue(id: extra.id))
        #expect(!store.hasMultipleQueues)
    }

    /// A file an older build wrote (schema v2, no `origin_session_id`)
    /// gains the column; its rows read back with no chat.
    @Test func schemaV2FileGainsTheChatColumn() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-v2-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = Self.task(title: "Before the upgrade", state: .succeeded)
        let json = String(decoding: try TaskDatabase.encoder.encode(old), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        let seed = try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: false)
        for sql in [
            """
            CREATE TABLE tasks (id TEXT PRIMARY KEY, queue_id TEXT NOT NULL, root_id TEXT NOT NULL,
                parent_id TEXT, subscription_id TEXT, agent_id TEXT, workflow_id TEXT, origin TEXT NOT NULL,
                state TEXT NOT NULL, idempotency_key TEXT, created_at REAL NOT NULL, finished_at REAL,
                record_json TEXT NOT NULL)
            """,
            """
            INSERT INTO tasks (id, queue_id, root_id, origin, state, created_at, record_json)
            VALUES ('\(old.id.uuidString)', '\(old.queueId.uuidString)', '\(old.rootId.uuidString)',
                '\(old.origin.rawValue)', '\(old.state.rawValue)', \(old.createdAt.timeIntervalSince1970), '\(json)')
            """,
            "PRAGMA user_version = 2",
        ] {
            #expect(sqlite3_exec(seed, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        sqlite3_close(seed)

        let database = TaskDatabase()
        try database.openPlaintextForTesting(path: path)
        defer { database.close() }
        #expect(try database.task(id: old.id)?.title == "Before the upgrade")
        #expect(try database.task(id: old.id)?.originSessionId == nil)
        #expect(try database.originSessionIds().isEmpty)

        let chat = UUID()
        var fromChat = Self.task(title: "After")
        fromChat.originSessionId = chat
        try database.upsertTasks([fromChat])
        #expect(try database.tasks(TaskQuery(originSessionId: chat)).map(\.id) == [fromChat.id])
        #expect(try database.originSessionIds() == [chat])
    }

    /// Encrypting or decrypting with an older build reset `user_version` to
    /// 0 on a current file. It still opens, keeps its rows, and is v3 again.
    @Test func currentFileWithResetSchemaVersionStillOpens() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasks-reset-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chat = UUID()
        var kept = Self.task(title: "Kept")
        kept.originSessionId = chat

        let first = TaskDatabase()
        try first.openPlaintextForTesting(path: path)
        try first.upsertTasks([kept])
        first.close()
        let reset = try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: false)
        #expect(sqlite3_exec(reset, "PRAGMA user_version = 0", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(reset)

        let reopened = TaskDatabase()
        try reopened.openPlaintextForTesting(path: path)
        defer { reopened.close() }
        #expect(try reopened.task(id: kept.id)?.originSessionId == chat)

        let check = try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: false)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 3)
        sqlite3_finalize(stmt)
    }

    @Test func loadTaskReadsHistoryPastTheHotCache() async throws {
        let (store, database) = try await Self.persistentStore()
        var old = Self.task(title: "Old", state: .succeeded)
        old.finishedAt = Date()
        try database.upsertTasks([old])

        #expect(store.task(id: old.id) == nil)
        #expect(await store.loadTask(id: old.id)?.title == "Old")
    }

    @Test func launchClosesWhatTheLastRunLeftOpen() async throws {
        let database = TaskDatabase()
        try database.openInMemory()
        let running = Self.task(title: "Running", state: .running)
        let waiting = Self.task(title: "Waiting", state: .queued)
        try database.upsertTasks([running, waiting])

        let store = TaskStore(database: database)
        await store.start()

        #expect(store.task(id: running.id)?.state == .interrupted)
        #expect(store.task(id: running.id)?.reason == "interrupted")
        #expect(store.task(id: waiting.id)?.state == .cancelled)
        #expect(store.live.isEmpty)
        #expect(await store.events(for: running.id).last?.kind == .finished)
    }

    @Test func defaultQueueSeedsFromTheSavedLimitOnce() async throws {
        let database = TaskDatabase()
        try database.openInMemory()
        let first = TaskStore(database: database)
        await first.start(seedMaxConcurrent: 7)
        #expect(first.defaultQueue.policy.maxConcurrent == 7)
        first.flush()

        let second = TaskStore(database: database)
        await second.start(seedMaxConcurrent: 2)
        #expect(second.defaultQueue.policy.maxConcurrent == 7)
    }

    @Test func pruneDropsOldFinishedRowsAndTheirJournal() throws {
        let database = TaskDatabase()
        try database.openInMemory()
        var old = Self.task(title: "Old", state: .succeeded)
        old.finishedAt = Date().addingTimeInterval(-(TaskDatabase.retentionDays + 1) * 86_400)
        var fresh = Self.task(title: "Fresh", state: .succeeded)
        fresh.finishedAt = Date()
        let open = Self.task(title: "Open", state: .running)
        try database.upsertTasks([old, fresh, open])
        try database.appendEvents([TaskEvent(taskId: old.id, kind: .finished)])

        try database.prune()

        #expect(try database.task(id: old.id) == nil)
        #expect(try database.events(taskId: old.id).isEmpty)
        #expect(try database.task(id: fresh.id) != nil)
        #expect(try database.task(id: open.id) != nil)
    }

    @Test func deletingAnAutomationsTasksClearsTheBoard() async throws {
        let (store, _) = try await Self.persistentStore()
        let subscription = UUID()
        var task = Self.task(origin: .automation, state: .succeeded)
        task.subscriptionId = subscription
        store.record(task)
        store.deleteTasks(subscriptionId: subscription)
        #expect(store.task(id: task.id) == nil)
        #expect(await store.tasks(TaskQuery(subscriptionId: subscription)).isEmpty)
    }

    @Test func storeThatCouldNotOpenWritesThroughOnceReattached() async throws {
        let database = TaskDatabase()
        database.refusesOpenForTesting = true
        let store = TaskStore(database: database)
        await store.start()
        let queue = store.createQueue(name: "Overnight")
        let running = Self.task(queueId: queue.id)
        let finished = Self.task(title: "Done")
        store.record(running, event: TaskEvent(taskId: running.id, kind: .started))
        store.record(finished)
        store.transition(finished.id, to: .succeeded, kind: .finished)
        #expect(!store.importOnce("probe") { [] })

        database.refusesOpenForTesting = false
        try database.openInMemory()
        #expect(await store.reattach())

        #expect(try database.queues().contains { $0.id == queue.id })
        let stored = try database.tasks(TaskQuery())
        #expect(Set(stored.map(\.id)) == [running.id, finished.id])
        #expect(try database.events(taskId: running.id).map(\.kind) == [.started])
        #expect(store.recent.contains { $0.id == finished.id })
        #expect(store.importOnce("probe") { [] })
    }

    @Test func heartbeatsDoNotMoveTheRevision() {
        let store = TaskStore(database: nil)
        let task = Self.task()
        store.record(task)
        store.heartbeat(task.id, owner: "test")
        let afterLease = store.revision
        store.heartbeat(task.id, owner: "test")
        #expect(store.revision == afterLease)
        #expect(store.live[task.id]?.lease != nil)
        store.heartbeat(task.id, owner: "test", note: "Step 2 of 3")
        #expect(store.revision == afterLease + 1)
        store.transition(task.id, to: .succeeded, kind: .finished)
        #expect(store.revision > afterLease + 1)
    }

    @Test func workflowKeepaliveRenewsTheOwningTask() {
        let store = TaskStore(database: nil)
        let previous = WorkflowTaskRecorder.store
        WorkflowTaskRecorder.store = store
        defer { WorkflowTaskRecorder.store = previous }
        let owner = Self.task(origin: .automation)
        store.record(owner)
        WorkflowTaskRecorder.alive(runID: UUID(), ownerTaskId: owner.id)
        #expect(store.live[owner.id]?.lease?.owner == "workflow")

        let queued = Self.task(state: .queued)
        store.record(queued)
        WorkflowTaskRecorder.alive(runID: queued.id, ownerTaskId: nil)
        #expect(store.live[queued.id]?.lease == nil)
    }

    @Test func journalKeepsTheFirstAndNewestRowsPerTask() throws {
        let database = TaskDatabase()
        try database.openInMemory()
        let taskId = UUID()
        let total = TaskDatabase.journalRowsPerTask + 5
        for chunk in stride(from: 1, through: total, by: 100) {
            let events = (chunk...min(chunk + 99, total)).map { seq -> TaskEvent in
                var event = TaskEvent(taskId: taskId, kind: seq == 1 ? .enqueued : .progress)
                event.seq = seq
                return event
            }
            try database.appendEvents(events)
        }
        let kept = try database.events(taskId: taskId)
        #expect(kept.count == TaskDatabase.journalRowsPerTask)
        #expect(kept.first?.seq == 1)
        #expect(kept.first?.kind == .enqueued)
        #expect(kept.dropFirst().first?.seq == total - TaskDatabase.journalRowsPerTask + 2)
        #expect(kept.last?.seq == total)
    }
}
