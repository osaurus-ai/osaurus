//
//  TaskSchedulerTests.swift
//  osaurusTests
//
//  Admission on an in-memory store: queue capacity, overflow policies,
//  per-key ordering, pause, lanes that hold while waiting, cancellation and
//  the loop guard. Nothing runs real work; `onStart` records admissions.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct TaskSchedulerTests {
    final class Started {
        var ids: [UUID] = []
        var dropped: [(UUID, String)] = []
    }

    static func scheduler(_ policy: TaskQueuePolicy = TaskQueuePolicy()) -> (TaskScheduler, TaskStore, TaskQueue) {
        let store = TaskStore(database: nil)
        let scheduler = TaskScheduler(store: store, reservations: ForegroundReservationCenter())
        let queue = store.createQueue(name: "Test", policy: policy)
        return (scheduler, store, queue)
    }

    static func submission(
        _ queue: TaskQueue, _ started: Started, id: UUID = UUID(), limits: [TaskScheduler.Limit] = [],
        key: String? = nil, depth: Int = 0
    ) -> TaskScheduler.Submission {
        TaskScheduler.Submission(
            id: id, queueId: queue.id, limits: limits, orderingKey: key, depth: depth,
            onStart: { started.ids.append(id) },
            onDrop: { started.dropped.append((id, $0)) })
    }

    @Test func queueCapacityHoldsTheRestUntilASlotFrees() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 2
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        let a = Self.submission(queue, started)
        let b = Self.submission(queue, started)
        let c = Self.submission(queue, started)

        #expect(scheduler.submit(a) == .started)
        #expect(scheduler.submit(b) == .started)
        #expect(scheduler.submit(c) == .queued(position: 1))
        #expect(scheduler.runningCount(key: TaskScheduler.Limit.queue(queue.id)) == 2)
        #expect(scheduler.pendingIds(queueId: queue.id) == [c.id])

        scheduler.finish(a.id)
        #expect(started.ids == [c.id])
        #expect(!scheduler.isPending(c.id))
        #expect(scheduler.isOccupying(c.id))
    }

    @Test func raisingMaxConcurrentAdmitsWaitingTasksAtOnce() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        let (scheduler, store, queue) = Self.scheduler(policy)
        let started = Started()
        _ = scheduler.submit(Self.submission(queue, started))
        let waiting = Self.submission(queue, started)
        #expect(scheduler.submit(waiting) == .queued(position: 1))

        var updated = queue
        updated.policy.maxConcurrent = 2
        store.updateQueue(updated)
        #expect(started.ids == [waiting.id])
    }

    @Test func fullQueueRefusesByDefault() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        policy.maxPending = 1
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        #expect(scheduler.submit(Self.submission(queue, started)) == .started)
        #expect(scheduler.submit(Self.submission(queue, started)) == .queued(position: 1))
        #expect(scheduler.submit(Self.submission(queue, started)) == .rejected(reason: "queue_full"))
    }

    @Test func dropOldestMakesRoomForTheNewTask() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        policy.maxPending = 1
        policy.overflow = .dropOldest
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        _ = scheduler.submit(Self.submission(queue, started))
        let oldest = Self.submission(queue, started)
        let newest = Self.submission(queue, started)
        _ = scheduler.submit(oldest)

        #expect(scheduler.submit(newest) == .queued(position: 1))
        #expect(started.dropped.map(\.0) == [oldest.id])
        #expect(started.dropped.first?.1 == "dropped_oldest")
        #expect(scheduler.pendingIds(queueId: queue.id) == [newest.id])
    }

    @Test func coalesceKeepsOnlyTheNewestPerKey() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        policy.overflow = .coalesceByKey
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        _ = scheduler.submit(Self.submission(queue, started))
        let first = Self.submission(queue, started, key: "room-1")
        let other = Self.submission(queue, started, key: "room-2")
        let second = Self.submission(queue, started, key: "room-1")
        _ = scheduler.submit(first)
        _ = scheduler.submit(other)
        _ = scheduler.submit(second)

        #expect(started.dropped.map(\.0) == [first.id])
        #expect(started.dropped.first?.1 == "coalesced")
        #expect(scheduler.pendingIds(queueId: queue.id) == [other.id, second.id])
    }

    @Test func perKeyOrderingRunsOneAtATimePerKeyAndKeysSideBySide() {
        var policy = TaskQueuePolicy()
        policy.orderingMode = .perKey
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        let a1 = Self.submission(queue, started, key: "a")
        let a2 = Self.submission(queue, started, key: "a")
        let b1 = Self.submission(queue, started, key: "b")

        #expect(scheduler.submit(a1) == .started)
        #expect(scheduler.submit(a2) == .queued(position: 1))
        #expect(scheduler.submit(b1) == .started)

        scheduler.finish(a1.id)
        #expect(started.ids == [a2.id])
    }

    @Test func pausedQueueHoldsWithAReasonUntilResumed() {
        var policy = TaskQueuePolicy()
        policy.paused = true
        let (scheduler, store, queue) = Self.scheduler(policy)
        let started = Started()
        let task = OsaurusTask(
            title: "Held", queueId: queue.id, origin: .manual, createdBy: .user,
            work: .agentTurn(AgentTurnWork(agentId: nil, source: .chat)), state: .queued)
        store.record(task)
        let submission = Self.submission(queue, started, id: task.id)

        #expect(scheduler.submit(submission) == .queued(position: 1))
        #expect(scheduler.waitReason(task.id) == "paused")
        #expect(store.task(id: task.id)?.waitReason == "paused")

        store.setPaused(queue.id, paused: false)
        #expect(started.ids == [task.id])
    }

    @Test func aWaitingLaneKeepsItsSlotButFreesTheQueue() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        let eventId = UUID()
        let lane = TaskScheduler.Limit.lane(
            eventId: eventId, delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 5), conversationKey: nil)
        let first = Self.submission(queue, started, limits: [lane])
        let sameLane = Self.submission(queue, started, limits: [lane])
        let unrelated = Self.submission(queue, started)

        #expect(scheduler.submit(first) == .started)
        #expect(scheduler.submit(sameLane) == .queued(position: 1))
        #expect(scheduler.submit(unrelated) == .queued(position: 2))

        // The first run stops for a form: the queue slot frees, the lane does not.
        scheduler.suspend(first.id)
        #expect(started.ids == [unrelated.id])
        #expect(scheduler.isPending(sameLane.id))

        scheduler.resume(first.id)
        scheduler.finish(first.id)
        scheduler.finish(unrelated.id)
        #expect(started.ids == [unrelated.id, sameLane.id])
    }

    @Test func laneKeysSplitOnlyPerConversation() {
        let id = UUID()
        #expect(TaskScheduler.Limit.laneKey(eventId: id, mode: .serial, conversationKey: "a") == "lane:\(id.uuidString)")
        #expect(
            TaskScheduler.Limit.laneKey(eventId: id, mode: .parallel, conversationKey: "a") == "lane:\(id.uuidString)")
        #expect(
            TaskScheduler.Limit.laneKey(eventId: id, mode: .perConversation, conversationKey: "a")
                == "lane:\(id.uuidString)|a")
        let parallel = TaskScheduler.Limit.lane(
            eventId: id, delivery: EventDeliveryPolicy(mode: .parallel, maxConcurrent: 3), conversationKey: nil)
        #expect(parallel.capacity == 3)
        let serial = TaskScheduler.Limit.lane(
            eventId: id, delivery: EventDeliveryPolicy(mode: .serial, maxConcurrent: 3, maxQueued: 0),
            conversationKey: nil)
        #expect(serial.capacity == 1)
        #expect(serial.rejectReason == "busy")
    }

    @Test func cancelPendingDropsWithoutStarting() {
        var policy = TaskQueuePolicy()
        policy.maxConcurrent = 1
        let (scheduler, _, queue) = Self.scheduler(policy)
        let started = Started()
        let running = Self.submission(queue, started)
        let waiting = Self.submission(queue, started)
        _ = scheduler.submit(running)
        _ = scheduler.submit(waiting)

        #expect(scheduler.cancelPending(waiting.id))
        #expect(!scheduler.cancelPending(waiting.id))
        scheduler.finish(running.id)
        #expect(started.ids.isEmpty)
    }

    @Test func chainsPastTheDepthLimitAreRefused() {
        let (scheduler, _, queue) = Self.scheduler()
        let started = Started()
        let deep = Self.submission(queue, started, depth: TaskScheduler.maxDepth + 1)
        #expect(scheduler.submit(deep) == .rejected(reason: "loop_guard"))
        #expect(scheduler.submit(Self.submission(queue, started, depth: TaskScheduler.maxDepth)) == .started)
    }

    @Test func agentCapIsSharedAcrossQueues() {
        let (scheduler, store, queue) = Self.scheduler()
        let other = store.createQueue(name: "Other")
        let started = Started()
        let agentId = UUID()
        for index in 0 ..< TaskScheduler.maxTasksPerAgent {
            let target = index.isMultiple(of: 2) ? queue : other
            #expect(scheduler.submit(Self.submission(target, started, limits: [.agent(agentId)])) == .started)
        }
        #expect(scheduler.submit(Self.submission(queue, started, limits: [.agent(agentId)])) == .queued(position: 1))
    }
}
