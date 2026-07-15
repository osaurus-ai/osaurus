//
//  CrossModelBandwidthBudgeter.swift
//  osaurus
//
//  Cross-model decode admission budgeter for big-RAM machines running
//  multiple models concurrently (`manualMultiModel` eviction policy).
//
//  Why: concurrent decodes on *different* models share one unified-memory
//  bus. Each decode step of a dense model streams (roughly) that model's
//  full weights, so N concurrent cross-model decodes each run at ~1/N of
//  the bus — for interactive use, serialized fast turns beat N uniformly
//  slow streams. This budgeter holds a new generation while the aggregate
//  weight-streaming demand of the models already decoding, plus the
//  incoming model's, exceeds what the bus can stream in one second.
//
//  Honest rationale for the admission rule: it is a coarse proportional
//  guard, not a scheduler. "Weights bytes per active model ≤ 0.7 × spec
//  bandwidth × 1 s" is a proxy — it does not model MoE sparsity, KV-cache
//  traffic, prefill bursts, or actual achieved bandwidth. It exists only
//  to stop the pathological case (several large models decoding at once,
//  all crawling); everything subtler is out of scope.
//
//  Scope boundaries:
//   * Same-model concurrency is NOT this budgeter's business —
//     `BatchEngine` (and its autoscaler) owns intra-model batching, and
//     concurrent streams on one model share a single weight-streaming
//     pass. A request for a model that is already decoding therefore adds
//     no marginal cross-model demand and normally bypasses the queue —
//     but the bypass is BOUNDED, not absolute: once the FIFO head has
//     been waiting longer than `headStarvationLimit`, same-model requests
//     enqueue normally, so continuous same-model traffic cannot park a
//     cross-model waiter indefinitely (each bypass keeps the model in
//     `active`; the head only fits once that model drains).
//   * Only active behind the `ai.osaurus.perf.crossModelBudgeter` flag
//     (default false, dark launch) AND `manualMultiModel` eviction AND a
//     known host bandwidth AND ≥ 96 GiB RAM. Single-model machines and
//     default strict-eviction setups never reach `acquire`.
//
//  Waiting pattern mirrors `MLXBatchAdapter.SoloGenerationGate`: FIFO
//  continuation queue, no timeout (a generation always finishes or is
//  cancelled), cancellation of a waiting task removes it from the queue.
//

import Foundation
import os

private let budgeterLog = Logger(subsystem: "ai.osaurus", category: "BandwidthBudgeter")

actor CrossModelBandwidthBudgeter {
    static let shared = CrossModelBandwidthBudgeter()

    typealias NowProvider = @Sendable () -> TimeInterval

    /// Injectable monotonic clock (seconds) so the head-starvation aging
    /// rule is testable without wall-clock waits.
    private let now: NowProvider

    init(now: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    // MARK: - Gating (pure, unit-tested)

    /// Dark-launch flag. Off by default; wiring in `ModelRuntime` checks it
    /// before doing any other work, so flag-off is a provable no-op.
    static let flagKey = "ai.osaurus.perf.crossModelBudgeter"

    /// Cross-model concurrency only makes sense on machines that can hold
    /// several large models resident; below this the eviction policy and
    /// RAM feasibility gates dominate anyway.
    static let minimumPhysicalMemoryBytes: UInt64 = 96 << 30  // 96 GiB

    /// Fraction of spec bandwidth treated as streamable by decode. Matches
    /// `decodeEfficiency` in the bandwidth-calibration PR: measured memcpy
    /// achieves 60–75% of the spec sheet, and decode's access pattern is
    /// close to memcpy.
    static let streamableBandwidthFraction = 0.7

    /// Aging bound on the zero-marginal-demand (same-model) fast path:
    /// once the FIFO head has been waiting longer than this, same-model
    /// requests stop bypassing the queue and enqueue behind it. Without
    /// the bound, CONTINUOUS same-model traffic starves the head forever —
    /// every bypass keeps that model registered in `active`, and the head
    /// only fits once the model drains. 60 s is generous next to
    /// interactive decode turns (seconds), so the bypass keeps its
    /// serialization win for normal bursts while bounding a parked
    /// waiter's worst case to roughly one starvation window plus the
    /// in-flight streams' remaining decode time.
    static let headStarvationLimit: TimeInterval = 60

    static var isFlagEnabled: Bool { isFlagEnabled(in: .standard) }

    static func isFlagEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: flagKey)
    }

    /// Full gate. All four conditions must hold; each `false` leg keeps the
    /// budgeter provably inert for that class of machine/config.
    static func isActive(
        flagEnabled: Bool,
        policy: ModelEvictionPolicy,
        bandwidthGBps: Double?,
        physicalMemoryBytes: UInt64
    ) -> Bool {
        guard flagEnabled else { return false }
        guard policy == .manualMultiModel else { return false }
        guard let bandwidth = bandwidthGBps, bandwidth > 0 else { return false }
        return physicalMemoryBytes >= minimumPhysicalMemoryBytes
    }

    /// Bytes of weights the bus can stream in one second at the guarded
    /// fraction — the admission budget.
    static func budgetBytes(bandwidthGBps: Double) -> Int64 {
        Int64(bandwidthGBps * 1e9 * streamableBandwidthFraction)
    }

    // MARK: - Host bandwidth (spec table)

    /// Spec-sheet unified-memory bandwidth (GB/s) by exact brand string.
    ///
    /// This base branch's `ChipProfile` carries no bandwidth fields, so the
    /// table is embedded here. It is a copy of
    /// `ChipProfileCalibration.specBandwidthGBps` on the
    /// `mlx-perf/bandwidth-calibration` PR — when that lands, prefer its
    /// measured record (`ChipProfileCalibration.measuredBandwidthGBps`)
    /// over this table and delete this copy. Where Apple shipped binned
    /// variants (e.g. M3 Max 300/400) the table carries the full-fat
    /// number; the 0.7 streamable fraction absorbs the optimism.
    static func specBandwidthGBps(brandString: String) -> Double? {
        let table: [String: Double] = [
            "Apple M1": 68, "Apple M1 Pro": 200, "Apple M1 Max": 400, "Apple M1 Ultra": 800,
            "Apple M2": 100, "Apple M2 Pro": 200, "Apple M2 Max": 400, "Apple M2 Ultra": 800,
            "Apple M3": 100, "Apple M3 Pro": 150, "Apple M3 Max": 400, "Apple M3 Ultra": 819,
            "Apple M4": 120, "Apple M4 Pro": 273, "Apple M4 Max": 546,
            "Apple M5": 153, "Apple M5 Pro": 307, "Apple M5 Max": 614,
        ]
        return table[brandString.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Bandwidth used for the budget: measured when a calibration source
    /// exists (none on this base — see `specBandwidthGBps` doc), otherwise
    /// the spec table, otherwise nil (which fails the gate).
    static func hostBandwidthGBps(profile: ChipProfile) -> Double? {
        specBandwidthGBps(brandString: profile.brandString)
    }

    // MARK: - Lease

    /// One-shot, idempotent release handle for an admitted generation.
    /// Same shape as `HTTPInferenceAdmission.Token`: multiple exit paths in
    /// `generateEventStream` may race to release; only the first call
    /// decrements the budgeter.
    final class Lease: @unchecked Sendable {
        private let releasedOnce = OSAllocatedUnfairLock(initialState: false)
        private let budgeter: CrossModelBandwidthBudgeter
        private let modelName: String

        fileprivate init(budgeter: CrossModelBandwidthBudgeter, modelName: String) {
            self.budgeter = budgeter
            self.modelName = modelName
        }

        func release() async {
            let shouldRelease = releasedOnce.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if shouldRelease { await budgeter.release(modelName: modelName) }
        }
    }

    // MARK: - State

    private struct ActiveModel {
        var streams: Int
        /// Weights bytes recorded at first admission of this model; the
        /// demand proxy for every concurrent stream on it (weights are
        /// streamed once per decode step regardless of stream count).
        var weightsBytes: Int64
    }

    private struct Waiter {
        let id: UInt64
        let modelName: String
        let weightsBytes: Int64
        let budgetBytes: Int64
        /// When this waiter entered the FIFO queue (monotonic seconds).
        /// The queue is strict FIFO, so for the head this is exactly when
        /// its wait started — the input to the `headStarvationLimit`
        /// aging rule.
        let enqueuedAt: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Models with at least one admitted generation, keyed by model name.
    private var active: [String: ActiveModel] = [:]
    /// FIFO admission queue. Head is admitted first; a non-fitting head
    /// blocks everything behind it (no skipping) so large models cannot be
    /// starved by a stream of small ones.
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    // MARK: - Admission

    /// Admit one generation on `modelName`, suspending (FIFO) while the
    /// aggregate cross-model weight-streaming demand exceeds `budgetBytes`.
    ///
    /// Admission rule: admit immediately when the request adds no marginal
    /// cross-model demand (no other model is active, or this model is
    /// already decoding) AND the queue head is not starving — once the head
    /// has waited past `headStarvationLimit`, same-model requests enqueue
    /// normally so continuous same-model traffic cannot bypass the FIFO
    /// forever. Otherwise admit when
    /// Σ weights of distinct active models + `weightsBytes` ≤ `budgetBytes`,
    /// and only when no earlier waiter is still queued (strict FIFO).
    ///
    /// Throws `CancellationError` when the waiting task is cancelled; the
    /// waiter is removed from the queue and no lease is held.
    func acquire(
        modelName: String,
        weightsBytes: Int64,
        budgetBytes: Int64
    ) async throws -> Lease {
        if zeroMarginalDemand(modelName: modelName), !headIsStarving() {
            register(modelName: modelName, weightsBytes: weightsBytes)
            return Lease(budgeter: self, modelName: modelName)
        }
        if waiters.isEmpty,
            fitsBudget(modelName: modelName, weightsBytes: weightsBytes, budgetBytes: budgetBytes) {
            register(modelName: modelName, weightsBytes: weightsBytes)
            return Lease(budgeter: self, modelName: modelName)
        }

        let id = nextWaiterID
        nextWaiterID += 1
        logHolding(modelName: modelName, budgetBytes: budgetBytes)

        // Ordering note: the continuation body below runs synchronously in
        // this actor job, and `onCancel` only *spawns* a task that must hop
        // onto this actor — so `cancelWaiter` always observes the waiter
        // already enqueued (or already admitted, in which case it is a
        // harmless no-op). No pre-enqueue-cancellation bookkeeping needed.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
                waiters.append(
                    Waiter(
                        id: id,
                        modelName: modelName,
                        weightsBytes: weightsBytes,
                        budgetBytes: budgetBytes,
                        enqueuedAt: now(),
                        continuation: cc
                    ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }

        // Admitted-then-cancelled race: the wake beat the cancellation
        // handler. Hand the slot back rather than starting doomed work.
        if Task.isCancelled {
            release(modelName: modelName)
            throw CancellationError()
        }
        return Lease(budgeter: self, modelName: modelName)
    }

    // MARK: - Release

    private func release(modelName: String) {
        guard var entry = active[modelName] else { return }
        entry.streams -= 1
        if entry.streams <= 0 {
            active[modelName] = nil
        } else {
            active[modelName] = entry
        }
        admitEligibleWaiters()
    }

    // MARK: - Internals

    /// True when admitting `modelName` adds no cross-model weight-streaming
    /// demand: nothing else is decoding, or this model already is (its
    /// weights are already being streamed; intra-model concurrency belongs
    /// to `BatchEngine`). On the `acquire` fast path this bypass is gated
    /// by `headIsStarving()` — see `headStarvationLimit`.
    private func zeroMarginalDemand(modelName: String) -> Bool {
        if active.isEmpty { return true }
        if active[modelName] != nil { return true }
        return false
    }

    /// True when the FIFO head has been waiting longer than
    /// `headStarvationLimit`. Only consulted by `acquire`'s fast path;
    /// `admitEligibleWaiters` keeps using `zeroMarginalDemand` unguarded —
    /// admitting the HEAD is FIFO progress, never starvation.
    private func headIsStarving() -> Bool {
        guard let head = waiters.first else { return false }
        return now() - head.enqueuedAt > Self.headStarvationLimit
    }

    private func fitsBudget(modelName: String, weightsBytes: Int64, budgetBytes: Int64) -> Bool {
        aggregateActiveWeights(excluding: modelName) + weightsBytes <= budgetBytes
    }

    /// Σ weights over distinct active models (each model counted once, not
    /// once per stream — see `ActiveModel.weightsBytes`).
    private func aggregateActiveWeights(excluding modelName: String) -> Int64 {
        active.reduce(Int64(0)) { sum, entry in
            entry.key == modelName ? sum : sum + entry.value.weightsBytes
        }
    }

    private func register(modelName: String, weightsBytes: Int64) {
        if var entry = active[modelName] {
            entry.streams += 1
            active[modelName] = entry
        } else {
            active[modelName] = ActiveModel(streams: 1, weightsBytes: weightsBytes)
        }
    }

    /// Admit the queue head while it fits, strictly in FIFO order. Called
    /// after every release and after a waiter cancellation (removing a
    /// blocked head can unblock the next waiter).
    private func admitEligibleWaiters() {
        while let head = waiters.first {
            let admissible =
                zeroMarginalDemand(modelName: head.modelName)
                || fitsBudget(
                    modelName: head.modelName,
                    weightsBytes: head.weightsBytes,
                    budgetBytes: head.budgetBytes
                )
            guard admissible else { return }
            waiters.removeFirst()
            register(modelName: head.modelName, weightsBytes: head.weightsBytes)
            head.continuation.resume()
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        admitEligibleWaiters()
    }

    /// One line, on first wait per request (a request enqueues at most once).
    private func logHolding(modelName: String, budgetBytes: Int64) {
        let activeSummary =
            active
            .sorted { $0.key < $1.key }
            .map { "\($0.key)@\(Self.formatGB(Double($0.value.weightsBytes) / 1e9))GB" }
            .joined(separator: ", ")
        let budget = Self.formatGB(Double(budgetBytes) / 1e9)
        budgeterLog.notice(
            "budgeter: holding model=\(modelName, privacy: .public) (active: \(activeSummary, privacy: .public); budget \(budget, privacy: .public)GB/s)"
        )
    }

    private static func formatGB(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - Test seams (inspection only)

    var activeModelNamesForTesting: [String] { active.keys.sorted() }
    var activeStreamCountForTesting: Int { active.values.reduce(0) { $0 + $1.streams } }
    var waiterCountForTesting: Int { waiters.count }
}
