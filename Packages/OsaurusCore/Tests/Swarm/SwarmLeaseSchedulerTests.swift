//
//  SwarmLeaseSchedulerTests.swift
//  OsaurusCoreTests
//
//  The lease contract the simulator implements (and the Swarm library
//  implements for real): warm-first choice, one lease per node, caller
//  affinity, queue with a deadline, expiry only while idle, revocation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Swarm lease scheduler")
struct SwarmLeaseSchedulerTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value = value.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    final class Nodes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SwarmLeaseScheduler.Candidate]
        init(_ list: [SwarmLeaseScheduler.Candidate]) { self.list = list }
        var current: [SwarmLeaseScheduler.Candidate] {
            lock.lock()
            defer { lock.unlock() }
            return list
        }
        func set(_ list: [SwarmLeaseScheduler.Candidate]) {
            lock.lock()
            self.list = list
            lock.unlock()
        }
    }

    static func candidate(
        _ id: String,
        warm: Bool = false,
        load: Double = 0,
        accepts: Bool = true,
        hasModel: Bool = true
    ) -> SwarmLeaseScheduler.Candidate {
        .init(
            nodeId: id,
            acceptsLeases: accepts,
            hasModel: hasModel,
            warm: warm,
            load: load,
            recentTokensPerSecond: nil
        )
    }

    static func request(caller: String, wait: Int = 0, lease: Int = 60) -> SwarmLeaseRequest {
        SwarmLeaseRequest(
            poolId: "p",
            nodeIds: [],
            modelId: "org/model",
            leaseSeconds: lease,
            maxWaitSeconds: wait,
            callerKey: caller
        )
    }

    @Test func prefersWarmThenLeastLoaded() {
        let pick = SwarmLeaseScheduler.choose(
            from: [
                Self.candidate("a", load: 0.1), Self.candidate("b", warm: true, load: 0.9),
                Self.candidate("c", load: 0),
            ],
            busy: [],
            preferred: nil
        )
        #expect(pick?.nodeId == "b")
        let cold = SwarmLeaseScheduler.choose(
            from: [Self.candidate("a", load: 0.5), Self.candidate("c", load: 0.1)],
            busy: [],
            preferred: nil
        )
        #expect(cold?.nodeId == "c")
    }

    @Test func skipsBusyPausedAndModelLessNodes() {
        let pick = SwarmLeaseScheduler.choose(
            from: [
                Self.candidate("busy", warm: true), Self.candidate("paused", warm: true, accepts: false),
                Self.candidate("empty", warm: true, hasModel: false), Self.candidate("ok"),
            ],
            busy: ["busy"],
            preferred: nil
        )
        #expect(pick?.nodeId == "ok")
    }

    @Test func oneLeasePerNodeAndCallerRenewsSameNode() async throws {
        let clock = Clock()
        let nodes = Nodes([Self.candidate("a"), Self.candidate("b")])
        let scheduler = SwarmLeaseScheduler(now: { clock.now }, candidates: { _, _, _ in nodes.current })
        let first = try await scheduler.acquire(Self.request(caller: "chat-1"), poolName: "Pool")
        let second = try await scheduler.acquire(Self.request(caller: "chat-2"), poolName: "Pool")
        #expect(first.nodeId != second.nodeId)
        clock.advance(10)
        let again = try await scheduler.acquire(Self.request(caller: "chat-1"), poolName: "Pool")
        #expect(again.id == first.id)
        #expect(again.nodeId == first.nodeId)
        #expect(again.expiresAt > first.expiresAt)
    }

    @Test func fullPoolFailsTypedWhenNoWait() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        _ = try await scheduler.acquire(Self.request(caller: "x"), poolName: "Raptor Pool #1")
        await #expect(throws: SwarmError.poolBusy(pool: "Raptor Pool #1", waitedSeconds: 0)) {
            _ = try await scheduler.acquire(Self.request(caller: "y"), poolName: "Raptor Pool #1")
        }
    }

    @Test func queuedCallerGetsNodeOnRelease() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        let held = try await scheduler.acquire(Self.request(caller: "x"), poolName: "P")
        async let waiting = scheduler.acquire(Self.request(caller: "y", wait: 30), poolName: "P")
        // Let the waiter enqueue.
        for _ in 0 ..< 50 where await scheduler.queuedCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await scheduler.queuedCount() == 1)
        await scheduler.release(held.id)
        let granted = try await waiting
        #expect(granted.nodeId == "a")
        #expect(await scheduler.queuedCount() == 0)
    }

    @Test func queueTimesOutWithPoolBusy() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        _ = try await scheduler.acquire(Self.request(caller: "x"), poolName: "P")
        await #expect(throws: SwarmError.poolBusy(pool: "P", waitedSeconds: 1)) {
            _ = try await scheduler.acquire(Self.request(caller: "y", wait: 1), poolName: "P")
        }
        #expect(await scheduler.queuedCount() == 0)
    }

    @Test func expiresOnlyWhileIdle() async throws {
        let clock = Clock()
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(now: { clock.now }, candidates: { _, _, _ in nodes.current })
        let lease = try await scheduler.acquire(Self.request(caller: "x", lease: 30), poolName: "P")
        await scheduler.beginRequest(lease.id)
        clock.advance(120)
        // A running request is never cut off by expiry.
        #expect(await scheduler.activeLeases().map(\.id) == [lease.id])
        await scheduler.endRequest(lease.id)
        #expect(await scheduler.activeLeases().isEmpty)
        let next = try await scheduler.acquire(Self.request(caller: "y"), poolName: "P")
        #expect(next.nodeId == "a")
    }

    @Test func waitingCallerReclaimsSessionIdleBetweenTurns() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        let chat = try await scheduler.acquire(Self.request(caller: "chat", lease: 300), poolName: "P")
        await scheduler.beginRequest(chat.id)
        await scheduler.endRequest(chat.id)
        // The chat is between turns: another caller gets its node at once
        // instead of waiting out the 300 s lease.
        let other = try await scheduler.acquire(Self.request(caller: "title"), poolName: "P")
        #expect(other.nodeId == "a")
        #expect(await scheduler.activeLeases().map(\.id) == [other.id])
    }

    @Test func runningOrJustRenewedLeaseIsNeverReclaimed() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        let chat = try await scheduler.acquire(Self.request(caller: "chat", lease: 300), poolName: "P")
        await scheduler.beginRequest(chat.id)
        await #expect(throws: SwarmError.poolBusy(pool: "P", waitedSeconds: 0)) {
            _ = try await scheduler.acquire(Self.request(caller: "other"), poolName: "P")
        }
        await scheduler.endRequest(chat.id)
        // The chat's next turn renews before it starts: still protected.
        let renewed = try await scheduler.acquire(Self.request(caller: "chat", lease: 300), poolName: "P")
        #expect(renewed.id == chat.id)
        await #expect(throws: SwarmError.poolBusy(pool: "P", waitedSeconds: 0)) {
            _ = try await scheduler.acquire(Self.request(caller: "other"), poolName: "P")
        }
    }

    @Test func revokedNodeLosesLeasesAndCallerMovesOn() async throws {
        let nodes = Nodes([Self.candidate("a", warm: true), Self.candidate("b")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        let lease = try await scheduler.acquire(Self.request(caller: "x"), poolName: "P")
        #expect(lease.nodeId == "a")
        let lost = await scheduler.revokeLeases(onNode: "a")
        #expect(lost == [lease.id])
        nodes.set([Self.candidate("a", warm: true, accepts: false), Self.candidate("b")])
        let moved = try await scheduler.acquire(Self.request(caller: "x"), poolName: "P")
        #expect(moved.nodeId == "b")
        #expect(moved.id != lease.id)
    }

    @Test func cancelledWaiterLeavesQueue() async throws {
        let nodes = Nodes([Self.candidate("a")])
        let scheduler = SwarmLeaseScheduler(candidates: { _, _, _ in nodes.current })
        _ = try await scheduler.acquire(Self.request(caller: "x"), poolName: "P")
        let task = Task { try await scheduler.acquire(Self.request(caller: "y", wait: 60), poolName: "P") }
        for _ in 0 ..< 50 where await scheduler.queuedCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await scheduler.queuedCount() == 0)
    }
}
