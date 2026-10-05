import Dispatch
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class SchedulerLifecycleRecorder {
    private let events: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private(set) var handledNotifications = 0
    private(set) var tickersStarted = 0
    private(set) var tickersFinished = 0

    init() {
        let stream = AsyncStream<Int>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func notificationHandled() {
        handledNotifications += 1
        continuation.yield(handledNotifications)
    }

    func runTicker() async {
        tickersStarted += 1
        defer { tickersFinished += 1 }
        // Cancellation ends the injected body; lifecycle/task ownership remains
        // in the real scheduler. This body never opens a database or model.
        try? await Task.sleep(for: .seconds(60))
    }

    func waitForHandlers(_ count: Int) async -> Bool {
        if handledNotifications >= count { return true }
        let events = events
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await handled in events {
                    if handled >= count { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }

    func finish() { continuation.finish() }
}

@MainActor
private struct SchedulerLifecycleFixture {
    let center: NotificationCenter
    let recorder: SchedulerLifecycleRecorder
    let scheduler: NextRunScheduler

    init() {
        let center = NotificationCenter()
        let recorder = SchedulerLifecycleRecorder()
        self.center = center
        self.recorder = recorder
        scheduler = NextRunScheduler.makeForTesting(
            notificationCenter: center,
            ticker: { await recorder.runTicker() },
            onStorageNotificationHandled: { recorder.notificationHandled() }
        )
    }

    func post() {
        center.post(name: StorageKeyManager.storageKeyDidBecomeResident, object: nil)
    }

    func finish() async {
        await scheduler.stopAndWaitForTesting()
        #expect(!scheduler.isRunning)
        #expect(recorder.tickersStarted == recorder.tickersFinished)
        recorder.finish()
    }
}

@Suite(.serialized)
@MainActor
struct NextRunSchedulerStorageReadyTests {
    private func withFixture(_ body: @MainActor (SchedulerLifecycleFixture) async -> Void) async {
        let fixture = SchedulerLifecycleFixture()
        await body(fixture)
        await fixture.finish()
    }

    // Swift 6 disallows these blocking/thread APIs directly in an async body.
    // The finite wait deliberately prevents main delivery until it returns.
    private func publisherReturnedWhileMainWaited(
        posting: DispatchSemaphore,
        returned: DispatchSemaphore
    ) -> Bool {
        #expect(Thread.isMainThread)
        guard posting.wait(timeout: .now() + 1) == .success else { return false }
        return returned.wait(timeout: .now() + 0.5) == .success
    }

    @Test
    func backgroundNotificationReturnsWhileMainIsWaiting() async {
        await withFixture { fixture in
            fixture.scheduler.startWhenStorageBecomesReady()
            let posting = DispatchSemaphore(value: 0)
            let returned = DispatchSemaphore(value: 0)
            let center = fixture.center
            let publisher = Task.detached(priority: .utility) { () -> Void in
                posting.signal()
                center.post(name: StorageKeyManager.storageKeyDidBecomeResident, object: nil)
                returned.signal()
            }
            #expect(publisherReturnedWhileMainWaited(posting: posting, returned: returned))
            // Yield main and join the actual publisher even after a failed
            // bounded wait, then await the real queued callback acknowledgment.
            await publisher.value
            #expect(await fixture.recorder.waitForHandlers(1))
            #expect(fixture.scheduler.isRunning)
        }
    }

    @Test
    func stopRejectsAlreadyQueuedNotification() async {
        await withFixture { fixture in
            fixture.scheduler.startWhenStorageBecomesReady()
            fixture.post()
            fixture.scheduler.stop()
            #expect(await fixture.recorder.waitForHandlers(1))
            #expect(!fixture.scheduler.isRunning)
        }
    }

    @Test
    func rearmPreservesFreshObservationAfterStaleCallback() async {
        await withFixture { fixture in
            fixture.scheduler.startWhenStorageBecomesReady()
            fixture.post()
            fixture.scheduler.stop()
            fixture.scheduler.startWhenStorageBecomesReady()
            #expect(await fixture.recorder.waitForHandlers(1))
            #expect(!fixture.scheduler.isRunning)
            fixture.post()
            #expect(await fixture.recorder.waitForHandlers(2))
            #expect(fixture.scheduler.isRunning)
        }
    }

    @Test
    func freshNotificationStartsTicker() async {
        await withFixture { fixture in
            fixture.scheduler.startWhenStorageBecomesReady()
            fixture.post()
            #expect(await fixture.recorder.waitForHandlers(1))
            #expect(fixture.scheduler.isRunning)
        }
    }

    @Test
    func stoppedObservationReceivesNoFurtherNotification() async {
        await withFixture { fixture in
            fixture.scheduler.startWhenStorageBecomesReady()
            fixture.scheduler.stop()
            fixture.post()
            #expect(!fixture.scheduler.isRunning)
            #expect(fixture.recorder.handledNotifications == 0)
        }
    }
}
