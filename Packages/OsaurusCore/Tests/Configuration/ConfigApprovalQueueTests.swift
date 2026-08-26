//
//  ConfigApprovalQueueTests.swift
//  osaurusTests
//
//  Pins the in-chat config-approval seam: an attended `osaurus_config` apply
//  parks a request on `ConfigApprovalQueue`, the card's tap resolves the
//  suspended tool call, teardown denies everything, and surface tracking
//  decides card-vs-modal-fallback. The queue is a shared singleton, so the
//  suite is `.serialized`: concurrent tests would interleave on the shared
//  `pending` array, grab each other's requests via `pending.first`, and
//  livelock the spin-waits below.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ConfigApprovalQueueTests {

    private func emptyPlan() throws -> ConfigPlan {
        let document = try ConfigYAML.decode("version: 1\n")
        return try ConfigPlanner.plan(document: document, prune: false)
    }

    @Test("approve resolves the suspended apply as true and clears the card")
    func approveResolvesTrue() async throws {
        let queue = ConfigApprovalQueue.shared
        queue.cancelAll()
        let plan = try emptyPlan()

        let task = Task { await queue.requestApproval(plan: plan, prune: false) }
        // Let the request park on the queue.
        while queue.pending.isEmpty { await Task.yield() }
        let request = try #require(queue.pending.first)
        #expect(request.prune == false)

        queue.resolve(id: request.id, approved: true)
        #expect(await task.value == true)
        #expect(queue.pending.isEmpty)
    }

    @Test("deny resolves the suspended apply as false")
    func denyResolvesFalse() async throws {
        let queue = ConfigApprovalQueue.shared
        queue.cancelAll()
        let plan = try emptyPlan()

        let task = Task { await queue.requestApproval(plan: plan, prune: true) }
        while queue.pending.isEmpty { await Task.yield() }
        let request = try #require(queue.pending.first)
        // Prune travels with the request so the card can warn about deletes.
        #expect(request.prune == true)

        queue.resolve(id: request.id, approved: false)
        #expect(await task.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("cancelAll denies every pending approval (Stop / chat teardown)")
    func cancelAllDeniesEverything() async throws {
        let queue = ConfigApprovalQueue.shared
        queue.cancelAll()
        let plan = try emptyPlan()

        let first = Task { await queue.requestApproval(plan: plan, prune: false) }
        let second = Task { await queue.requestApproval(plan: plan, prune: true) }
        while queue.pending.count < 2 { await Task.yield() }

        queue.cancelAll()
        #expect(await first.value == false)
        #expect(await second.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("cancelled turn resolves as denied so the tool never hangs")
    func taskCancellationDenies() async throws {
        let queue = ConfigApprovalQueue.shared
        queue.cancelAll()
        let plan = try emptyPlan()

        let task = Task { await queue.requestApproval(plan: plan, prune: false) }
        while queue.pending.isEmpty { await Task.yield() }

        task.cancel()
        #expect(await task.value == false)
        // The onCancel resolve hops through a MainActor task; drain it.
        while !queue.pending.isEmpty { await Task.yield() }
        #expect(queue.pending.isEmpty)
    }

    @Test("surface tracking is a balanced mount/unmount counter")
    func surfaceTracking() {
        let queue = ConfigApprovalQueue.shared
        // Establish a clean baseline regardless of prior test order.
        while queue.hasMountedSurface { queue.surfaceDidUnmount() }

        #expect(queue.hasMountedSurface == false)
        queue.surfaceDidMount()
        queue.surfaceDidMount()
        #expect(queue.hasMountedSurface == true)
        queue.surfaceDidUnmount()
        #expect(queue.hasMountedSurface == true)
        queue.surfaceDidUnmount()
        #expect(queue.hasMountedSurface == false)
        // Unmount below zero must not wedge the counter negative.
        queue.surfaceDidUnmount()
        queue.surfaceDidMount()
        #expect(queue.hasMountedSurface == true)
        queue.surfaceDidUnmount()
    }
}
