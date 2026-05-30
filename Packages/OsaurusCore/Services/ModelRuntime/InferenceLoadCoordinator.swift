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

public actor InferenceLoadCoordinator {
    public static let shared = InferenceLoadCoordinator()

    private var activeChats = 0
    /// Each waiter is a one-shot callback that fires when the count
    /// transitions to zero. Storing closures (instead of raw
    /// `CheckedContinuation` values) keeps the timeout-vs-idle race in
    /// `waitForChatIdle` simple — the closure routes through a small
    /// `RaceBox` that ensures only the first signal wins.
    private var idleWaiters: [@Sendable () -> Void] = []

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
        let pending = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        for cb in pending { cb() }
    }

    // MARK: - Inspection

    public var chatActive: Bool { activeChats > 0 }
    public var activeCount: Int { activeChats }

    // MARK: - Distillation side

    /// Suspend until `chatActive == false` OR `timeoutMs` elapses.
    /// Returns `true` when chat went idle, `false` on timeout.
    ///
    /// Re-checks after each wake (the `acquire → wake → re-acquire`
    /// race is real under sustained load — see `ModelLease.waitForZero`
    /// for the same pattern in a sibling primitive).
    public func waitForChatIdle(timeoutMs: Int) async -> Bool {
        if activeChats == 0 { return true }

        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000.0)

        while activeChats > 0 {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }

            let timedOut: Bool = await withCheckedContinuation { (cc: CheckedContinuation<Bool, Never>) in
                // Re-check atomically inside the actor before parking
                // — the increment that flipped activeChats to non-zero
                // could have already been undone before we got here.
                if activeChats == 0 {
                    cc.resume(returning: false)
                    return
                }
                let box = RaceBox(continuation: cc)

                // Idle path: enqueued in the actor's waiter list,
                // fired by `wakeIdleWaiters` when count hits zero.
                idleWaiters.append { Task { await box.resumeOnce(timedOut: false) } }

                // Timeout path: independent task; whichever signal
                // wins through `RaceBox.resumeOnce` is the result.
                Task { [remaining] in
                    try? await Task.sleep(for: .seconds(remaining))
                    await box.resumeOnce(timedOut: true)
                }
            }

            if timedOut { return false }
            // Loop and re-check activeChats. If a different chat
            // started during the wake, we re-park.
        }
        return true
    }
}

/// One-shot continuation router. Either the idle-wake path or the
/// timeout task resumes the underlying continuation; whichever loses
/// the race becomes a no-op. Avoids double-resume traps that
/// `CheckedContinuation` would catch at runtime.
private actor RaceBox {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(timedOut: Bool) {
        guard let cc = continuation else { return }
        continuation = nil
        cc.resume(returning: timedOut)
    }
}
