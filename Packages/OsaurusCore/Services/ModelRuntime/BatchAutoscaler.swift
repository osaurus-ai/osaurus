//
//  BatchAutoscaler.swift
//  osaurus
//
//  "Auto" batch sizing for the MLX `BatchEngine`: keep `maxBatchSize == 1`
//  (the compiled-decode fast path — the documented 9× TTFT win per the
//  `InferenceFeatureFlags.mlxBatchEngineMaxBatchSize` doc comment) for
//  single-user chat, and escalate a model's slot count ONLY when real
//  overlapping demand for that model has been observed recently, capped by
//  the hardware tier.
//
//  Escalation is one-way sticky within a busy window: downsizing an engine
//  mid-burst thrashes engine rebuilds and (per the vmlx invariant) a
//  hot-resize DOWN never recovers the compiled decode path anyway. The
//  recommendation falls back to 1 only after a FULL quiet window (no
//  overlapping demand for `windowSeconds`), and the return-to-1 path tears
//  the engine down via `MLXBatchAdapter.Registry.shutdownEngineIfIdle` —
//  off the request path, and only when the engine is idle — so the next
//  request rebuilds fresh at 1 and regains compile eligibility.
//

import Foundation
import os.log

private let autoBatchLog = Logger(subsystem: "ai.osaurus", category: "BatchAutoscaler")

/// Pure decision rules for auto batch sizing. Kept side-effect free (no
/// clock, no actor state) so the escalation/stickiness contract is unit
/// testable without `BatchAutoscaler` itself.
enum BatchAutoscalerPolicy {
    /// Hardware ceiling for auto escalation, keyed by chip tier.
    ///
    /// Rationale: decode on Apple Silicon is memory-bandwidth bound, and
    /// every extra concurrent sequence multiplies per-step KV + activation
    /// traffic. Base dies (~100–150 GB/s) cannot feed even two concurrent
    /// decode streams meaningfully faster than serial execution, so on base
    /// tier escalation would trade away the 9× compiled-decode TTFT win for
    /// throughput the bandwidth can't deliver — base NEVER escalates.
    /// Pro (~200–300 GB/s) sustains a small fan-out, Max (~400–550 GB/s)
    /// roughly doubles that, Ultra (two fused Max dies, ~800+ GB/s) doubles
    /// it again. `unknown` (Intel, VMs, future naming schemes) gets the most
    /// conservative cap, matching `ChipProfile`'s "unknown means be
    /// conservative" contract.
    static func tierCap(for tier: ChipProfile.Tier) -> Int {
        switch tier {
        case .base, .unknown: return 1
        case .pro: return 4
        case .max: return 8
        case .ultra: return 16
        }
    }

    /// Smallest power of two >= `value`. Values <= 1 map to 1.
    static func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }

    /// One recommendation step.
    ///
    /// - No overlap in the window (`windowMax <= 1`): return to 1 — the
    ///   compile-friendly single-slot configuration. This is the ONLY path
    ///   that can lower the recommendation; a full quiet window must elapse
    ///   before samples age out and `windowMax` drops.
    /// - Overlap: `min(nextPowerOfTwo(windowMax), tierCap)`, but never below
    ///   `previous` (one-way sticky within a busy window — mid-burst
    ///   downsizing thrashes engine rebuilds without recovering compile).
    static func decision(windowMax: Int, tierCap: Int, previous: Int) -> Int {
        let cap = max(tierCap, 1)
        guard windowMax > 1 else { return 1 }
        let target = min(nextPowerOfTwo(windowMax), cap)
        return min(max(target, previous), cap)
    }
}

/// Tracks recent same-model overlapping demand and recommends a
/// `BatchEngine` `maxBatchSize` from it. See the file header for the
/// escalate/stick/decay contract.
///
/// The submission path (`MLXBatchAdapter.generate`) feeds
/// `recordSubmission(model:pendingAndActive:)`; the resolution path
/// (`InferenceFeatureFlags`) reads `recommendedBatchSize(for:tierCap:)`.
actor BatchAutoscaler {
    /// Production instance. The return-to-1 hook shuts the engine down (only
    /// when idle) so the next request rebuilds fresh at 1 and regains
    /// compile eligibility — a hot-resize down would NOT recover it.
    static let shared = BatchAutoscaler(
        onReturnToOne: { model in
            await MLXBatchAdapter.Registry.shared.shutdownEngineIfIdle(for: model)
        }
    )

    typealias NowProvider = @Sendable () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async -> Void

    private struct ModelState {
        /// Sliding window of (timestamp, pending+active) demand samples;
        /// pruned to `windowSeconds` on every touch.
        var samples: [(at: TimeInterval, demand: Int)] = []
        var recommendation = 1
        /// Last tier cap seen from the resolution path; used only for the
        /// decay-side change log line.
        var lastTierCap = 1
        /// Set when the recommendation returned to 1 but the engine teardown
        /// (which restores compile eligibility) has not succeeded yet — e.g.
        /// the engine was still busy. The decay loop retries until it lands.
        var pendingTeardown = false
        var decayTask: Task<Void, Never>?
    }

    private let windowSeconds: TimeInterval
    /// Retry cadence for a return-to-1 teardown that found the engine busy.
    private let teardownRetrySeconds: TimeInterval
    private let now: NowProvider
    private let sleep: Sleeper
    private let onReturnToOne: @Sendable (String) async -> Bool
    private var states: [String: ModelState] = [:]

    /// Recommendation-change log lines, oldest first, capped. Exists so
    /// tests can assert the change-gated logging (one line per CHANGE, none
    /// for repeats) without scraping os.log.
    private(set) var recentChangeLogs: [String] = []

    /// - Parameters:
    ///   - windowSeconds: quiet interval that must elapse before decay.
    ///   - now: injectable clock (monotonic seconds) for tests.
    ///   - sleep: injectable suspension for the decay loop, so tests never
    ///     wait wall-clock time.
    ///   - onReturnToOne: teardown hook run off the request path when the
    ///     recommendation decays to 1. Returns whether teardown completed
    ///     (false = engine busy, retry later).
    init(
        windowSeconds: TimeInterval = 60,
        teardownRetrySeconds: TimeInterval = 10,
        now: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping Sleeper = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        },
        onReturnToOne: @escaping @Sendable (String) async -> Bool
    ) {
        self.windowSeconds = windowSeconds
        self.teardownRetrySeconds = teardownRetrySeconds
        self.now = now
        self.sleep = sleep
        self.onReturnToOne = onReturnToOne
    }

    // MARK: - Signal intake

    /// Record one submission's observed concurrent demand
    /// (`pendingAndActive` = the engine's pending+active counts including
    /// this submission). Called from `MLXBatchAdapter.generate` BEFORE the
    /// solo lease — after the lease, single-slot serialization makes the
    /// counts read 1 forever and overlap would never be observed.
    func recordSubmission(model: String, pendingAndActive: Int) {
        var state = states[model] ?? ModelState()
        let timestamp = now()
        state.samples.append((at: timestamp, demand: max(pendingAndActive, 1)))
        prune(&state, at: timestamp)
        states[model] = state
        if pendingAndActive > 1 {
            scheduleDecayLoop(for: model)
        }
    }

    // MARK: - Recommendation

    /// Current recommendation for `model` under the hardware `tierCap`.
    /// Logs one line on every recommendation CHANGE (never on repeats).
    func recommendedBatchSize(for model: String, tierCap: Int) -> Int {
        var state = states[model] ?? ModelState()
        let timestamp = now()
        prune(&state, at: timestamp)
        state.lastTierCap = tierCap
        let windowMax = state.samples.map(\.demand).max() ?? 0
        let previous = state.recommendation
        let next = BatchAutoscalerPolicy.decision(
            windowMax: windowMax,
            tierCap: tierCap,
            previous: previous
        )
        if next != previous {
            logChange(model: model, from: previous, to: next, windowMax: windowMax, tierCap: tierCap)
            if next == 1 {
                // Decayed on a read. The engine (resized up during the
                // burst) is running uncompiled; flag it for the off-path
                // teardown so the next quiet-moment rebuild restores the
                // compiled single-slot path.
                state.pendingTeardown = true
            }
        }
        state.recommendation = next
        states[model] = state
        if next > 1 || state.pendingTeardown {
            scheduleDecayLoop(for: model)
        }
        return next
    }

    // MARK: - Decay

    /// One decay evaluation. Internal (not private) so tests can drive it
    /// directly with an advanced injected clock instead of sleeping.
    func sweep(model: String) async {
        guard var state = states[model] else { return }
        let timestamp = now()
        prune(&state, at: timestamp)
        let windowMax = state.samples.map(\.demand).max() ?? 0
        if windowMax <= 1, state.recommendation > 1 {
            logChange(
                model: model,
                from: state.recommendation,
                to: 1,
                windowMax: windowMax,
                tierCap: state.lastTierCap
            )
            state.recommendation = 1
            state.pendingTeardown = true
        }
        states[model] = state
        guard windowMax <= 1, state.pendingTeardown else { return }
        // Off-request-path teardown. `onReturnToOne` (Registry
        // `shutdownEngineIfIdle`) declines while the engine has pending or
        // active work; the loop retries on `teardownRetrySeconds`. The actor
        // suspends across the await, so re-read state before mutating.
        let done = await onReturnToOne(model)
        if done {
            states[model]?.pendingTeardown = false
        }
    }

    /// Idempotent: at most one decay loop per model. The loop re-computes
    /// its own wake-up point each iteration, so new samples never need to
    /// cancel/reschedule it.
    private func scheduleDecayLoop(for model: String) {
        guard states[model] != nil, states[model]?.decayTask == nil else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.decayLoop(model: model)
        }
        states[model]?.decayTask = task
    }

    private func decayLoop(model: String) async {
        while !Task.isCancelled {
            guard let delay = nextDecayDelay(for: model) else { break }
            await sleep(delay)
            if Task.isCancelled { break }
            await sweep(model: model)
        }
        states[model]?.decayTask = nil
    }

    /// Seconds until the next decay check, or `nil` when no decay work
    /// remains (recommendation already 1 and no teardown owed).
    private func nextDecayDelay(for model: String) -> TimeInterval? {
        guard var state = states[model] else { return nil }
        let timestamp = now()
        prune(&state, at: timestamp)
        states[model] = state
        if let lastOverlapAt = state.samples.filter({ $0.demand > 1 }).map(\.at).max() {
            // Wake just after the newest overlap sample ages out of the
            // window — the earliest instant decay could apply.
            return max(lastOverlapAt + windowSeconds - timestamp, 0.05)
        }
        if state.recommendation > 1 {
            // Quiet window already elapsed; sweep imminently.
            return 0.05
        }
        if state.pendingTeardown {
            return teardownRetrySeconds
        }
        return nil
    }

    // MARK: - Helpers

    private func prune(_ state: inout ModelState, at timestamp: TimeInterval) {
        state.samples.removeAll { timestamp - $0.at >= windowSeconds }
    }

    private func logChange(model: String, from: Int, to: Int, windowMax: Int, tierCap: Int) {
        let line = "[Osaurus] autobatch: model=\(model) \(from)→\(to) (windowMax=\(windowMax), tierCap=\(tierCap))"
        autoBatchLog.notice("\(line, privacy: .public)")
        recentChangeLogs.append(line)
        if recentChangeLogs.count > 32 {
            recentChangeLogs.removeFirst(recentChangeLogs.count - 32)
        }
    }
}
