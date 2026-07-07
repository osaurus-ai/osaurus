//
//  CrossModelBandwidthBudgeterTests.swift
//  osaurus
//
//  Admission math, FIFO waiting, wake-on-release, and cancellation for
//  `CrossModelBandwidthBudgeter`, plus the gate legs that keep it a
//  provable no-op for default setups. Every test uses a fresh budgeter
//  instance with injected weights/budgets — no real models, no ChipProfile
//  probing, no shared state.
//
//  Parked-waiter assertions use the `AtomicBoolFlag` + short-sleep pattern
//  from `InferenceLoadCoordinatorTests` (which mirrors `ModelLeaseTests`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CrossModelBandwidthBudgeterTests {
    /// 1 decimal GB in bytes, matching the budgeter's 1e9 accounting.
    private static let GB: Int64 = 1_000_000_000

    // MARK: - Gate (zero-behavior-change legs)

    @Test func gate_flag_off_is_passthrough_even_on_ideal_hardware() {
        let active = CrossModelBandwidthBudgeter.isActive(
            flagEnabled: false,
            policy: .manualMultiModel,
            bandwidthGBps: 546,
            physicalMemoryBytes: 128 << 30
        )
        #expect(!active)
    }

    @Test func gate_strict_single_model_is_passthrough() {
        let active = CrossModelBandwidthBudgeter.isActive(
            flagEnabled: true,
            policy: .strictSingleModel,
            bandwidthGBps: 546,
            physicalMemoryBytes: 128 << 30
        )
        #expect(!active)
    }

    @Test func gate_requires_known_positive_bandwidth() {
        #expect(
            !CrossModelBandwidthBudgeter.isActive(
                flagEnabled: true,
                policy: .manualMultiModel,
                bandwidthGBps: nil,
                physicalMemoryBytes: 128 << 30
            ))
        #expect(
            !CrossModelBandwidthBudgeter.isActive(
                flagEnabled: true,
                policy: .manualMultiModel,
                bandwidthGBps: 0,
                physicalMemoryBytes: 128 << 30
            ))
    }

    @Test func gate_requires_96_gib_ram() {
        #expect(
            !CrossModelBandwidthBudgeter.isActive(
                flagEnabled: true,
                policy: .manualMultiModel,
                bandwidthGBps: 546,
                physicalMemoryBytes: (96 << 30) - 1
            ))
        #expect(
            CrossModelBandwidthBudgeter.isActive(
                flagEnabled: true,
                policy: .manualMultiModel,
                bandwidthGBps: 546,
                physicalMemoryBytes: 96 << 30
            ))
    }

    @Test func flag_defaults_to_false() {
        let suiteName = "ai.osaurus.tests.crossModelBudgeter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!CrossModelBandwidthBudgeter.isFlagEnabled(in: defaults))
        defaults.set(true, forKey: CrossModelBandwidthBudgeter.flagKey)
        #expect(CrossModelBandwidthBudgeter.isFlagEnabled(in: defaults))
    }

    @Test func budget_is_seventy_percent_of_one_second_of_bandwidth() {
        let budget = CrossModelBandwidthBudgeter.budgetBytes(bandwidthGBps: 546)
        #expect(budget == Int64(546.0 * 1e9 * 0.7))
    }

    @Test func spec_table_knows_shipping_chips_and_rejects_unknowns() {
        #expect(CrossModelBandwidthBudgeter.specBandwidthGBps(brandString: "Apple M4 Max") == 546)
        #expect(CrossModelBandwidthBudgeter.specBandwidthGBps(brandString: "Apple M1") == 68)
        #expect(CrossModelBandwidthBudgeter.specBandwidthGBps(brandString: "Intel Core i9") == nil)
        #expect(CrossModelBandwidthBudgeter.specBandwidthGBps(brandString: "VirtualApple M2") == nil)
    }

    // MARK: - Admission math

    @Test func only_active_model_admits_even_when_over_budget() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let lease = try await budgeter.acquire(
            modelName: "A", weightsBytes: 200 * Self.GB, budgetBytes: 100 * Self.GB)
        let activeNames = await budgeter.activeModelNamesForTesting
        let waiters = await budgeter.waiterCountForTesting
        #expect(activeNames == ["A"])
        #expect(waiters == 0)
        await lease.release()
    }

    @Test func second_model_admits_when_aggregate_fits_budget() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)
        let leaseB = try await budgeter.acquire(
            modelName: "B", weightsBytes: 40 * Self.GB, budgetBytes: 100 * Self.GB)
        let activeNames = await budgeter.activeModelNamesForTesting
        #expect(activeNames == ["A", "B"])
        await leaseA.release()
        await leaseB.release()
    }

    @Test func over_budget_second_model_waits_and_release_wakes_it() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)

        let admitted = AtomicBoolFlag()
        let waiterTask = Task<Bool, Never> {
            guard
                let lease = try? await budgeter.acquire(
                    modelName: "B", weightsBytes: 50 * Self.GB, budgetBytes: 100 * Self.GB)
            else { return false }
            admitted.set()
            await lease.release()
            return true
        }

        // Give the waiter time to park; without this we can race the
        // enqueue and assert before it actually parks.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!admitted.value)
        let parked = await budgeter.waiterCountForTesting
        #expect(parked == 1)

        await leaseA.release()
        let succeeded = await waiterTask.value
        #expect(succeeded)
        #expect(admitted.value)
        let remaining = await budgeter.activeStreamCountForTesting
        #expect(remaining == 0)
    }

    @Test func same_model_stream_admits_immediately_even_at_budget_ceiling() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA1 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)
        let leaseB = try await budgeter.acquire(
            modelName: "B", weightsBytes: 40 * Self.GB, budgetBytes: 100 * Self.GB)
        // Aggregate is exactly at the ceiling; a second stream on an
        // already-decoding model adds no cross-model demand and must not
        // queue (BatchEngine owns same-model concurrency).
        let leaseA2 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)
        let waiters = await budgeter.waiterCountForTesting
        let streams = await budgeter.activeStreamCountForTesting
        #expect(waiters == 0)
        #expect(streams == 3)
        await leaseA1.release()
        await leaseA2.release()
        await leaseB.release()
    }

    @Test func aggregate_counts_each_model_once_not_per_stream() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA1 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)
        let leaseA2 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)
        // Two streams on A demand 60 GB (one weight-streaming pass), not
        // 120 GB — B at 30 GB must still fit.
        let leaseB = try await budgeter.acquire(
            modelName: "B", weightsBytes: 30 * Self.GB, budgetBytes: 100 * Self.GB)
        let waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 0)
        await leaseA1.release()
        await leaseA2.release()
        await leaseB.release()
    }

    // MARK: - FIFO

    @Test func waiters_admit_in_fifo_order_without_skipping() async throws {
        // Budget 95: C (30) fits alongside A (60) but not alongside B (70),
        // so every admission is forced into a distinct, observable step.
        let budgeter = CrossModelBandwidthBudgeter()
        let order = AdmissionOrder()
        let leaseA = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 95 * Self.GB)

        // B (70 GB) cannot fit alongside A (130 > 95) and parks.
        let taskB = Task<CrossModelBandwidthBudgeter.Lease?, Never> {
            let lease = try? await budgeter.acquire(
                modelName: "B", weightsBytes: 70 * Self.GB, budgetBytes: 95 * Self.GB)
            if lease != nil { await order.record("B") }
            return lease
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        var waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 1)

        // C (30 GB) WOULD fit alongside A (90 ≤ 95) but must queue behind
        // B — the head blocks everything behind it so large models cannot
        // be starved by a stream of small ones.
        let admittedC = AtomicBoolFlag()
        let taskC = Task<Void, Never> {
            guard
                let lease = try? await budgeter.acquire(
                    modelName: "C", weightsBytes: 30 * Self.GB, budgetBytes: 95 * Self.GB)
            else { return }
            admittedC.set()
            await order.record("C")
            await lease.release()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 2)
        #expect(!admittedC.value)

        // Releasing A admits B (70 ≤ 95); C stays parked (70 + 30 > 95).
        await leaseA.release()
        let leaseB = await taskB.value
        #expect(leaseB != nil)
        waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 1)
        #expect(!admittedC.value)

        // Releasing B finally admits C.
        await leaseB?.release()
        await taskC.value
        let recorded = await order.entries
        #expect(recorded == ["B", "C"])
    }

    // MARK: - Cancellation

    @Test func cancelling_a_waiting_task_removes_it_from_the_queue() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)

        let threwCancellation = AtomicBoolFlag()
        let taskB = Task<Void, Never> {
            do {
                let lease = try await budgeter.acquire(
                    modelName: "B", weightsBytes: 50 * Self.GB, budgetBytes: 100 * Self.GB)
                await lease.release()
            } catch is CancellationError {
                threwCancellation.set()
            } catch {}
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        var waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 1)

        taskB.cancel()
        await taskB.value
        #expect(threwCancellation.value)
        waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 0)

        // The cancelled waiter must not hold a slot: releasing A leaves the
        // budgeter fully drained.
        await leaseA.release()
        let streams = await budgeter.activeStreamCountForTesting
        #expect(streams == 0)
    }

    @Test func cancelling_a_blocked_head_unblocks_the_waiter_behind_it() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA = try await budgeter.acquire(
            modelName: "A", weightsBytes: 60 * Self.GB, budgetBytes: 100 * Self.GB)

        let taskB = Task<Void, Never> {
            _ = try? await budgeter.acquire(
                modelName: "B", weightsBytes: 50 * Self.GB, budgetBytes: 100 * Self.GB)
        }
        // Park B before spawning C — otherwise C (which fits alongside A)
        // could reach the budgeter first and be admitted immediately.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let admittedC = AtomicBoolFlag()
        let taskC = Task<Void, Never> {
            guard
                let lease = try? await budgeter.acquire(
                    modelName: "C", weightsBytes: 30 * Self.GB, budgetBytes: 100 * Self.GB)
            else { return }
            admittedC.set()
            await lease.release()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let waiters = await budgeter.waiterCountForTesting
        #expect(waiters == 2)

        // Removing the blocked head re-evaluates the queue: C fits
        // alongside A (90 ≤ 100) and is admitted.
        taskB.cancel()
        await taskB.value
        await taskC.value
        #expect(admittedC.value)

        await leaseA.release()
        let streams = await budgeter.activeStreamCountForTesting
        #expect(streams == 0)
    }

    // MARK: - Lease semantics

    @Test func double_release_is_idempotent() async throws {
        let budgeter = CrossModelBandwidthBudgeter()
        let leaseA1 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 10 * Self.GB, budgetBytes: 100 * Self.GB)
        let leaseA2 = try await budgeter.acquire(
            modelName: "A", weightsBytes: 10 * Self.GB, budgetBytes: 100 * Self.GB)

        await leaseA1.release()
        await leaseA1.release()  // intentional double release
        let streams = await budgeter.activeStreamCountForTesting
        #expect(streams == 1)
        await leaseA2.release()
        let drained = await budgeter.activeStreamCountForTesting
        #expect(drained == 0)
    }
}

/// Records admission order across concurrent waiter tasks.
private actor AdmissionOrder {
    private(set) var entries: [String] = []
    func record(_ name: String) { entries.append(name) }
}

// `AtomicBoolFlag` is intentionally duplicated from
// `InferenceLoadCoordinatorTests.swift` / `ModelLeaseTests.swift` (where it
// is `private`) — per the note there, a tiny local race-flag helper isn't
// worth a shared test-utility module.
private final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
