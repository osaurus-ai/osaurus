//
//  AsyncDeadlineTests.swift
//  OsaurusCoreTests
//
//  Pins the non-rejoining semantics of `valueWithDeadline`: the caller is
//  released by whichever of {completion, deadline, caller cancellation}
//  happens first, even when the underlying operation ignores cooperative
//  cancellation entirely (a stuck MCP SDK call, OAuth wait, or native
//  model-load path).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AsyncDeadlineTests {

    @Test
    func returnsOperationValueBeforeDeadline() async throws {
        let value = try await valueWithDeadline(seconds: 5, operationName: "fast op") {
            42
        }
        #expect(value == 42)
    }

    @Test
    func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await valueWithDeadline(seconds: 5, operationName: "failing op") {
                throw Boom()
            }
        }
    }

    @Test
    func deadlineUnblocksCallerEvenWhenOperationIgnoresCancellation() async {
        // The operation parks on a continuation that is never resumed and
        // has no cancellation handler — the worst case. A task-group race
        // would re-join it and hang; `valueWithDeadline` must abandon it.
        let start = Date()
        do {
            _ = try await valueWithDeadline(seconds: 0.2, operationName: "wedged op") {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in
                    // Never resumed: simulates non-cooperative native work.
                }
            }
            Issue.record("expected DeadlineExceededError")
        } catch let error as DeadlineExceededError {
            #expect(error.operationName == "wedged op")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "caller stayed blocked for \(elapsed)s past the deadline")
    }

    @Test
    func callerCancellationUnblocksImmediately() async {
        // Stop responsiveness: cancelling the *caller* must release it right
        // away — not after the remaining deadline — even though the wedged
        // operation never observes cancellation.
        let waiter = Task {
            try await valueWithDeadline(seconds: 30, operationName: "wedged op") {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        waiter.cancel()
        let result = await waiter.result
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "cancelled caller stayed blocked for \(elapsed)s")
        switch result {
        case .success:
            Issue.record("expected cancellation error")
        case .failure(let error):
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    @Test
    func operationSeesCooperativeCancellationAtDeadline() async {
        // A cooperative operation should observe the cancel that fires when
        // the deadline wins, so it can stop doing work.
        let observedCancel = OSAllocatedUnfairLockBox(false)
        do {
            _ = try await valueWithDeadline(seconds: 0.15, operationName: "cooperative op") {
                () -> Int in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                observedCancel.set(true)
                return 0
            }
        } catch {}
        // Give the abandoned task a beat to notice the cancel.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(observedCancel.get(), "operation never observed cooperative cancellation")
    }
}

/// A deadline stands still while a person decides on an approval card.
@Suite
struct DeadlineClockTests {

    @Test
    func pausedTime_isNotCounted_andNestedPausesResumeTogether() {
        let clock = DeadlineClock()
        let start = Date(timeIntervalSince1970: 1000)
        clock.pause(now: start.addingTimeInterval(2))
        clock.pause(now: start.addingTimeInterval(3))
        clock.resume(now: start.addingTimeInterval(4))
        #expect(clock.isPaused, "an inner resume leaves the outer pause open")
        #expect(!clock.hasElapsed(5, since: start, now: start.addingTimeInterval(60)))
        clock.resume(now: start.addingTimeInterval(12))
        #expect(!clock.isPaused)
        #expect(clock.pausedSeconds(now: start.addingTimeInterval(20)) == 10)
        #expect(clock.remaining(5, since: start, now: start.addingTimeInterval(14)) == 1)
        #expect(!clock.hasElapsed(5, since: start, now: start.addingTimeInterval(14)))
        #expect(clock.hasElapsed(5, since: start, now: start.addingTimeInterval(15)))
    }

    @Test
    func extraResume_isIgnored() {
        let clock = DeadlineClock()
        let start = Date(timeIntervalSince1970: 0)
        clock.resume(now: start)
        #expect(!clock.isPaused)
        #expect(clock.pausedSeconds(now: start.addingTimeInterval(5)) == 0)
    }

    @Test
    func observer_pausesItsClockAndForwardsToTheOuterOne() async {
        let outer = DeadlineClock()
        let inner = DeadlineClock()
        let observer = inner.observer(chainingTo: outer.observer(chainingTo: nil))
        await observer(true)
        #expect(inner.isPaused && outer.isPaused)
        await observer(false)
        #expect(!inner.isPaused && !outer.isPaused)
    }

    @Test
    func valueWithDeadline_doesNotFireWhilePaused_andCreditsThePause() async throws {
        let clock = DeadlineClock()
        let value = try await valueWithDeadline(seconds: 0.3, clock: clock, operationName: "approval step") {
            clock.pause()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            clock.resume()
            try await Task.sleep(nanoseconds: 100_000_000)
            return 7
        }
        #expect(value == 7)
    }

    @Test
    func valueWithDeadline_stillFiresForUnpausedWork() async {
        let clock = DeadlineClock()
        let start = Date()
        do {
            _ = try await valueWithDeadline(seconds: 0.4, clock: clock, operationName: "slow step") {
                clock.pause()
                try await Task.sleep(nanoseconds: 300_000_000)
                clock.resume()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            }
            Issue.record("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed >= 0.6, "the paused 0.3s must be credited, fired after \(elapsed)s")
            #expect(elapsed < 3, "fired late: \(elapsed)s")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// Tiny Sendable box for cross-task assertions.
private final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}
