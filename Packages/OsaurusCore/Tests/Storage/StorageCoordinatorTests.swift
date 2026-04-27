//
//  StorageCoordinatorTests.swift
//  osaurusTests
//
//  Coverage for the gating + retry semantics on
//  `StorageMigrationCoordinator`:
//
//  - `awaitReady()` blocks while `isMutating == true`, then
//    unblocks once `endMutating()` is called (the contract used
//    by `StorageExportService.rotateStorageKey`).
//  - Failure-to-migrate state is *not* latched as `isReady`, so a
//    retry is possible without process restart.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageCoordinatorTests {

    /// All three tests below force the coordinator into a known
    /// "ready" state via `_setReadyForTesting()` instead of calling
    /// the real `awaitReady()`. The real `awaitReady()` triggers
    /// `runMigration()`, which:
    ///   - reads the *real* `~/.osaurus/.storage-version` (the
    ///     coordinator predates `OsaurusPaths.overrideRoot`),
    ///   - displays an `NSPanel` ("Securing your data" overlay),
    ///   - hits the real Keychain,
    ///   - walks the real `~/.osaurus/Tools/` for plugin DBs.
    ///
    /// On a CI runner with no display server / no interactive
    /// Keychain prompt path that combination has historically
    /// hung the test process for the full 45-min job timeout
    /// (the user even saw the panel briefly appear during local
    /// `swift test`).

    @Test
    @MainActor
    func awaitReady_parksWhileMutatingAndUnblocksOnEnd() async throws {
        let coord = StorageMigrationCoordinator.shared
        coord._setReadyForTesting()

        // Park `awaitReady` in a Task so we can observe whether it
        // returns prematurely.
        coord.beginMutating()
        let probe = Task { @MainActor in
            await coord.awaitReady()
            return Date()
        }

        // Sleep a tick to let the probe park.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!probe.isCancelled)

        let beforeEnd = Date()
        coord.endMutating()
        let returnedAt = await probe.value
        // Probe must have returned strictly after we called endMutating.
        #expect(returnedAt >= beforeEnd)
    }

    @Test
    @MainActor
    func endMutating_drainsAllParkedWaiters() async throws {
        let coord = StorageMigrationCoordinator.shared
        coord._setReadyForTesting()
        coord.beginMutating()

        // Park multiple awaiters concurrently.
        let probes: [Task<Void, Never>] = (0 ..< 5).map { _ in
            Task { @MainActor in
                await coord.awaitReady()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        coord.endMutating()
        for p in probes {
            await p.value
        }
        // All five resumed without us having to call endMutating again.
        #expect(true)
    }

    /// Pins the lock-free fast path of `blockingAwaitReady`. When
    /// `isReady == true && isMutating == false` the call must
    /// return without scheduling a Task, hopping onto the main
    /// actor, or pumping the run loop. We verify by hammering the
    /// gate from many threads — pre-fix the gate scheduled a
    /// `Task @MainActor` on every call and contended with main
    /// for thousands of cycles; post-fix the atomic latch
    /// short-circuits.
    @Test
    @MainActor
    func blockingAwaitReady_fastPathDoesNotTouchMainActor() async throws {
        let coord = StorageMigrationCoordinator.shared
        coord._setReadyForTesting()

        // 16 background hammerers + a deadline. 16 × 1000 = 16k
        // calls. Even at 10µs per atomic load on slow hardware
        // that's 160ms total. Pre-fix this took multiple seconds.
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    for _ in 0 ..< 1000 {
                        StorageMigrationCoordinator.blockingAwaitReady()
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "16k blockingAwaitReady calls took \(elapsed)s — fast path regressed")
    }
}
