// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

private actor ResidencySleepRecorder {
    private var requests: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ nanoseconds: UInt64) async {
        requests.append(nanoseconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func recordedRequests() -> [UInt64] {
        requests
    }

    func finishAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ResidencyUnloadRecorder {
    private var unloadedNames: [String] = []

    func unload(_ name: String) {
        unloadedNames.append(name)
    }

    func names() -> [String] {
        unloadedNames
    }
}

@Suite("Model idle residency manager")
struct ModelResidencyManagerTests {
    private static func allowTasksToRun() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test("afterSeconds schedules one delayed unload")
    func afterSecondsSchedulesDelayedUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })
        let now = Date(timeIntervalSinceReferenceDate: 100)

        await manager.scheduleIdleUnload(
            modelName: "llama",
            policy: .afterSeconds(300),
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )

        await Self.allowTasksToRun()
        #expect(await sleeper.recordedRequests() == [300_000_000_000])
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "llama")
        #expect(snapshots.first?.unloadAt == now.addingTimeInterval(300))

        await sleeper.finishAll()
        await Self.allowTasksToRun()
        #expect(await unloads.names() == ["llama"])
        #expect(await manager.snapshots().isEmpty)
    }

    @Test("markActive cancels pending idle unload")
    func markActiveCancelsPendingIdleUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(30),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        await manager.markActive(modelName: "gemma")
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "gemma")
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("never policy records residency without scheduling a timer")
    func neverPolicyDoesNotScheduleTimer() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "hy3",
            policy: .never,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await sleeper.recordedRequests().isEmpty)
        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.policy == .never)
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("idle fire rechecks lease count before unloading")
    func idleFireRechecksLeaseCountBeforeUnloading() async {
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager()

        await manager.scheduleIdleUnload(
            modelName: "busy",
            policy: .immediately,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 1 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "busy")
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("idle fire drops stale entries when model is not resident")
    func idleFireDropsStaleEntriesWhenModelIsNotResident() async {
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager()

        await manager.scheduleIdleUnload(
            modelName: "gone",
            policy: .immediately,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in false }
        )
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().isEmpty)
    }

    @Test("accelerateIdleUnload shortens a pending idle unload")
    func accelerateShortensPendingUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })
        let now = Date(timeIntervalSinceReferenceDate: 100)

        await manager.scheduleIdleUnload(
            modelName: "llama",
            policy: .afterSeconds(900),
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        await manager.accelerateIdleUnload(
            modelName: "llama",
            grace: 60,
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await sleeper.recordedRequests() == [900_000_000_000, 60_000_000_000])
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.unloadAt == now.addingTimeInterval(60))

        await sleeper.finishAll()
        await Self.allowTasksToRun()
        // The superseded 900s timer was cancelled; only the grace timer fires.
        #expect(await unloads.names() == ["llama"])
        #expect(await manager.snapshots().isEmpty)
    }

    @Test("accelerateIdleUnload never extends a sooner deadline")
    func accelerateNeverExtendsSoonerDeadline() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })
        let now = Date(timeIntervalSinceReferenceDate: 100)

        await manager.scheduleIdleUnload(
            modelName: "llama",
            policy: .afterSeconds(30),
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        await manager.accelerateIdleUnload(
            modelName: "llama",
            grace: 60,
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        // No second timer: the existing 30s deadline is sooner than now+60s.
        #expect(await sleeper.recordedRequests() == [30_000_000_000])
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.unloadAt == now.addingTimeInterval(30))
    }

    @Test("accelerateIdleUnload is a no-op while the model is active")
    func accelerateNoOpWhileModelActive() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        // markActive state: entry exists but has no pending timer — the
        // API/chat stream in flight owns residency until it releases.
        await manager.markActive(modelName: "busy")
        await manager.accelerateIdleUnload(
            modelName: "busy",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 1 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await sleeper.recordedRequests().isEmpty)
        #expect(await unloads.names().isEmpty)
    }

    @Test("accelerateIdleUnload is a no-op under the never policy")
    func accelerateNoOpUnderNeverPolicy() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "pinned",
            policy: .never,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await manager.accelerateIdleUnload(
            modelName: "pinned",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await sleeper.recordedRequests().isEmpty)
        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().first?.policy == .never)
    }

    @Test("markActive during the grace window cancels the accelerated unload")
    func markActiveDuringGraceCancelsAcceleratedUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(900),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        await manager.accelerateIdleUnload(
            modelName: "gemma",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        // An API request starts during the grace window.
        await manager.markActive(modelName: "gemma")
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().first?.unloadAt == nil)
    }

    @Test("accelerated fire with a held lease does not unload")
    func acceleratedFireWithHeldLeaseDoesNotUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(900),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        // Lease is re-checked at FIRE time; report it held there.
        await manager.accelerateIdleUnload(
            modelName: "gemma",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 1 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        // Entry kept (timer consumed) — the stream's release re-arms policy.
        #expect(await manager.snapshots().first?.modelName == "gemma")
        #expect(await manager.snapshots().first?.unloadAt == nil)
    }

    @Test("shouldStillUnload guard aborts the accelerated unload")
    func shouldStillUnloadGuardAbortsAcceleratedUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(900),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        // A window reopened during the grace and re-selected the model.
        await manager.accelerateIdleUnload(
            modelName: "gemma",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true },
            shouldStillUnload: { _ in false }
        )
        await Self.allowTasksToRun()
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().first?.modelName == "gemma")
        #expect(await manager.snapshots().first?.unloadAt == nil)
    }

    @Test("a new generation after acceleration re-arms the full policy")
    func generationAfterAccelerationReArmsFullPolicy() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(900),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        await manager.accelerateIdleUnload(
            modelName: "gemma",
            grace: 60,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        // API generation starts (cancels grace) and later releases,
        // re-arming the full policy timer.
        await manager.markActive(modelName: "gemma")
        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(900),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(
            await sleeper.recordedRequests()
                == [900_000_000_000, 60_000_000_000, 900_000_000_000]
        )
        await sleeper.finishAll()
        await Self.allowTasksToRun()
        // Only the final full-policy timer fires; the superseded grace
        // timer was cancelled by markActive.
        #expect(await unloads.names() == ["gemma"])
    }

    @Test("cancelAll cancels timers and clears snapshots")
    func cancelAllCancelsTimersAndClearsSnapshots() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "cancelled",
            policy: .afterSeconds(30),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        await manager.cancelAll()
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().isEmpty)
    }
}
