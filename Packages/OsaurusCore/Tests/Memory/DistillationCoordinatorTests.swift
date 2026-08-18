//
//  DistillationCoordinatorTests.swift
//  osaurus
//
//  Tests focus on the *coordination* primitives (single-flight queue,
//  chat-idle wait bypass, residency gate, and timeout behavior). Each
//  test uses an isolated coordinator with deterministic gate closures,
//  leaving the production process-wide singleton untouched.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DistillationCoordinatorTests {

    @Test func snapshot_defaults_to_idle() async {
        let coord = DistillationCoordinator.makeForTesting()
        let snap = await coord.snapshot()
        #expect(snap.queued == 0)
        #expect(!snap.active)
    }

    @Test func run_executes_body_when_residency_disabled() async {
        let gates = DistillationGateProbe(resident: false, chatIdle: false)
        let coord = DistillationCoordinator.makeForTesting(
            canDistillCheaply: { await gates.checkResidency() },
            waitForChatIdle: { timeoutMs in await gates.waitForChatIdle(timeoutMs) }
        )
        let observer = ConcurrencyObserver()

        await coord.run(chatIdleWaitMs: 0, requireResident: false) {
            await observer.enter()
            await observer.exit()
        }

        let total = await observer.totalEntries
        #expect(total == 1)
        #expect(await gates.residencyChecks == 0)
        #expect(await gates.chatIdleWaits.isEmpty)

        let snap = await coord.snapshot()
        #expect(snap.queued == 0)
        #expect(!snap.active)
    }

    @Test func concurrent_runs_serialize_strictly() async {
        let coord = DistillationCoordinator.makeForTesting()
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
        let gates = DistillationGateProbe(resident: true, chatIdle: false)
        let coord = DistillationCoordinator.makeForTesting(
            waitForChatIdle: { timeoutMs in await gates.waitForChatIdle(timeoutMs) }
        )

        let started = Date()
        let bodyRan = AtomicBoolFlag()
        await coord.run(chatIdleWaitMs: 0, requireResident: false) {
            bodyRan.set()
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(bodyRan.value)
        #expect(await gates.chatIdleWaits.isEmpty)
        // 0.5s is generous; the actual run should be < 50ms. We just
        // need to confirm it didn't sit waiting on a chat-idle signal.
        #expect(elapsed < 0.5)
    }

    @Test func residency_gate_skips_body_when_model_is_not_cheap() async {
        let gates = DistillationGateProbe(resident: false, chatIdle: true)
        let coord = DistillationCoordinator.makeForTesting(
            canDistillCheaply: { await gates.checkResidency() },
            waitForChatIdle: { timeoutMs in await gates.waitForChatIdle(timeoutMs) }
        )
        let bodyRan = AtomicBoolFlag()

        await coord.run(chatIdleWaitMs: 500, requireResident: true) {
            bodyRan.set()
        }

        #expect(!bodyRan.value)
        #expect(await gates.residencyChecks == 1)
        #expect(await gates.chatIdleWaits.isEmpty)
    }

    @Test(arguments: [true, false])
    func positive_chat_idle_wait_runs_after_gate(_ wentIdle: Bool) async {
        let gates = DistillationGateProbe(resident: true, chatIdle: wentIdle)
        let coord = DistillationCoordinator.makeForTesting(
            waitForChatIdle: { timeoutMs in await gates.waitForChatIdle(timeoutMs) }
        )
        let bodyRan = AtomicBoolFlag()

        await coord.run(chatIdleWaitMs: 321, requireResident: false) {
            bodyRan.set()
        }

        #expect(bodyRan.value)
        #expect(await gates.chatIdleWaits == [321])
    }

    @Test func snapshot_marks_active_during_body() async {
        let coord = DistillationCoordinator.makeForTesting()
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

private actor DistillationGateProbe {
    private let resident: Bool
    private let chatIdle: Bool
    private(set) var residencyChecks = 0
    private(set) var chatIdleWaits: [Int] = []

    init(resident: Bool, chatIdle: Bool) {
        self.resident = resident
        self.chatIdle = chatIdle
    }

    func checkResidency() -> Bool {
        residencyChecks += 1
        return resident
    }

    func waitForChatIdle(_ timeoutMs: Int) -> Bool {
        chatIdleWaits.append(timeoutMs)
        return chatIdle
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
