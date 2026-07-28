//
//  InferenceLoadCoordinator.swift
//  osaurus
//
//  Refcounted "live chat generation in flight" signal. Distinct from
//  `ModelLease` (which counts in-use *model names*) so background
//  distillation can pause for chat traffic without registering its own
//  core-model lease as chat traffic.
//
//  `ModelLease` already prevents the documented
//  `notifyExternalReferencesNonZeroOnDealloc` Metal crash. This
//  coordinator covers the OOM-kill class on non-foundation core
//  models — running distillation concurrently with a heavy MLX chat
//  on 8/16 GB Macs puts two large prefills + two KV caches into
//  unified memory and triggers macOS jetsam.
//
//  Pattern mirrors `ModelLease`:
//   * `beginChatGeneration` / `endChatGeneration` track the refcount.
//   * `waitForChatIdle(timeoutMs:)` parks the caller until the count
//     hits zero, with a wallclock cap so distillation can't be
//     starved by a long-running stream.
//

import Foundation
import os

/// Synchronous HTTP-layer admission gate for inference requests.
///
/// `ServerController.activeRequestCount` is UI-only and `ModelLease` /
/// `InferenceLoadCoordinator` track *liveness*, not *backpressure*: nothing
/// stops N concurrent `/v1/chat/completions` streams from each spawning a Task
/// that fans into MLX, oversubscribing the batch engine and unified memory.
///
/// This is a plain token counter (no async hop — the NIO channel handler is
/// synchronous) keyed to the batch engine's `maxConcurrentSequences`. When the
/// in-flight count is at the ceiling, the HTTP layer returns `503` with a
/// `Retry-After` instead of admitting unbounded work.
public final class HTTPInferenceAdmission: @unchecked Sendable {
    public static let shared = HTTPInferenceAdmission()

    private let state = OSAllocatedUnfairLock(initialState: 0)

    init() {}

    /// Try to admit one inference request. Returns `true` when admitted — the
    /// caller MUST pair it with exactly one `release()` on every exit path —
    /// or `false` when the gate is saturated.
    public func tryAcquire(limit: Int) -> Bool {
        let ceiling = max(1, limit)
        return state.withLock { inflight in
            guard inflight < ceiling else { return false }
            inflight += 1
            return true
        }
    }

    public func release() {
        state.withLock { inflight in
            inflight = max(0, inflight - 1)
        }
    }

    /// Acquire one slot and hand back a one-shot `Token`. Returns `nil` when
    /// saturated. Prefer this over `tryAcquire`/`release` on routes with many
    /// exit paths: the token releases exactly once (idempotent) and its
    /// `deinit` is a leak backstop, so a forgotten/cancelled path can't pin
    /// the gate.
    public func tryAcquireToken(limit: Int) -> Token? {
        tryAcquire(limit: limit) ? Token(gate: self) : nil
    }

    public var inflightCount: Int {
        state.withLock { $0 }
    }

    /// One-shot, idempotent release handle for an admitted inference request.
    public final class Token: @unchecked Sendable {
        private let releasedOnce = OSAllocatedUnfairLock(initialState: false)
        private let gate: HTTPInferenceAdmission

        fileprivate init(gate: HTTPInferenceAdmission) { self.gate = gate }

        /// Release the slot. Safe to call multiple times — only the first
        /// call decrements the gate.
        public func release() {
            let shouldRelease = releasedOnce.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if shouldRelease { gate.release() }
        }

        deinit { release() }
    }
}

public actor InferenceLoadCoordinator {
    public static let shared = InferenceLoadCoordinator()

    private var activeChats = 0
    private enum IdleWaitSignal: Sendable {
        case idle
        case timedOut
        case cancelled
    }

    /// One owned parked wait. The coordinator removes the entry, cancels its
    /// timeout task, and resumes its continuation exactly once on every exit
    /// path (idle, timeout, or caller cancellation).
    private struct IdleWaiter {
        let continuation: CheckedContinuation<IdleWaitSignal, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var idleWaiters: [UUID: IdleWaiter] = [:]

    init() {}

    // MARK: - Refcount API (chat side)

    /// Pair with exactly one `endChatGeneration` on every exit path
    /// (success, throw, cancel) — chat callers should `defer` the
    /// release so cancellation never leaks the count.
    public func beginChatGeneration() {
        activeChats += 1
    }

    public func endChatGeneration() {
        activeChats = max(0, activeChats - 1)
        if activeChats == 0 { wakeIdleWaiters() }
    }

    private func wakeIdleWaiters() {
        guard !idleWaiters.isEmpty else { return }
        let pending = Array(idleWaiters.values)
        idleWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: .idle)
        }
    }

    // MARK: - Inspection

    public var chatActive: Bool { activeChats > 0 }
    public var activeCount: Int { activeChats }
    /// Internal diagnostic used by deterministic cancellation tests. A
    /// cancelled caller must never leave a parked waiter behind.
    var pendingIdleWaiterCount: Int { idleWaiters.count }

    // MARK: - Distillation side

    /// Suspend until `chatActive == false` OR `timeoutMs` elapses.
    /// Returns `true` when chat went idle, `false` on timeout.
    ///
    /// Re-checks after each wake (the `acquire → wake → re-acquire`
    /// race is real under sustained load — see `ModelLease.waitForZero`
    /// for the same pattern in a sibling primitive).
    public func waitForChatIdle(timeoutMs: Int) async -> Bool {
        if Task.isCancelled { return false }
        if activeChats == 0 { return true }

        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000.0)

        while activeChats > 0 {
            if Task.isCancelled { return false }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }

            let signal = await parkUntilIdleOrDeadline(remaining: remaining)
            switch signal {
            case .idle:
                break
            case .timedOut, .cancelled:
                return false
            }
            // Loop and re-check activeChats. If a different chat
            // started during the wake, we re-park.
        }
        return true
    }

    private func parkUntilIdleOrDeadline(remaining: TimeInterval) async -> IdleWaitSignal {
        let waiterID = UUID()
        if Task.isCancelled { return .cancelled }

        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<IdleWaitSignal, Never>) in
                // Re-check atomically inside the actor before parking.
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if activeChats == 0 {
                    continuation.resume(returning: .idle)
                    return
                }

                let timeoutTask = Task { [remaining] in
                    do {
                        try await Task.sleep(for: .seconds(remaining))
                    } catch {
                        return
                    }
                    self.resolveIdleWaiter(waiterID, signal: .timedOut)
                }
                idleWaiters[waiterID] = IdleWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            // Cancellation handlers are synchronous. The actor-owned removal
            // still runs in-order, and `resolveIdleWaiter` is the sole
            // continuation-resume boundary.
            Task { await self.resolveIdleWaiter(waiterID, signal: .cancelled) }
        }
    }

    private func resolveIdleWaiter(_ id: UUID, signal: IdleWaitSignal) {
        guard let waiter = idleWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: signal)
    }
}
