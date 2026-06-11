//
//  LifecycleConcurrencyTests.swift
//  osaurus
//
//  Executable (not source-text) coverage for the regression-prone lifecycle +
//  concurrency primitives introduced by the hang/stability audit:
//
//    * `runWithDeadline` — the bounded best-effort timeout that lets the quit
//      teardown abandon a stalled step instead of hanging exit.
//    * `ModelLease.waitForZero(timeoutSeconds:)` — the timed lease drain the
//      quit path uses so a never-released generation can't strand `clearAll`.
//    * `HTTPInferenceAdmission` — the HTTP-layer fan-out gate that returns 503
//      instead of oversubscribing MLX.
//
//  These complement the source-text assertions in `RuntimePolicySourceTests`,
//  which only check that the wiring *exists*; here we actually run the code.
//

import Foundation
import Testing

@testable import OsaurusCore

struct LifecycleConcurrencyTests {

    // MARK: - runWithDeadline

    @Test func deadline_completes_within_budget_returns_true() async {
        // Budget is intentionally generous: CI runners can be CPU-starved
        // enough that even scheduling the child task takes seconds. A tight
        // budget would flake; a 50ms op finishing inside 30s still proves the
        // "completes within budget" path.
        let completed = await runWithDeadline(seconds: 30.0) {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        #expect(completed == true)
    }

    @Test func deadline_times_out_and_unblocks_caller() async {
        let completed = await runWithDeadline(seconds: 0.2) {
            // Far longer than the deadline; the caller must not wait for it.
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
        }
        // The deadline won the race, so the operation did not complete first —
        // that is the contract. Wall-clock latency is intentionally not
        // asserted: the Dispatch deadline fires on time, but resuming this
        // test's task after the await needs a cooperative-pool thread, and a
        // loaded CI runner can delay that resumption past any fixed ceiling
        // (observed ~17s), flaking the test. A genuine "blocked on the full
        // operation" regression still fails the check below — that path returns
        // `true`.
        #expect(completed == false)
    }

    // MARK: - ModelLease timed drain (load-cancellation / quit path)

    @Test func lease_timed_wait_returns_false_when_never_released() async {
        let name = "test-lease-\(UUID().uuidString)"
        await ModelLease.shared.acquire(name)
        let drained = await ModelLease.shared.waitForZero(name, timeoutSeconds: 0.2)
        // Never released, so the bounded wait must report failure rather than
        // hang. Wall-clock latency is intentionally not asserted — see the note
        // in `deadline_times_out_and_unblocks_caller`; a loaded CI runner can
        // delay this task's post-await resumption and flake a fixed ceiling.
        #expect(drained == false)
        #expect(await ModelLease.shared.count(for: name) == 1)
        // Cleanup so the shared actor doesn't carry state into other suites.
        await ModelLease.shared.release(name)
    }

    @Test func lease_timed_wait_returns_true_when_released_in_time() async {
        let name = "test-lease-\(UUID().uuidString)"
        await ModelLease.shared.acquire(name)
        defer {
            Task {
                if await ModelLease.shared.count(for: name) > 0 {
                    await ModelLease.shared.release(name)
                }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            await ModelLease.shared.release(name)
        }
        let drained = await ModelLease.shared.waitForZero(name, timeoutSeconds: 30.0)
        #expect(drained == true)
        #expect(await ModelLease.shared.count(for: name) == 0)
    }

    // MARK: - HTTP inference admission (fan-out backpressure)

    @Test func admission_rejects_beyond_limit_and_releases_slots() {
        let gate = HTTPInferenceAdmission()
        #expect(gate.tryAcquire(limit: 2))
        #expect(gate.tryAcquire(limit: 2))
        // At capacity — the next acquire is refused.
        #expect(gate.tryAcquire(limit: 2) == false)
        #expect(gate.inflightCount == 2)

        // Releasing one frees exactly one slot.
        gate.release()
        #expect(gate.tryAcquire(limit: 2))
        #expect(gate.inflightCount == 2)

        gate.release()
        gate.release()
        #expect(gate.inflightCount == 0)
    }

    @Test func admission_never_exceeds_limit_under_concurrent_fanout() async {
        let gate = HTTPInferenceAdmission()
        let limit = 8

        // Fan out far more concurrent acquires than the ceiling; with no
        // releases, exactly `limit` must succeed and the rest must be refused.
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 256 {
                group.addTask { gate.tryAcquire(limit: limit) }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }

        #expect(admitted == limit)
        #expect(gate.inflightCount == limit)
    }

    // MARK: - LaunchGuard tiering

    @Test @MainActor func launchguard_features_are_distinct_composable_bits() {
        // The crash-count → tier mapping is private; what we can pin here is the
        // public `Feature` option-set contract the tiers are built from: each
        // feature is a distinct bit and they compose into an unambiguous
        // safe-mode set.
        let plugins = LaunchGuard.Feature.plugins
        let sandbox = LaunchGuard.Feature.sandbox
        let distill = LaunchGuard.Feature.distillation
        let autoLoad = LaunchGuard.Feature.autoModelLoad

        // Distinct bits so combined safe-mode sets are unambiguous.
        #expect(plugins.rawValue != sandbox.rawValue)
        #expect(sandbox.rawValue != distill.rawValue)
        #expect(distill.rawValue != autoLoad.rawValue)

        var combined: LaunchGuard.Feature = []
        combined.insert(plugins)
        combined.insert(sandbox)
        #expect(combined.contains(.plugins))
        #expect(combined.contains(.sandbox))
        #expect(!combined.contains(.autoModelLoad))
    }
}
