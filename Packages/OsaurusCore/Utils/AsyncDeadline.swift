//
//  AsyncDeadline.swift
//  osaurus
//
//  Best-effort async deadline primitive for the app-quit teardown path.
//
//  The quit chain in `AppDelegate.applicationShouldTerminate` is a sequence
//  of `await`s, several of which can stall indefinitely (a never-released
//  model lease, a synchronous GPU fence, a Linux VM that won't stop, a NIO
//  graceful shutdown waiting on a long-lived SSE stream). A plain
//  `withTaskGroup`-based timeout does NOT help here: structured concurrency
//  re-joins every child task at scope exit, so a child stuck in a
//  non-cancellable / parked await keeps the group — and therefore the
//  caller — blocked forever.
//
//  `runWithDeadline` instead races the operation against a timer using two
//  *unstructured* tasks and a one-shot continuation. Whichever finishes
//  first resumes the caller; if the deadline wins, the operation task is
//  cancelled (cooperative best effort) and simply abandoned. The caller
//  proceeds regardless, which is exactly what a bounded quit teardown needs.
//

import Foundation
import os

/// Runs `operation`, returning no later than `seconds`.
///
/// - Returns: `true` if `operation` completed before the deadline, `false`
///   if the deadline fired first. On timeout the operation task is
///   cancelled and left to finish (or never finish) on its own — the caller
///   is unblocked immediately. Intended for best-effort teardown where a
///   single stuck step must never block process exit.
@discardableResult
public func runWithDeadline(
    seconds: Double,
    operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let work = Task(priority: .high) { await operation() }
    let resolved = OSAllocatedUnfairLock(initialState: false)

    @Sendable func claim() -> Bool {
        resolved.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }

    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        // Completion racer.
        Task {
            await work.value
            if claim() { cont.resume(returning: true) }
        }
        // Deadline racer on a Dispatch timer rather than `Task.sleep`. This
        // backstops the quit teardown, which can saturate the Swift
        // cooperative thread pool (many concurrent shutdown awaits) — and a
        // `Task.sleep`-based deadline would then fire late, exactly when the
        // bound matters most. A Dispatch timer runs on its own thread, so the
        // deadline is honored regardless of cooperative-pool pressure.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0, seconds)
        ) {
            if claim() {
                work.cancel()
                cont.resume(returning: false)
            }
        }
    }
}
