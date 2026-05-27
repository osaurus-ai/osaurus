//
//  InferenceLoadCoordinatorTests.swift
//  osaurus
//
//  Mirrors `ModelLeaseTests` in shape — same `AtomicBoolFlag` trick to
//  assert "the waiter is parked" without relying on race-prone sleeps.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct InferenceLoadCoordinatorTests {

    @Test func begin_end_balances_to_zero() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)

            await coord.beginChatGeneration()
            await coord.beginChatGeneration()
            var count = await coord.activeCount
            #expect(count == 2)

            await coord.endChatGeneration()
            await coord.endChatGeneration()
            count = await coord.activeCount
            #expect(count == 0)
            let active = await coord.chatActive
            #expect(!active)
        }
    }

    @Test func double_end_clamps_at_zero() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)

            await coord.beginChatGeneration()
            await coord.endChatGeneration()
            await coord.endChatGeneration()  // intentional double-end
            let count = await coord.activeCount
            #expect(count == 0)
        }
    }

    @Test func waitForChatIdle_returns_true_when_already_idle() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)
            let wentIdle = await coord.waitForChatIdle(timeoutMs: 100)
            #expect(wentIdle)
        }
    }

    @Test func waitForChatIdle_resumes_when_chat_ends() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)

            await coord.beginChatGeneration()
            let waiterFinished = AtomicBoolFlag()
            let waiterTask = Task<Bool, Never> {
                let result = await coord.waitForChatIdle(timeoutMs: 5000)
                waiterFinished.set()
                return result
            }

            // Brief sleep gives the waiter time to park; without this we can
            // race the parking step and assert before it actually parks.
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(!waiterFinished.value)

            await coord.endChatGeneration()
            let result = await waiterTask.value
            #expect(result)
            #expect(waiterFinished.value)
        }
    }

    @Test func waitForChatIdle_returns_false_on_timeout() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)

            await coord.beginChatGeneration()
            let result = await coord.waitForChatIdle(timeoutMs: 100)
            #expect(!result)
            await coord.endChatGeneration()
        }
    }

    @Test func multi_window_refcount_only_idles_when_all_end() async {
        await InferenceLoadCoordinatorTestLock.shared.run {
            let coord = InferenceLoadCoordinator()
            await drainToZero(coord)

            await coord.beginChatGeneration()
            await coord.beginChatGeneration()
            await coord.beginChatGeneration()

            // Drop two of three; should still be active.
            await coord.endChatGeneration()
            await coord.endChatGeneration()
            var active = await coord.chatActive
            #expect(active)

            // The remaining one should idle the coordinator + resume the waiter.
            let waiterTask = Task<Bool, Never> {
                await coord.waitForChatIdle(timeoutMs: 2000)
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            await coord.endChatGeneration()
            let waiterResult = await waiterTask.value
            #expect(waiterResult)

            active = await coord.chatActive
            #expect(!active)
        }
    }

    /// Drain leftover refcount entries from the shared coordinator before
    /// each locked test. The coordinator clamps `endChatGeneration` at zero,
    /// so we can call it safely up to the current count.
    private func drainToZero(_ coord: InferenceLoadCoordinator) async {
        var count = await coord.activeCount
        var safety = 64
        while count > 0 && safety > 0 {
            await coord.endChatGeneration()
            count = await coord.activeCount
            safety -= 1
        }
    }
}

// `AtomicBoolFlag` is intentionally duplicated from `ModelLeaseTests.swift`
// (where it's `private`) — a tiny, local race-flag helper isn't worth a
// shared test-utility module. If a third test file needs it, promote at
// that point.
private final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
