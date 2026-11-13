//
//  EventPipelineTests.swift
//  osaurusTests
//
//  The shared event pipeline: lanes on the task scheduler, the run ledger, admission
//  (disabled / filtered / duplicate / unavailable agent), cancellation,
//  interrupted-run cleanup, missed schedule slots, and folder convergence.
//  Runs go through a fake action runner; nothing reaches a model.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
final class FakeEventRunner {
    var fired: [EventOccurrence] = []
    var hold = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    var onRun: (@MainActor (EventOccurrence) -> Void)?

    func install(on manager: EventManager, status: EventRunStatus = .succeeded) {
        manager.targetLookup = EventTargetLookup(agentExists: { _ in true })
        manager.runAction = { _, _, occurrence, _ in
            self.fired.append(occurrence)
            self.onRun?(occurrence)
            if self.hold { await withCheckedContinuation { self.gate.append($0) } }
            return TaskOutcome(status: TaskState(status))
        }
    }

    func release() {
        hold = false
        for waiter in gate { waiter.resume() }
        gate.removeAll()
    }

    func waitForFires(_ count: Int) async {
        for _ in 0 ..< 500 where fired.count < count { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

@MainActor
enum EventPipelineFixtures {
    static func manager() throws -> (EventManager, FakeEventRunner) {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let runner = FakeEventRunner()
        runner.install(on: manager)
        return (manager, runner)
    }

    static func agentAction(_ target: AgentDispatchTarget? = .local(UUID())) -> EventAction {
        .agent(AgentEventAction(target: target, instructions: "Do the thing"))
    }

    static func settled(_ manager: EventManager, _ runId: UUID) async -> EventRun? {
        for _ in 0 ..< 300 {
            if let run = await manager.run(id: runId), run.status.isTerminal { return run }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await manager.run(id: runId)
    }
}

// MARK: - Lanes

@MainActor
struct EventLaneTests {
    @Test func policyClampsToCeilings() {
        let policy = EventDeliveryPolicy(maxConcurrent: 99, maxQueued: 9999, dedupeWindowSeconds: -5)
        #expect(policy.maxConcurrent == EventDeliveryPolicy.maxConcurrentCeiling)
        #expect(policy.maxQueued == EventDeliveryPolicy.maxQueuedCeiling)
        #expect(policy.dedupeWindowSeconds == 0)
    }

    @Test func perConversationLanesRunSideBySide() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        runner.hold = true
        let event = manager.create(
            OsaurusEvent(
                name: "Chat", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(),
                delivery: EventDeliveryPolicy(mode: .perConversation, maxQueued: 0, dedupeWindowSeconds: 0)))
        let a = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), conversationKey: "room-a"))
        let b = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), conversationKey: "room-b"))
        let a2 = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), conversationKey: "room-a"))
        #expect(a.status == .running)
        #expect(b.status == .running)
        #expect(a2.status == .suppressed)
        #expect(a2.reason == "busy")
        await runner.waitForFires(2)
        runner.release()
        #expect(await EventPipelineFixtures.settled(manager, a.runId)?.status == .succeeded)
        #expect(await EventPipelineFixtures.settled(manager, b.runId)?.status == .succeeded)
    }
}

// MARK: - Ledger

struct EventRunDatabaseTests {
    static func row(
        _ eventId: UUID, at firedAt: Date, status: EventRunStatus = .succeeded, dedupe: String? = nil
    ) -> EventRun {
        EventRun(
            eventId: eventId, eventName: "E", sourceKind: .webhook, actionKind: .agent, firedAt: firedAt,
            status: status, dedupeKey: dedupe)
    }

    @Test func upsertReadsBackNewestFirstAndUpdatesInPlace() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let id = UUID()
        let now = Date()
        var older = Self.row(id, at: now.addingTimeInterval(-60), status: .running)
        let newer = Self.row(id, at: now)
        try db.upsert(older)
        try db.upsert(newer)
        try db.upsert(Self.row(UUID(), at: now))
        #expect(try db.runs(eventId: id).map(\.id) == [newer.id, older.id])
        #expect(try db.openRuns().map(\.id) == [older.id])

        older.status = .failed
        older.error = "boom"
        try db.upsert(older)
        #expect(try db.run(id: older.id)?.error == "boom")
        #expect(try db.runs(eventId: id).count == 2)
        #expect(try db.openRuns().isEmpty)
        #expect(try db.recentRuns(limit: 10).count == 3)

        try db.deleteRuns(eventId: id)
        #expect(try db.runs(eventId: id).isEmpty)
    }

    @Test func firstOccurrenceIgnoresRefusalsAndHonorsTheWindow() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let id = UUID()
        let now = Date()
        try db.upsert(Self.row(id, at: now, status: .duplicate, dedupe: "k"))
        try db.upsert(Self.row(id, at: now, status: .suppressed, dedupe: "k"))
        #expect(try db.firstOccurrence(eventId: id, dedupeKey: "k", since: now.addingTimeInterval(-60)) == nil)
        let real = Self.row(id, at: now.addingTimeInterval(-30), dedupe: "k")
        try db.upsert(real)
        #expect(try db.firstOccurrence(eventId: id, dedupeKey: "k", since: now.addingTimeInterval(-60))?.id == real.id)
        #expect(try db.firstOccurrence(eventId: id, dedupeKey: "k", since: now.addingTimeInterval(-10)) == nil)
        #expect(try db.firstOccurrence(eventId: id, dedupeKey: "other", since: .distantPast) == nil)
    }

    @Test func pruneKeepsThePerEventCapAndDropsOldRows() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let id = UUID()
        let now = Date()
        for i in 0 ..< EventRunDatabase.retentionPerEvent + 3 {
            try db.upsert(Self.row(id, at: now.addingTimeInterval(TimeInterval(-i))))
        }
        let other = UUID()
        let ancient = Self.row(other, at: now.addingTimeInterval(-EventRunDatabase.retentionAge - 60))
        try db.upsert(ancient)
        try db.prune(eventId: id, now: now)
        #expect(try db.runs(eventId: id, limit: 10_000).count == EventRunDatabase.retentionPerEvent)
        #expect(try db.run(id: ancient.id) == nil)
    }

    @Test func pruneAllTrimsEveryEventWithoutARun() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let now = Date()
        let busy = UUID()
        let quiet = UUID()
        for i in 0 ..< EventRunDatabase.retentionPerEvent + 2 {
            try db.upsert(Self.row(busy, at: now.addingTimeInterval(TimeInterval(-i)), status: .filtered))
        }
        let newestQuiet = Self.row(quiet, at: now)
        try db.upsert(newestQuiet)
        let ancient = Self.row(quiet, at: now.addingTimeInterval(-EventRunDatabase.retentionAge - 60))
        try db.upsert(ancient)
        try db.pruneAll(now: now)
        #expect(try db.runs(eventId: busy, limit: 10_000).count == EventRunDatabase.retentionPerEvent)
        #expect(try db.runs(eventId: quiet, limit: 10).map(\.id) == [newestQuiet.id])
    }
}

// MARK: - Admission

@MainActor
struct EventAdmissionTests {
    @Test func disabledEventsRefuseSourceFiresButFireNowStillRuns() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Off", isEnabled: false, source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction()))
        let source = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:])))
        #expect(source.status == .suppressed)
        #expect(source.reason == "disabled")
        let manual = await manager.fireNow(event.id)
        #expect(manual.status == .running)
        #expect(await EventPipelineFixtures.settled(manager, manual.runId)?.summary["trigger"] == "manual")
        #expect(runner.fired.count == 1)
    }

    @Test func agentTargetsAreCheckedBeforeTakingALane() throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let none = manager.create(
            OsaurusEvent(
                name: "No agent", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(nil)))
        #expect(manager.submit(EventOccurrence(eventId: none.id, payload: .null)).reason == "agent_not_selected")
        let builtIn = manager.create(
            OsaurusEvent(
                name: "Default", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(.local(Agent.defaultId))))
        #expect(manager.submit(EventOccurrence(eventId: builtIn.id, payload: .null)).reason == "agent_unavailable")
        #expect(runner.fired.isEmpty)
    }

    @Test func deletedTargetsAreNamedInsteadOfFailingQuietly() throws {
        let nothingExists = EventTargetLookup(
            agentExists: { _ in false }, workflowExists: { _ in false }, connectionExists: { _ in false })
        let hook = WebhookSourceConfig(verification: .none)
        let agentEvent = OsaurusEvent(name: "A", source: .webhook(hook), action: EventPipelineFixtures.agentAction())
        let workflowEvent = OsaurusEvent(
            name: "W", source: .webhook(hook), action: .workflow(WorkflowEventAction(workflowID: UUID())))
        let n8nEvent = OsaurusEvent(
            name: "N", source: .channelMessage(ChannelMessageSourceConfig(kind: .n8n, connectionId: "gone")),
            action: EventPipelineFixtures.agentAction())
        let nativeEvent = OsaurusEvent(
            name: "T", source: .channelMessage(ChannelMessageSourceConfig(kind: .telegram)),
            action: EventPipelineFixtures.agentAction())

        #expect(EventInspection.targetProblem(agentEvent, lookup: nothingExists) == .agentDeleted)
        #expect(EventInspection.targetProblem(workflowEvent, lookup: nothingExists) == .workflowDeleted)
        #expect(EventInspection.targetProblem(n8nEvent, lookup: nothingExists) == .channelDeleted)
        #expect(
            EventInspection.targetProblem(nativeEvent, lookup: EventTargetLookup(agentExists: { _ in true })) == nil,
            "native platforms are configured, never deleted")
        for problem in [EventTargetProblem.agentDeleted, .workflowDeleted, .channelDeleted] {
            #expect(
                AgentChannelInboundActivityPresentation.guidance(stage: .dispatchSuppressed, reason: problem.reason)
                    == problem.message)
        }

        let (manager, runner) = try EventPipelineFixtures.manager()
        manager.targetLookup = nothingExists
        let created = manager.create(agentEvent)
        let result = manager.submit(EventOccurrence(eventId: created.id, payload: .null))
        #expect(result.status == .suppressed)
        #expect(result.reason == "agent_deleted")
        #expect(runner.fired.isEmpty)
    }

    @Test func dedupeWindowAppliesToSourceFiresOnly() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Daily", source: .schedule(ScheduleSourceConfig(frequency: .daily(hour: 9, minute: 0))),
                action: EventPipelineFixtures.agentAction(),
                delivery: EventDeliveryPolicy(mode: .parallel, maxConcurrent: 4, dedupeWindowSeconds: 600)))
        let first = manager.submit(EventOccurrence(eventId: event.id, payload: .null, dedupeKey: "slot-1"))
        #expect(first.status == .running)
        let again = manager.submit(EventOccurrence(eventId: event.id, payload: .null, dedupeKey: "slot-1"))
        #expect(again.status == .duplicate)
        #expect(again.reason == "duplicate_of:\(first.runId.uuidString)")
        let manual = manager.submit(
            EventOccurrence(eventId: event.id, payload: .null, trigger: .manual, dedupeKey: "slot-1"))
        #expect(manual.status == .running)
        let next = manager.submit(EventOccurrence(eventId: event.id, payload: .null, dedupeKey: "slot-2"))
        #expect(next.status == .running)
        await runner.waitForFires(3)
        #expect(runner.fired.count == 3)
    }

    @Test func dedupeSurvivesAFreshManagerThroughTheLedger() async throws {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let first = EventManager(ledger: ledger, persistsToDisk: false)
        let firstRunner = FakeEventRunner()
        firstRunner.install(on: first)
        let event = first.create(
            OsaurusEvent(
                name: "Hook", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction()))
        let original = first.submit(EventOccurrence(eventId: event.id, payload: .null, dedupeKey: "d1"))
        _ = await EventPipelineFixtures.settled(first, original.runId)

        #expect(await EventPipelineFixtures.settled(first, original.runId)?.status == .succeeded)

        let second = EventManager(ledger: ledger, persistsToDisk: false)
        let secondRunner = FakeEventRunner()
        secondRunner.install(on: second)
        second.create(event)
        let redelivery = second.submit(EventOccurrence(eventId: event.id, payload: .null, dedupeKey: "d1"))
        #expect(redelivery.status == .duplicate)
        #expect(secondRunner.fired.isEmpty)
    }

    @Test func filtersRejectWithTheirReason() throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Keyword", source: .webhook(WebhookSourceConfig(verification: .none)),
                filter: EventFilter(keywordsAny: ["deploy"]), action: EventPipelineFixtures.agentAction()))
        let miss = manager.submit(EventOccurrence(eventId: event.id, payload: .object(["text": .string("hello")])))
        #expect(miss.status == .filtered)
        let hit = manager.submit(EventOccurrence(eventId: event.id, payload: .object(["text": .string("Deploy now")])))
        #expect(hit.status == .running)
        _ = runner
    }

    @Test func disablingCancelsQueuedFires() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        runner.hold = true
        let event = manager.create(
            OsaurusEvent(
                name: "Serial", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(),
                delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 5, dedupeWindowSeconds: 0)))
        let running = manager.submit(EventOccurrence(eventId: event.id, payload: .null))
        let queued = manager.submit(EventOccurrence(eventId: event.id, payload: .null))
        #expect(queued.status == .queued)
        #expect(manager.queuedCount(event.id) == 1)
        await runner.waitForFires(1)

        manager.setEnabled(event.id, enabled: false)
        let cancelled = await EventPipelineFixtures.settled(manager, queued.runId)
        #expect(cancelled?.status == .cancelled)
        #expect(cancelled?.reason == "cancelled")
        runner.release()
        #expect(await EventPipelineFixtures.settled(manager, running.runId)?.status == .succeeded)
        #expect(runner.fired.count == 1)
    }

    @Test func startClosesRunsAQuitLeftOpen() async throws {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let stale = EventRun(
            eventId: UUID(), eventName: "E", sourceKind: .schedule, actionKind: .agent, status: .running)
        try ledger.upsert(stale)
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        manager.start()
        await manager.awaitLoaded()
        manager.stop()
        let closed = await manager.run(id: stale.id)
        #expect(closed?.status == .cancelled)
        #expect(closed?.reason == "interrupted")
        #expect(closed?.finishedAt != nil)
    }

    @Test func successUpdatesTheEventsLastRunState() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Hook", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction()))
        let fired = manager.submit(EventOccurrence(eventId: event.id, payload: .null))
        _ = await EventPipelineFixtures.settled(manager, fired.runId)
        let updated = try #require(manager.event(for: event.id))
        #expect(updated.lastStatus == .succeeded)
        #expect(updated.lastRunAt != nil)
        #expect(updated.lastFiredAt != nil)
    }
}

// MARK: - Schedule source

@MainActor
struct ScheduleEventSourceTests {
    @Test func missedOneShotFiresOnceAndTurnsItselfOff() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let due = Date().addingTimeInterval(-3600)
        let event = manager.create(
            OsaurusEvent(
                name: "Once", source: .schedule(ScheduleSourceConfig(frequency: .once(date: due))),
                action: EventPipelineFixtures.agentAction()))
        manager.scheduleSource.fireMissed()
        await runner.waitForFires(1)
        #expect(runner.fired.count == 1)
        let occurrence = try #require(runner.fired.first)
        #expect(occurrence.dedupeKey == EventPayload.iso8601(due))
        #expect(occurrence.payload.value(atPath: "schedule.scheduled_for") == .string(EventPayload.iso8601(due)))
        #expect(manager.event(for: event.id)?.isEnabled == false)

        manager.scheduleSource.fireMissed()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 1)
    }

    @Test func missedSlotWithSkipPolicyIsLedgeredNotRun() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Hourly", source: .schedule(ScheduleSourceConfig(frequency: .hourly(minute: 0))),
                action: EventPipelineFixtures.agentAction(),
                delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 0, missedFirePolicy: .skip),
                lastFiredAt: Date().addingTimeInterval(-3 * 3600)))
        manager.scheduleSource.fireMissed()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty)
        let rows = await manager.runs(eventId: event.id)
        #expect(rows.map(\.reason) == ["missed_skipped"])
        let updated = try #require(manager.event(for: event.id))
        #expect(updated.lastFiredAt! > Date().addingTimeInterval(-3 * 3600 + 60))
    }

    @Test func missedRecurringSlotRunsOnce() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        _ = manager.create(
            OsaurusEvent(
                name: "Hourly", source: .schedule(ScheduleSourceConfig(frequency: .hourly(minute: 0))),
                action: EventPipelineFixtures.agentAction(),
                lastFiredAt: Date().addingTimeInterval(-5 * 3600)))
        manager.scheduleSource.fireMissed()
        await runner.waitForFires(1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.count == 1)
        #expect(runner.fired.first?.summary["scheduled_for"] != nil)
    }

    @Test func neverFiredRecurringScheduleDoesNotBackfill() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        _ = manager.create(
            OsaurusEvent(
                name: "Fresh", source: .schedule(ScheduleSourceConfig(frequency: .hourly(minute: 0))),
                action: EventPipelineFixtures.agentAction()))
        manager.scheduleSource.fireMissed()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.fired.isEmpty)
    }
}

// MARK: - Folder source

@MainActor
struct FolderEventSourceTests {
    @Test func fireNowRunsOverTheFolderThenConvergesOnTheAgentsChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evt-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("inbox.txt"))

        let (manager, runner) = try EventPipelineFixtures.manager()
        runner.onRun = { occurrence in
            if occurrence.summary["iteration"] == "1" {
                try? Data("sorted".utf8).write(to: folder.appendingPathComponent("sorted.txt"))
            }
        }
        let event = manager.create(
            OsaurusEvent(
                name: "Sorter",
                source: .folder(FolderSourceConfig(path: folder.path, responsiveness: .fast, settleSeconds: 0.05)),
                action: EventPipelineFixtures.agentAction()))

        #expect(await manager.fireNow(event.id).status == .running)
        await runner.waitForFires(2)
        for _ in 0 ..< 200 where manager.folderPhases[event.id] != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runner.fired.count == 2)
        let first = try #require(runner.fired.first)
        #expect(first.folderPath == folder.path)
        #expect(first.trigger == .manual)
        #expect(first.agentPrompt?.contains(FolderEventSource.watchedFolderLinePrefix + folder.path) == true)
        #expect(first.agentPrompt?.contains(FolderEventSource.changedSinceHeader) == false)

        let second = try #require(runner.fired.last)
        #expect(second.trigger == .source)
        #expect(second.agentPrompt?.contains("sorted.txt") == true)
        #expect(second.payload.value(atPath: "folder.changed_paths")?.arrayValue?.count == 1)
        #expect(manager.folderPhases[event.id] == nil)
    }

    @Test func aFileDroppedIntoAFolderBehindASymlinkFiresTheEvent() async throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("evt-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (manager, runner) = try EventPipelineFixtures.manager()
        manager.start()
        await manager.awaitLoaded()
        let event = manager.create(
            OsaurusEvent(
                name: "Drop",
                source: .folder(FolderSourceConfig(path: folder.path, responsiveness: .fast, settleSeconds: 0.05)),
                action: EventPipelineFixtures.agentAction()))
        defer { manager.stop() }
        #expect(manager.folderSource.canonicalPath(for: event) == "/private" + folder.path)
        await manager.folderSource.reconcile(manager.events)

        try Data("x".utf8).write(to: folder.appendingPathComponent("drop.txt"))
        for _ in 0 ..< 200 where runner.fired.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        let fired = try #require(runner.fired.first)
        #expect(fired.trigger == .source)
        #expect(fired.folderPath == folder.path)
        #expect(fired.agentPrompt?.contains("drop.txt") == true)
        #expect(fired.agentPrompt?.contains("/private") == false)
        #expect(
            fired.payload.value(atPath: "folder.changed_paths")?.arrayValue?.compactMap(\.stringValue) == ["drop.txt"])
        for _ in 0 ..< 200 where manager.folderPhases[event.id] != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func fingerprintBehindASymlinkKeepsRelativePathsAndExclusions() throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("evt-fp-\(UUID().uuidString)", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("top.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("inner.txt"))

        let all = try DirectoryFingerprint.capture(folder)
        #expect(Set(all.entries.map(\.relativePath)) == ["top.txt", "nested/inner.txt"])
        let excluded = try DirectoryFingerprint.capture(folder, excludedSubpaths: [nested])
        #expect(excluded.entries.map(\.relativePath) == ["top.txt"])
    }

    @Test func fireNowRefusesAFolderEventWithoutAPath() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(name: "Nowhere", source: .folder(FolderSourceConfig()), action: EventPipelineFixtures.agentAction()))
        let result = await manager.fireNow(event.id)
        #expect(result.status == .suppressed)
        #expect(result.reason == "folder_unavailable")
    }
}
