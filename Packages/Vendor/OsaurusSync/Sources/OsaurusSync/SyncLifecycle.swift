#if os(iOS)
import UIKit

/// Suspends the core when the app moves to the background and resumes it in the foreground.
///
/// iOS closes sockets of suspended apps, so the core must stop networking cleanly: `suspend`
/// flushes Loro snapshots, checkpoints the database and closes the endpoint inside a background
/// task. Writes made while suspended wait in the outbox; `resume` reconnects and catches up.
/// The core does no networking in the background beyond that task.
@MainActor
public final class SyncLifecycle {
    private let core: SyncCore
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    public init(core: SyncCore) {
        self.core = core
    }

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

    private func didEnterBackground() {
        let app = UIApplication.shared
        backgroundTask = app.beginBackgroundTask(withName: "osaurus-sync-suspend") { [weak self] in
            MainActor.assumeIsolated { self?.endTask() }
        }
        let core = self.core
        Task {
            try? await core.suspend()
            await MainActor.run { self.endTask() }
        }
    }

    private func willEnterForeground() {
        let core = self.core
        Task { try? await core.resume() }
    }

    private func endTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
#endif
