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

/// Thrown by `valueWithDeadline` when the wall-clock deadline fires before
/// the operation completes. Carries the operation name so timeout telemetry
/// and user-facing errors can say *what* exceeded its budget.
public struct DeadlineExceededError: Error, LocalizedError, Sendable {
    public let operationName: String
    public let seconds: Double

    public init(operationName: String, seconds: Double) {
        self.operationName = operationName
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "\(operationName) did not complete within \(Int(seconds.rounded()))s"
    }
}

/// Race `operation` against a wall-clock deadline and the caller's own
/// cancellation, returning its value.
///
/// Unlike a `withThrowingTaskGroup` race, the caller is NEVER re-joined to
/// the operation: structured concurrency waits for every child at scope
/// exit, so a child stuck in a non-cancellable await (an MCP SDK call, an
/// OAuth browser wait, native model-load code) keeps the "timed out"
/// caller blocked forever. Here the operation runs as an *unstructured*
/// task; whichever of {completion, deadline, caller cancellation} happens
/// first resumes the caller, and a non-cooperative operation is cancelled
/// (best effort) and abandoned to finish on its own.
///
/// - Throws: the operation's own error, `DeadlineExceededError` when the
///   deadline fires first, or `CancellationError` when the caller is
///   cancelled while waiting (Stop must unblock immediately even when the
///   underlying work cannot be interrupted).
public func valueWithDeadline<T: Sendable>(
    seconds: Double,
    operationName: String = "operation",
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let work = Task(priority: .high) { try await operation() }
    let state = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)

    /// Resolve at most once; later racers find nil and do nothing.
    @Sendable func take() -> CheckedContinuation<T, Error>? {
        state.withLock { held in
            defer { held = nil }
            return held
        }
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            // If the caller was already cancelled before we stored the
            // continuation, resolve immediately instead of parking.
            if Task.isCancelled {
                work.cancel()
                cont.resume(throwing: CancellationError())
                return
            }
            state.withLock { $0 = cont }

            // Completion racer.
            Task {
                let result: Result<T, Error>
                do { result = .success(try await work.value) } catch { result = .failure(error) }
                take()?.resume(with: result)
            }
            // Deadline racer on a Dispatch timer rather than `Task.sleep`
            // so cooperative-pool saturation cannot delay the bound (see
            // `runWithDeadline` below).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + max(0, seconds)
            ) {
                if let cont = take() {
                    work.cancel()
                    cont.resume(
                        throwing: DeadlineExceededError(operationName: operationName, seconds: seconds)
                    )
                }
            }
        }
    } onCancel: {
        work.cancel()
        // Unblock the caller NOW: Stop/turn-cancel must not wait out the
        // remaining deadline behind a non-cooperative operation.
        take()?.resume(throwing: CancellationError())
    }
}

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
