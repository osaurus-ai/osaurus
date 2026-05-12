//
//  DistillationCoordinatorTests.swift
//  osaurus
//
//  Tests focus on the *coordination* primitives (single-flight queue,
//  chat-idle wait bypass, requireResident bypass). The residency-true
//  path depends on `MemoryService.canDistillCheaply` which wires through
//  `ChatConfigurationStore`, `ModelManager`, and `ModelRuntime` —
//  setting that up cleanly in a unit test would be more scaffolding
//  than the value justifies, so it's covered manually + via the
//  diagnostics panel rather than here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DistillationCoordinatorTests {

    @Test func snapshot_defaults_to_idle() async {
        let coord = DistillationCoordinator.shared
        let snap = await coord.snapshot()
        #expect(snap.queued == 0)
        #expect(!snap.active)
    }

    @Test func run_executes_body_when_residency_disabled() async {
        let coord = DistillationCoordinator.shared
        let observer = ConcurrencyObserver()

        await coord.run(chatIdleWaitMs: 0, requireResident: false) {
            await observer.enter()
            await observer.exit()
        }

        let total = await observer.totalEntries
        #expect(total == 1)

        let snap = await coord.snapshot()
        #expect(snap.queued == 0)
        #expect(!snap.active)
    }

    @Test func concurrent_runs_serialize_strictly() async {
        let coord = DistillationCoordinator.shared
        // Drain anything still chained from a previous test before we
        // start observing — `currentTask` could otherwise hold a
        // reference whose await delays the first run far longer than
        // the body's own sleep.
        await coord.run(chatIdleWaitMs: 0, requireResident: false) {}

        let observer = ConcurrencyObserver()

        async let first: Void = coord.run(chatIdleWaitMs: 0, requireResident: false) {
            await observer.enter()
            // Sleep long enough that, without serialization, the second
            // run's body would observe `active=2`.
            try? await Task.sleep(nanoseconds: 80_000_000)
            await observer.exit()
        }
        async let second: Void = coord.run(chatIdleWaitMs: 0, requireResident: false) {
            await observer.enter()
            try? await Task.sleep(nanoseconds: 40_000_000)
            await observer.exit()
        }

        _ = await (first, second)

        let peak = await observer.peakActive
        let total = await observer.totalEntries
        #expect(peak == 1, "single-flight should never let two bodies overlap")
        #expect(total == 2)
    }

    @Test func chatIdleWaitMs_zero_proceeds_even_with_active_chat() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = DistillationCoordinator.shared
            let load = InferenceLoadCoordinator.shared

            // Simulate a long-running chat. With chatIdleWaitMs=0 the
            // coordinator must skip the idle wait entirely, so the body
            // runs without waiting on `endChatGeneration`.
            await load.beginChatGeneration()

            let started = Date()
            let bodyRan = AtomicBoolFlag()
            await coord.run(chatIdleWaitMs: 0, requireResident: false) {
                bodyRan.set()
            }
            let elapsed = Date().timeIntervalSince(started)
            await load.endChatGeneration()

            #expect(bodyRan.value)
            // 0.5s is generous; the actual run should be < 50ms. We just
            // need to confirm it didn't sit waiting on a chat-idle signal.
            #expect(elapsed < 0.5)
        }
    }

    @Test func snapshot_marks_active_during_body() async {
        let coord = DistillationCoordinator.shared
        let started = AtomicBoolFlag()
        let observed = AtomicBoolFlag()

        let runTask = Task {
            await coord.run(chatIdleWaitMs: 0, requireResident: false) {
                started.set()
                // Hold the body open long enough for the outer task to
                // sample `snapshot()` and see `active == true`.
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        // Wait until the body is actually inside the run.
        var safety = 100
        while !started.value && safety > 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            safety -= 1
        }
        let snap = await coord.snapshot()
        if snap.active { observed.set() }

        await runTask.value
        #expect(observed.value, "snapshot should report active while a body is executing")

        let final = await coord.snapshot()
        #expect(!final.active)
    }
}

private actor ConcurrencyObserver {
    private var active = 0
    private(set) var peakActive = 0
    private(set) var totalEntries = 0

    func enter() {
        active += 1
        totalEntries += 1
        if active > peakActive { peakActive = active }
    }

    func exit() {
        active -= 1
    }
}

private final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
