//
//  InferenceSchedulerTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct InferenceSchedulerTests {

    @Test func first_caller_admitted_immediately() async {
        let scheduler = InferenceScheduler.shared
        // Drain anything left from a previous test.
        await drainScheduler()

        await scheduler.acquire(priority: .interactive)
        let snapshot = await scheduler.snapshot()
        #expect(snapshot.active)
        #expect(snapshot.activePriority == .interactive)
        #expect(snapshot.totalQueued == 0)

        await scheduler.release()
    }

    @Test func second_caller_waits_until_release() async {
        let scheduler = InferenceScheduler.shared
        await drainScheduler()

        await scheduler.acquire(priority: .plugin)
        let secondAdmitted = AtomicBoolFlag()
        let secondTask = Task {
            await scheduler.acquire(priority: .plugin)
            secondAdmitted.set()
            await scheduler.release()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!secondAdmitted.value)

        await scheduler.release()
        await secondTask.value
        #expect(secondAdmitted.value)
    }

    @Test func higher_priority_jumps_ahead_of_lower() async {
        let scheduler = InferenceScheduler.shared
        await drainScheduler()

        // Active: occupied so queueing happens.
        await scheduler.acquire(priority: .background)

        let order = OrderRecorder()

        // Three waiters: low, high, mid (in that arrival order).
        let lowTask = Task {
            await scheduler.acquire(priority: .background)
            order.record("background")
            await scheduler.release()
        }
        let highTask = Task {
            await scheduler.acquire(priority: .interactive)
            order.record("interactive")
            await scheduler.release()
        }
        let midTask = Task {
            await scheduler.acquire(priority: .plugin)
            order.record("plugin")
            await scheduler.release()
        }

        // Let all three enqueue.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Release the active slot — interactive should win, then plugin,
        // then background.
        await scheduler.release()

        // Wait for everyone.
        await lowTask.value
        await highTask.value
        await midTask.value

        let recorded = order.values
        #expect(recorded == ["interactive", "plugin", "background"])
    }

    @Test func snapshot_reports_queued_counts() async {
        let scheduler = InferenceScheduler.shared
        await drainScheduler()

        await scheduler.acquire(priority: .interactive)

        let pluginA = Task {
            await scheduler.acquire(priority: .plugin)
            await scheduler.release()
        }
        let pluginB = Task {
            await scheduler.acquire(priority: .plugin)
            await scheduler.release()
        }
        let bg = Task {
            await scheduler.acquire(priority: .background)
            await scheduler.release()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await scheduler.snapshot()
        #expect(snapshot.active)
        #expect(snapshot.activePriority == .interactive)
        #expect(snapshot.totalQueued == 3)
        #expect(snapshot.queuedByPriority[.plugin] == 2)
        #expect(snapshot.queuedByPriority[.background] == 1)

        await scheduler.release()
        await pluginA.value
        await pluginB.value
        await bg.value
    }

    @Test func shouldYield_returns_true_when_higher_queued() async {
        let scheduler = InferenceScheduler.shared
        await drainScheduler()

        await scheduler.acquire(priority: .background)
        let pendingTask = Task {
            await scheduler.acquire(priority: .interactive)
            await scheduler.release()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let shouldYield = await scheduler.shouldYield(above: .background)
        #expect(shouldYield)

        let shouldYieldAtTop = await scheduler.shouldYield(above: .interactive)
        #expect(!shouldYieldAtTop)

        await scheduler.release()
        await pendingTask.value
    }

    // MARK: - Helpers

    /// Drain anything left over from a prior test (only safe in serialized suite).
    private func drainScheduler() async {
        // Cancel any pending waiters and ensure we're idle.
        await InferenceScheduler.shared.cancelAllWaiters()
        let snapshot = await InferenceScheduler.shared.snapshot()
        if snapshot.active {
            await InferenceScheduler.shared.release()
        }
    }
}

private final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func record(_ s: String) { lock.withLock { _values.append(s) } }
}
