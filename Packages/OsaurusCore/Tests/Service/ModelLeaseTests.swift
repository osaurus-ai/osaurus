//
//  ModelLeaseTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ModelLeaseTests {

    @Test func acquire_release_balances_to_zero() async {
        let lease = ModelLease.shared
        let name = "lease-test-\(UUID().uuidString)"

        await lease.acquire(name)
        await lease.acquire(name)
        var count = await lease.count(for: name)
        #expect(count == 2)

        await lease.release(name)
        await lease.release(name)
        count = await lease.count(for: name)
        #expect(count == 0)
    }

    @Test func waitForZero_resumes_when_count_drops() async {
        let lease = ModelLease.shared
        let name = "wait-test-\(UUID().uuidString)"
        await lease.acquire(name)

        let waiterFinished = AtomicBoolFlag()
        let waiterTask = Task {
            await lease.waitForZero(name)
            waiterFinished.set()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!waiterFinished.value)

        await lease.release(name)
        await waiterTask.value
        #expect(waiterFinished.value)
    }

    @Test func waitForZero_returns_immediately_when_no_lease() async {
        let lease = ModelLease.shared
        let name = "no-lease-\(UUID().uuidString)"
        await lease.waitForZero(name)
        // No assertion needed — reaching this line means no hang.
    }

    @Test func double_release_clamps_at_zero() async {
        let lease = ModelLease.shared
        let name = "clamp-test-\(UUID().uuidString)"
        await lease.acquire(name)
        await lease.release(name)
        await lease.release(name)  // intentional double-release
        let count = await lease.count(for: name)
        #expect(count == 0)
    }

    @Test func activeNames_only_includes_held_leases() async {
        let lease = ModelLease.shared
        let name = "active-\(UUID().uuidString)"
        let unrelated = "unrelated-\(UUID().uuidString)"

        await lease.acquire(name)
        let active = await lease.activeNames()
        #expect(active.contains(name))
        #expect(!active.contains(unrelated))

        await lease.release(name)
        let activeAfter = await lease.activeNames()
        #expect(!activeAfter.contains(name))
    }
}

private final class AtomicBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
