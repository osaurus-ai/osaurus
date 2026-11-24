import Foundation
import Testing

@testable import OsaurusCore

@Suite("Nearby host gate")
struct NearbyHostGateTests {
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the gate")
    }

    @Test func matchesTheHostUploadLimit() {
        #expect(NearbyHostGate.slotsPerHost == 4)
    }

    @Test func holdsAtMostTheLimitPerHost() async throws {
        let gate = NearbyHostGate(slotsPerHost: 2)
        try await gate.acquire("a")
        try await gate.acquire("a")
        try await gate.acquire("b")
        #expect(await gate.holderCount("a") == 2)
        #expect(await gate.holderCount("b") == 1)

        let third = Task { try await gate.acquire("a") }
        try await waitUntil { await gate.waiterCount("a") == 1 }
        #expect(await gate.holderCount("a") == 2)

        await gate.release("a")
        try await third.value
        #expect(await gate.holderCount("a") == 2)
        #expect(await gate.waiterCount("a") == 0)

        await gate.release("a")
        await gate.release("a")
        await gate.release("b")
        #expect(await gate.holderCount("a") == 0)
        #expect(await gate.holderCount("b") == 0)
    }

    @Test func waitersGetSlotsInTheOrderTheyAsked() async throws {
        let gate = NearbyHostGate(slotsPerHost: 1)
        try await gate.acquire("a")
        let order = Order()
        var tasks: [Task<Void, Error>] = []
        for index in 1 ... 3 {
            tasks.append(
                Task {
                    try await gate.acquire("a")
                    order.append(index)
                    await gate.release("a")
                }
            )
            try await waitUntil { await gate.waiterCount("a") == index }
        }

        await gate.release("a")
        for task in tasks { try await task.value }
        #expect(order.all == [1, 2, 3])
        #expect(await gate.holderCount("a") == 0)
    }

    @Test func cancelledWaiterHoldsNothingAndDoesNotBlockTheQueue() async throws {
        let gate = NearbyHostGate(slotsPerHost: 1)
        try await gate.acquire("a")
        let cancelled = Task { try await gate.acquire("a") }
        try await waitUntil { await gate.waiterCount("a") == 1 }
        let next = Task { try await gate.acquire("a") }
        try await waitUntil { await gate.waiterCount("a") == 2 }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await gate.waiterCount("a") == 1)

        await gate.release("a")
        try await next.value
        #expect(await gate.holderCount("a") == 1)
        await gate.release("a")
        #expect(await gate.holderCount("a") == 0)
    }

    @Test func alreadyCancelledTaskNeverWaits() async throws {
        let gate = NearbyHostGate(slotsPerHost: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire("a")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.holderCount("a") == 0)
        #expect(await gate.waiterCount("a") == 0)
    }

    @Test func busyRetryBacksOffUpToTenSeconds() {
        #expect((1 ... 6).map(NearbyFileDownloader.busyRetryDelay(attempt:)) == [1, 2, 4, 8, 10, 10])
    }
}
