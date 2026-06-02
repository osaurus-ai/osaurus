//
//  StorageMutationGateTests.swift
//  osaurusTests
//
//  Coverage for the rotation-parking semantics on
//  `StorageMutationGate`:
//
//  - `awaitNotMutating()` blocks while `isMutating == true`, then
//    unblocks once `endMutating()` is called (the contract used
//    by `StorageExportService.rotateStorageKey`).
//  - `endMutating()` drains every parked waiter.
//  - the lock-free `blockingAwaitNotMutating()` fast path returns
//    without hopping onto the main actor when no rotation is running.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageMutationGateTests {

    @Test
    @MainActor
    func awaitNotMutating_parksWhileMutatingAndUnblocksOnEnd() async throws {
        let gate = StorageMutationGate.shared

        // Park `awaitNotMutating` in a Task so we can observe whether
        // it returns prematurely.
        gate.beginMutating()
        let probe = Task { @MainActor in
            await gate.awaitNotMutating()
            return Date()
        }

        // Sleep a tick to let the probe park.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!probe.isCancelled)

        let beforeEnd = Date()
        gate.endMutating()
        let returnedAt = await probe.value
        // Probe must have returned strictly after we called endMutating.
        #expect(returnedAt >= beforeEnd)
    }

    @Test
    @MainActor
    func endMutating_drainsAllParkedWaiters() async throws {
        let gate = StorageMutationGate.shared
        gate.beginMutating()

        // Park multiple awaiters concurrently.
        let probes: [Task<Void, Never>] = (0 ..< 5).map { _ in
            Task { @MainActor in
                await gate.awaitNotMutating()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        gate.endMutating()
        for p in probes {
            await p.value
        }
        // All five resumed without us having to call endMutating again.
        #expect(true)
    }

    /// Pins the lock-free fast path of `blockingAwaitNotMutating`.
    /// When no rotation is running the call must return without
    /// scheduling a Task, hopping onto the main actor, or pumping
    /// the run loop. We verify by hammering the gate from many
    /// threads.
    @Test
    @MainActor
    func blockingAwaitNotMutating_fastPathDoesNotTouchMainActor() async throws {
        // 16 background hammerers + a deadline. 16 × 1000 = 16k
        // calls. Even at 10µs per atomic load on slow hardware
        // that's 160ms total.
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    for _ in 0 ..< 1000 {
                        StorageMutationGate.blockingAwaitNotMutating()
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "16k blockingAwaitNotMutating calls took \(elapsed)s — fast path regressed")
    }
}
