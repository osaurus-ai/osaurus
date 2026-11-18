#if os(iOS)
import UIKit

/// Suspends the core when the app moves to the background and resumes it in the foreground.
///
/// iOS closes sockets of suspended apps, so the core must stop networking cleanly: `suspend`
/// flushes Loro snapshots, checkpoints the database and closes the endpoint inside a background
/// task. Writes made while suspended wait in the outbox; `resume` reconnects and catches up.
/// The core does no networking in the background beyond that task.
///
/// An app that keeps running in the background for a reason of its own, such as a call in
/// progress under the audio background mode, holds the core awake with `holdAwake()` for as long
/// as it does. While held, going to the background doesn't suspend the core, and holding it
/// resumes a core already suspended. The last `releaseAwake()` suspends it if the app is still in
/// the background.
@MainActor
public final class SyncLifecycle {
    private let core: SyncCore
    private var observers: [NSObjectProtocol] = []
    /// Each trip to the background's task, by attempt. One begun while an earlier one was still flushing
    /// (background, foreground and background again within the flush) used to overwrite it, and the first
    /// was never ended, which iOS can end the app for.
    private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
    private var attempt = 0
    private var holds = 0
    /// Suspended because the app went to the background, and not resumed since.
    private var suspended = false

    public init(core: SyncCore) {
        self.core = core
    }

    /// True while something holds the core awake.
    public var isHeldAwake: Bool { holds > 0 }

    public func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Keeps the core running in the background until the matching `releaseAwake()`.
    public func holdAwake() {
        holds += 1
        guard holds == 1, suspended else { return }
        suspended = false
        let core = self.core
        Task { try? await core.resume() }
    }

    public func releaseAwake() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0, UIApplication.shared.applicationState == .background {
            didEnterBackground()
        }
    }

    private func didEnterBackground() {
        guard holds == 0, !suspended else { return }
        suspended = true
        attempt += 1
        let mine = attempt
        backgroundTasks[mine] = UIApplication.shared.beginBackgroundTask(withName: "osaurus-sync-suspend") {
            [weak self] in
            MainActor.assumeIsolated { self?.endTask(mine) }
        }
        let core = self.core
        Task {
            // Writes made just before (an answer tapped, then the phone locked) go out first:
            // suspended now, they'd wait for the next time the app is opened.
            await Self.flush(core)
            // Back in front, or held awake for a call, while it flushed: not suspended after all. Back in
            // front and gone again: the newer trip suspends it.
            let still = await MainActor.run { self.suspended && self.holds == 0 && self.attempt == mine }
            guard still else {
                await MainActor.run { self.endTask(mine) }
                return
            }
            try? await core.suspend()
            // Back in front, or held awake, while it was suspending: their resume may have run first, and
            // the core would stay suspended in the foreground. Resumed again.
            let resume = await MainActor.run { () -> Bool in
                self.endTask(mine)
                guard !self.suspended || self.holds > 0 else { return false }
                self.suspended = false
                return true
            }
            if resume { try? await core.resume() }
        }
    }

    /// Longest the app stays connected in the background to send what's waiting. Well inside the
    /// background task iOS gives, and short enough not to cost battery when no device is reachable.
    nonisolated static let flushLimit: Duration = .seconds(10)

    /// Waits until every write has been stored by a peer, or `flushLimit`. An entry leaves the
    /// outbox once any one device stores it, so a device that is never online doesn't hold this up.
    nonisolated private static func flush(_ core: SyncCore) async {
        let pending: @Sendable () -> UInt32 = { (try? core.pendingOutboxTotal()) ?? 0 }
        guard await Task.detached(operation: pending).value > 0 else { return }
        core.syncNow()
        let start = ContinuousClock.now
        while ContinuousClock.now - start < flushLimit {
            try? await Task.sleep(for: .milliseconds(250))
            if await Task.detached(operation: pending).value == 0 { return }
        }
    }

    private func willEnterForeground() {
        suspended = false
        let core = self.core
        Task { try? await core.resume() }
    }

    private func endTask(_ attempt: Int) {
        guard let task = backgroundTasks.removeValue(forKey: attempt), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}
#endif
