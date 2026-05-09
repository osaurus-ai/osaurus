//
//  DistillationCoordinator.swift
//  osaurus
//
//  Single-flight serializer for the memory distillation pipeline.
//  Every distill trigger (per-turn debounce, syncNow, recoverOrphaned-
//  Signals, the user-driven "Distill pending" button, the chat-history
//  backfill) routes through here so heavy MLX core models don't see
//  three concurrent prefills land at once on small Macs.
//
//  Three invariants `run` enforces:
//
//    1. **One at a time.** New `run` calls chain onto the previous
//       Task via `await previous?.value`.
//    2. **Yield to live chat.** Awaits
//       `InferenceLoadCoordinator.waitForChatIdle(timeoutMs:)` first;
//       proceeds anyway on timeout so signals can't pile up forever.
//    3. **Skip uncheap cold loads.** When `requireResident == true`,
//       short-circuits via `MemoryService.canDistillCheaply()` so a
//       400-session backfill doesn't repeatedly cold-load a 13B model
//       between runs as eviction GCs it.
//
//  `flushAllPending` at app quit deliberately bypasses this coordinator
//  — shutdown wants direct serial execution against a wallclock budget,
//  not a chat-idle wait that would block teardown.
//

import Foundation

public actor DistillationCoordinator {
    public static let shared = DistillationCoordinator()

    /// The most-recently scheduled distillation task. Each new call to
    /// `run` awaits this before executing, forming an implicit FIFO
    /// queue. Previous-task references are dropped as soon as a new
    /// one chains, so the chain doesn't accumulate.
    private var currentTask: Task<Void, Never>?

    /// Number of `run` calls currently awaiting their turn (including
    /// the one actively executing). Surfaced via `snapshot()` so the
    /// diagnostics panel can show queue depth.
    private var queuedCount = 0

    /// Whether a distillation body is currently executing (post-gate).
    /// Distinct from `queuedCount` so the panel can tell "queued
    /// waiting" from "running now".
    private var bodyActive = false

    private init() {}

    // MARK: - Inspection

    public struct Snapshot: Sendable {
        public let queued: Int
        public let active: Bool
    }

    public func snapshot() -> Snapshot {
        Snapshot(queued: queuedCount, active: bodyActive)
    }

    // MARK: - Run

    /// Run `body` after waiting for: (1) any previous distill to
    /// finish, (2) chat idle for up to `chatIdleWaitMs` (0 disables
    /// the wait — used by the quit-time drain caller via direct calls,
    /// not via this coordinator). When `requireResident == true`, the
    /// gate also checks `MemoryService.canDistillCheaply()` and skips
    /// the run if the configured core model would require an expensive
    /// cold load. Skipped runs return without invoking `body`.
    ///
    /// Returns when `body` either finishes, throws (it's `() async`,
    /// so it doesn't), or was skipped by the residency gate.
    public func run(
        chatIdleWaitMs: Int = 8000,
        requireResident: Bool = true,
        body: @Sendable @escaping () async -> Void
    ) async {
        queuedCount += 1
        let previous = currentTask
        let myTask = Task<Void, Never> { [weak self] in
            // Wait for the previous distill to fully complete before
            // we even check the residency / chat-idle gates — this is
            // what makes the queue strictly serial. `previous?.value`
            // is non-throwing because we use `Task<Void, Never>`.
            await previous?.value

            if requireResident {
                let cheap = await MemoryService.shared.canDistillCheaply()
                if !cheap {
                    MemoryLogger.service.info(
                        "DistillationCoordinator: skipping run — core model not resident or too large to cold-load"
                    )
                    return
                }
            }

            if chatIdleWaitMs > 0 {
                let wentIdle = await InferenceLoadCoordinator.shared.waitForChatIdle(
                    timeoutMs: chatIdleWaitMs
                )
                if !wentIdle {
                    // Proceed anyway. Long-running chats shouldn't
                    // starve the memory pipeline; we'd rather take the
                    // chat-latency hit than have signals pile up
                    // forever. The .info log gives support a marker
                    // when investigating chat tok/sec degradation.
                    MemoryLogger.service.info(
                        "DistillationCoordinator: chat-idle wait timed out; proceeding"
                    )
                }
            }

            // Sequential pairing (not `defer { Task { ... } }`) so the
            // false-flip happens *before* `myTask` returns. A
            // fire-and-forget defer would leave `bodyActive == true`
            // briefly observable after `myTask.value` resumes, which
            // would race the diagnostics-panel snapshot.
            await self?.setBodyActive(true)
            await body()
            await self?.setBodyActive(false)
        }

        currentTask = myTask
        await myTask.value
        queuedCount = max(0, queuedCount - 1)
    }

    private func setBodyActive(_ active: Bool) {
        bodyActive = active
    }
}
