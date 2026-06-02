//
//  NextRunScheduler.swift
//  osaurus
//
//  Phase 3 — Self-scheduling dispatch loop (spec §9). Owns the runtime
//  side of the agent's next-run slot: read `agent_next_run`, sleep until
//  the soonest scheduled row, then dispatch through `TaskDispatcher`
//  with `SessionSource.selfSchedule`.
//
//  Concurrency model:
//
//   - One timer task (`tickerTask`) at any time. It sleeps until either
//     the next scheduled row or a 60-second fallback (whichever fires
//     first), then re-reads from `SchedulerDatabase` and dispatches due
//     rows. The 60-second fallback is the safety net for "a row was
//     added while we were sleeping" — `notifyRowChanged()` cancels the
//     sleep early when that happens at runtime.
//   - Bounded concurrency: at most `Self.maxConcurrent` (4) due rows
//     dispatched per tick. Anything beyond that waits for the next tick.
//   - On-miss policy (`NextRunOnMiss`) is applied at dispatch time for
//     each row, so a cold start sees `runOnce`/`skip`/`runCatchup`
//     behavior consistent with the wake-time evaluation.
//
//  This manager is fully separate from `ScheduleManager` (recurring
//  user-authored schedules). `ScheduleManager.executeSchedule` dispatches
//  with `source: .schedule`; `NextRunScheduler` uses `.selfSchedule`.
//

import Foundation

@MainActor
public final class NextRunScheduler {
    public static let shared = NextRunScheduler()

    /// Cap on simultaneous in-flight self-scheduled dispatches. Each one
    /// is just an `await dispatch(...)` (the actual chat run lives in
    /// `BackgroundTaskManager` and doesn't block us), but the cap caps
    /// the burst seen by `TaskDispatcher.dispatch` itself.
    private static let maxConcurrent = 4

    /// How long we sleep before re-polling when there's no upcoming row.
    /// Keeps the loop reactive to rows the bridge adds at runtime even
    /// if the explicit `notifyRowChanged()` plumbing misses one.
    private static let idleSleep: TimeInterval = 60

    /// Threshold past `scheduled_at` after which a missed row is treated
    /// as stale (spec §9.2). We always run rows ≤ `staleThreshold` past
    /// their wake time; older rows consult `on_miss`.
    private static let staleThreshold: TimeInterval = 5 * 60

    /// Coalesce window keyed by `(agent_id, trigger_kind)` for
    /// overlapping triggers (spec §16). We drop a dispatch if the same
    /// agent has been dispatched with this trigger within the last 5s.
    private static let coalesceWindow: TimeInterval = 5

    private var tickerTask: Task<Void, Never>?
    private var earlyWakeContinuation: CheckedContinuation<Void, Never>?

    /// `(agent_id, trigger_kind) -> last dispatch wall time`. Used for
    /// coalescing. Lives in-process; not persisted because spec defines
    /// the window relative to the running scheduler, not to wall time.
    private var lastDispatch: [String: Date] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Boot the scheduler. Idempotent — calling twice from app delegate
    /// is a no-op. Called from `AppDelegate.applicationDidFinishLaunching`.
    public func start() {
        guard tickerTask == nil else { return }
        // Cold-start catch-up runs as the first iteration of the loop —
        // by the time the loop starts its first sleep, all rows whose
        // scheduled_at has already passed have been processed.
        tickerTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
        print("[Osaurus] NextRunScheduler started")
    }

    /// Stop the loop. Used by tests and (theoretically) the in-process
    /// dispatcher shutdown.
    public func stop() {
        tickerTask?.cancel()
        tickerTask = nil
        fireEarlyWake()
    }

    /// Wake the loop early — call this from `LocalAgentBridge`
    /// `scheduleNextRun` / `cancelNextRun` so the next sleep cycle picks
    /// up the new row immediately rather than waiting for the 60s
    /// fallback. Safe to call when the loop is asleep, awake, or stopped.
    public func notifyRowChanged() {
        fireEarlyWake()
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try SchedulerDatabase.shared.open()
            } catch {
                print("[NextRunScheduler] open failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(Self.idleSleep * 1_000_000_000))
                continue
            }

            await dispatchDueRows()
            await sleepUntilNext()
        }
    }

    /// Find rows whose `scheduled_at <= now`, filter out paused agents,
    /// and dispatch up to `maxConcurrent` of them.
    private func dispatchDueRows() async {
        let now = Date()
        // Prune coalesce entries older than the window: they can no longer
        // suppress a dispatch, so keeping them just grows `lastDispatch` by
        // one entry per agent that ever fired. Bounds the map to recently
        // active agents.
        lastDispatch = lastDispatch.filter { now.timeIntervalSince($0.value) < Self.coalesceWindow }
        let due: [NextRunEntry]
        do {
            due = try SchedulerDatabase.shared.dueNextRuns(asOf: now, limit: Self.maxConcurrent)
        } catch {
            print("[NextRunScheduler] dueNextRuns failed: \(error.localizedDescription)")
            return
        }
        guard !due.isEmpty else { return }

        for entry in due {
            // Pause check (spec §9.2): a paused agent never wakes. We
            // leave the row in place so it dispatches naturally when
            // the pause expires.
            if let pause = try? SchedulerDatabase.shared.pauseInfo(for: entry.agentId),
                pause.pausedUntil > now
            {
                continue
            }

            // On-miss policy. `scheduled_at` ≤ now is guaranteed; the
            // question is whether we're past the stale threshold.
            let drift = now.timeIntervalSince(entry.scheduledAt)
            let staleStatus: StaleStatus = drift > Self.staleThreshold ? .stale : .fresh
            switch (entry.onMiss, staleStatus) {
            case (.skip, .stale):
                // Mark as cancelled in `agent_runs` so the Activity tab
                // shows the miss, then clear the row.
                await recordSkippedRun(entry: entry, reason: "stale-skip")
                clearRow(entry.agentId)
                continue
            case (.runCatchup, .stale):
                // Catch-up dispatches one run per missed interval. We
                // don't have an "interval" for one-shot self-scheduled
                // rows (the row is a single slot, not a recurrence),
                // so for now this collapses to a single dispatch — same
                // as `runOnce`. The behavior matches §9.2's note that
                // `run_catchup` is "rare; for ledger-type agents",
                // which today fold their own intervals into successive
                // self-schedule calls.
                break
            case (.runOnce, _), (.skip, .fresh), (.runCatchup, .fresh):
                break
            }

            // Coalesce window (spec §16). Drop the dispatch if the same
            // (agent, trigger) has fired in the last 5s.
            let coalesceKey = "\(entry.agentId.uuidString):schedule"
            if let last = lastDispatch[coalesceKey],
                now.timeIntervalSince(last) < Self.coalesceWindow
            {
                continue
            }
            lastDispatch[coalesceKey] = now

            // Clear the slot before dispatch. The slot is single-shot;
            // if the agent wants another wake it must call
            // `schedule_next_run` again during the run. Clearing first
            // avoids the race where a slow dispatch lets the scheduler
            // re-pick the same row on the next tick.
            clearRow(entry.agentId)
            await dispatch(entry: entry)
        }
    }

    private func dispatch(entry: NextRunEntry) async {
        // Self-scheduled wakes MUST target a real custom agent. Refuse to
        // dispatch under the built-in Default agent (the previous code
        // could have silently fallen back to it through the dispatcher's
        // `?? Agent.defaultId` coercion, which has now been removed).
        if let rejection = Agent.rejectBuiltInForExternalSurface(
            entry.agentId,
            source: "scheduler/NextRun"
        ) {
            print("[NextRunScheduler] dispatch skipped: \(rejection.message)")
            return
        }

        let request = DispatchRequest(
            prompt: entry.instructions,
            agentId: entry.agentId,
            title: "Self-scheduled run",
            source: .selfSchedule,
            externalSessionKey: entry.agentId.uuidString
        )
        guard let handle = await TaskDispatcher.shared.dispatch(request) else {
            print(
                "[NextRunScheduler] dispatch failed for agent \(entry.agentId.uuidString.prefix(8))"
            )
            return
        }
        // Fire-and-forget the await — we don't need to block the
        // scheduler loop on the chat completing. `BackgroundTaskManager`
        // records the `agent_runs` start/end rows for us via the
        // existing run-hook in Phase 1.
        Task.detached {
            _ = await TaskDispatcher.shared.awaitCompletion(handle)
        }
    }

    private func clearRow(_ agentId: UUID) {
        try? SchedulerDatabase.shared.clearNextRun(for: agentId)
    }

    /// Record a `cancelled` row in `agent_runs` for a missed-and-skipped
    /// self-scheduled wake. The Activity tab joins on this so the user
    /// can see why a wake didn't run.
    private func recordSkippedRun(entry: NextRunEntry, reason: String) async {
        do {
            let id = try SchedulerDatabase.shared.recordRunStart(
                agentId: entry.agentId,
                triggerKind: .schedule,
                triggerPayload: reason,
                instructions: entry.instructions
            )
            try SchedulerDatabase.shared.recordRunEnd(
                runId: id,
                status: .cancelled,
                error: "Skipped: \(reason)"
            )
        } catch {
            // Best-effort; if we can't write to scheduler.sqlite the
            // run-hook isn't critical and we'd rather keep ticking than
            // fail loudly.
        }
    }

    // MARK: - Sleep helpers

    private enum StaleStatus { case fresh, stale }

    /// Sleep until either the next `scheduled_at`, the idle fallback,
    /// or an explicit `notifyRowChanged()`. Whichever happens first.
    ///
    /// Implementation: park on a `CheckedContinuation`; the timer task
    /// resumes it after `interval`, `notifyRowChanged()` resumes it
    /// early. Whichever wins clears the slot so the loser is a no-op.
    private func sleepUntilNext() async {
        let interval = nextSleepInterval()
        let timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fireEarlyWake()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if Task.isCancelled {
                c.resume()
                return
            }
            // If a previous park is still around (shouldn't happen since
            // the loop is sequential, but defensive), resume it first.
            if let prior = self.earlyWakeContinuation {
                self.earlyWakeContinuation = nil
                prior.resume()
            }
            self.earlyWakeContinuation = c
        }
        timerTask.cancel()
    }

    /// Resume the parked sleep continuation, if any. Called by both the
    /// timer task (idle fallback hit) and `notifyRowChanged()`.
    private func fireEarlyWake() {
        guard let c = earlyWakeContinuation else { return }
        earlyWakeContinuation = nil
        c.resume()
    }

    private func nextSleepInterval() -> TimeInterval {
        // Peek at the very next row; if none, sleep the idle fallback.
        // We do a single-row LIMIT 1 by reusing `dueNextRuns` with a
        // far-future cutoff — adding a dedicated `peekNextRun` to
        // `SchedulerDatabase` would be cleaner but the cost is trivial
        // (one bound stmt) and this keeps the storage layer simpler.
        let now = Date()
        do {
            let upcoming = try SchedulerDatabase.shared.dueNextRuns(
                asOf: now.addingTimeInterval(Self.idleSleep),
                limit: 1
            )
            if let first = upcoming.first {
                let delta = first.scheduledAt.timeIntervalSince(now)
                return max(0.5, min(Self.idleSleep, delta))
            }
        } catch {
            // fall through to idle sleep
        }
        return Self.idleSleep
    }
}
