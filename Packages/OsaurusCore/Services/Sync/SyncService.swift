//
//  SyncService.swift
//  osaurus
//
//  Owns the process's one `SyncCore`: open and close, network settings,
//  sleep/wake and connectivity hooks, and core events. Conversations go
//  through `SyncConversationStore`; this type only manages the core.
//

import AppKit
import Foundation
import Network
import OsaurusSync
import os

final class SyncService: @unchecked Sendable {
    static let shared = SyncService()

    /// Posted on the main queue after the core opens (launch, reopen after a
    /// settings change, reset or sign-out).
    static let didOpenNotification = Notification.Name("SyncService.didOpen")
    /// Posted on the main queue after the core closed (close, reopen or
    /// sign-out). Subscriptions on it no longer deliver.
    static let didCloseNotification = Notification.Name("SyncService.didClose")
    /// Posted on the main queue when everything shown may be stale: pairing,
    /// recovery or rotation replaced the identity, or the core was reset.
    static let didReplaceIdentityNotification = Notification.Name("SyncService.didReplaceIdentity")
    /// Posted on the main queue with a `CoreEvent` under `eventUserInfoKey`.
    static let didReceiveEventNotification = Notification.Name("SyncService.didReceiveEvent")
    static let eventUserInfoKey = "event"
    /// Posted on the main queue when `devices` changed.
    static let devicesDidChangeNotification = Notification.Name("SyncService.devicesDidChange")
    /// Posted on the main queue after `apply` saved a changed configuration.
    static let didChangeConfigurationNotification = Notification.Name("SyncService.didChangeConfiguration")

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync")

    private let stateLock = NSLock()
    private let openLock = NSLock()
    private var _core: SyncCore?
    private var _openDirectory: String?
    private var _lastOpenError: Error?
    private var _opening = false
    private var lifecycle: Lifecycle?
    private var loggingInstalled = false
    private var _devices: [Device] = []

    private init() {}

    /// This user's devices, this one included, as of the last change.
    var devices: [Device] { stateLock.withLock { _devices } }

    /// Whether anything this Mac writes to a synced conversation goes somewhere.
    var hasOtherDevices: Bool { devices.contains { !$0.isSelf && !$0.revoked } }

    func deviceName(forKey key: String) -> String? {
        devices.first { $0.id == key }?.name
    }

    private func refreshDevices(_ core: SyncCore) {
        let list = (try? core.devices()) ?? []
        let changed = stateLock.withLock {
            guard _devices != list else { return false }
            _devices = list
            return true
        }
        if changed { postOnMain(Self.devicesDidChangeNotification) }
    }

    // MARK: - State

    /// The open core, or nil before the first open finishes (or after it failed).
    var core: SyncCore? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _core
    }

    var isOpen: Bool { core != nil }

    var lastOpenError: Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastOpenError
    }

    // MARK: - Open and close

    /// Opens the core for the current `OsaurusPaths` root, or returns the one
    /// already open. Blocks on the Keychain and the database open, so the main
    /// thread uses `openInBackground()` instead.
    @discardableResult
    func open() throws -> SyncCore {
        openLock.lock()
        defer { openLock.unlock() }
        return try openLocked()
    }

    private func openLocked() throws -> SyncCore {
        let directory = OsaurusPaths.sync()
        stateLock.lock()
        let existing = _core
        let existingDirectory = _openDirectory
        stateLock.unlock()
        if let existing, existingDirectory == directory.path { return existing }
        if existing != nil { closeLocked() }

        installLoggingOnce()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let core = try SyncCore.open(
                dataDirectory: directory,
                deviceName: Self.deviceName,
                network: Self.networkConfig(for: SyncConfigurationStore.load()),
                keyStore: SyncKeyStores.make(dataDirectory: directory)
            )
            stateLock.lock()
            _core = core
            _openDirectory = directory.path
            _lastOpenError = nil
            stateLock.unlock()
            PersistenceHealth.shared.clearStoreIssue(store: StorageRecoveryService.Store.sync.rawValue)
            core.setListener { [weak self] event in self?.handle(event) }
            refreshDevices(core)
            startLifecycle(core)
            SyncNetworkDirectoryStore.refreshInBackground()
            Self.log.info("sync core opened")
            postOnMain(Self.didOpenNotification)
            return core
        } catch {
            stateLock.lock()
            _lastOpenError = error
            stateLock.unlock()
            let detail = (error as? SyncError)?.logDetail ?? "\(error)"
            Self.log.error("sync core failed to open: \(detail, privacy: .public)")
            PersistenceHealth.shared.recordStoreIssue(
                store: StorageRecoveryService.Store.sync.rawValue,
                kind: (error as? SyncError)?.storageIssueKind ?? StorageOpenIssueKind.classify(error),
                message: error.syncUserMessage,
                path: directory.path
            )
            postOnMain(Self.didOpenNotification)
            throw error
        }
    }

    /// Waits before each automatic retry of an open that failed for a reason
    /// that can clear by itself.
    static let openRetryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)]

    /// Opens off the calling thread, retrying transient failures. Repeated
    /// calls while an open is running are ignored; `didOpenNotification`
    /// fires after each attempt.
    func openInBackground() {
        stateLock.lock()
        if _core != nil || _opening {
            stateLock.unlock()
            return
        }
        _opening = true
        stateLock.unlock()
        Task.detached(priority: .userInitiated) { [self] in
            defer { stateLock.withLock { _opening = false } }
            for delay in [Duration.zero] + Self.openRetryDelays {
                if delay > .zero { try? await Task.sleep(for: delay) }
                if core != nil { return }
                do {
                    _ = try open()
                    return
                } catch {
                    guard (error as? SyncError)?.isTransientOpenFailure == true else { return }
                    Self.log.notice("sync open will retry")
                }
            }
        }
    }

    /// Stops networking, flushes and releases the data directory. Blocks
    /// until the core has closed.
    func close() {
        openLock.lock()
        defer { openLock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        stateLock.lock()
        let core = _core
        _core = nil
        _openDirectory = nil
        stateLock.unlock()
        stopLifecycle()
        guard let core else { return }
        core.setListener(listener: nil)
        _ = Self.blocking { try await core.close() }
        postOnMain(Self.didCloseNotification)
    }

    /// Calls `attach` with the core now if it's open, and again after every
    /// open or identity replacement; calls `detach` after it closes. `attach`
    /// replaces whatever the previous call set up. Keep the returned
    /// observers for as long as the callbacks should run.
    @MainActor
    func observeCore(
        attach: @escaping @MainActor @Sendable (SyncCore) -> Void,
        detach: @escaping @MainActor @Sendable () -> Void
    ) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let reattach: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                if let core = SyncService.shared.core { attach(core) }
            }
        }
        let observers = [
            center.addObserver(forName: Self.didOpenNotification, object: nil, queue: .main, using: reattach),
            center.addObserver(forName: Self.didReplaceIdentityNotification, object: nil, queue: .main, using: reattach),
            center.addObserver(forName: Self.didCloseNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { detach() }
            },
        ]
        if let core { attach(core) }
        return observers
    }

    /// Closes and opens again, for settings that only apply at open.
    func reopen() {
        Task.detached(priority: .userInitiated) { [self] in
            close()
            _ = try? open()
        }
    }

    // MARK: - Settings

    static func networkConfig(for configuration: SyncConfiguration) -> NetworkConfig {
        if RuntimeEnvironment.isUnderTests {
            var net = localNetworkConfig()
            net.enabled = false
            return net
        }
        var net: NetworkConfig
        switch configuration.networkMode {
        case .localNetworkOnly:
            net = defaultNetworkConfig()
        case .anywhere:
            net = defaultNetworkConfig()
            SyncNetworkDirectoryStore.current().apply(to: &net)
        }
        net.enabled = configuration.networkEnabled
        return net
    }

    /// Saves `configuration` and applies it: the network switch takes effect
    /// right away, a server change reopens the core.
    func apply(_ configuration: SyncConfiguration) {
        let previous = SyncConfigurationStore.load()
        SyncConfigurationStore.save(configuration)
        guard previous != configuration else { return }
        postOnMain(Self.didChangeConfigurationNotification)
        guard previous.networkEnabled != configuration.networkEnabled
            || previous.networkMode != configuration.networkMode
        else { return }
        if previous.networkMode != configuration.networkMode {
            reopen()
            return
        }
        guard let core else { return }
        Task.detached(priority: .utility) {
            do {
                if configuration.networkEnabled {
                    try await core.resume()
                } else {
                    try await core.suspend()
                }
            } catch {
                Self.log.error("network switch failed: \((error as? SyncError)?.logDetail ?? "\(error)", privacy: .public)")
            }
        }
    }

    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    // MARK: - Account

    /// Signs this Mac out. `keepConversations` keeps them here as device-local
    /// conversations under a new identity; otherwise this Mac's sync data and
    /// keys are deleted. Opens a fresh core afterwards.
    func signOut(keepConversations: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try openLock.withLock { try signOutLocked(keepConversations: keepConversations) }
        }.value
    }

    /// Holds `openLock` throughout, so a settings reopen or launch open can't
    /// land between the sign-out and the fresh core.
    private func signOutLocked(keepConversations: Bool) throws {
        guard let core else { return }
        stopLifecycle()
        core.setListener(listener: nil)
        stateLock.withLock {
            _core = nil
            _openDirectory = nil
        }
        postOnMain(Self.didCloseNotification)
        let result = Self.blocking {
            if keepConversations {
                try await core.signOut(keepConversations: true)
            } else {
                try await core.reset()
            }
        }
        if case .failure(let error)? = result {
            Self.log.error("sign out failed: \((error as? SyncError)?.logDetail ?? "\(error)", privacy: .public)")
            _ = try? openLocked()
            throw error
        }
        postOnMain(Self.didReplaceIdentityNotification)
        _ = try openLocked()
    }

    /// The key store items the core's own reset deletes.
    static let keyStoreItems = ["device-key", "user-secret", "user-secret-next", "view-key"]

    /// Storage recovery: starts this Mac over with an empty sync identity.
    /// An open core resets itself. One that can't open (a damaged database)
    /// has its data directory moved to quarantine and its keys deleted.
    /// Returns the quarantined directory, if one was moved.
    @discardableResult
    func resetLocalData() async throws -> URL? {
        try await Task.detached(priority: .userInitiated) { [self] () throws -> URL? in
            try openLock.withLock { () throws -> URL? in
                if core != nil {
                    try signOutLocked(keepConversations: false)
                    return nil
                }
                closeLocked()
                let directory = OsaurusPaths.sync()
                let quarantined = StorageFile.quarantine(path: directory.path, reason: "reset sync")
                let keyStore = SyncKeyStores.make(dataDirectory: directory)
                for name in Self.keyStoreItems {
                    try keyStore.delete(name: name)
                }
                postOnMain(Self.didReplaceIdentityNotification)
                _ = try openLocked()
                return quarantined
            }
        }.value
    }

    // MARK: - Events

    private func handle(_ event: CoreEvent) {
        switch event {
        case .identityChanged:
            postOnMain(Self.didReplaceIdentityNotification)
        case let .incompatiblePeer(_, version):
            Self.log.notice("peer runs incompatible protocol version \(version)")
        case .selfRevoked:
            Self.log.notice("this device was revoked")
        default:
            break
        }
        switch event {
        case .devicesChanged, .paired, .peerRevoked, .identityChanged, .selfRevoked:
            if let core { refreshDevices(core) }
        default:
            break
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didReceiveEventNotification,
                object: nil,
                userInfo: [Self.eventUserInfoKey: event]
            )
        }
    }

    private func postOnMain(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    private func installLoggingOnce() {
        guard !loggingInstalled else { return }
        loggingInstalled = true
        SyncLogging.useOSLog(level: .info)
    }

    // MARK: - Lifecycle

    private func startLifecycle(_ core: SyncCore) {
        guard !RuntimeEnvironment.isUnderTests else { return }
        let lifecycle = Lifecycle(core: core)
        lifecycle.start()
        self.lifecycle = lifecycle
    }

    private func stopLifecycle() {
        lifecycle?.stop()
        lifecycle = nil
    }

    /// Sleep and wake, app activation and network changes.
    private final class Lifecycle: @unchecked Sendable {
        private let core: SyncCore
        private var observers: [NSObjectProtocol] = []
        private let pathMonitor = NWPathMonitor()
        private let backfill: BackfillPolicyMonitor

        init(core: SyncCore) {
            self.core = core
            self.backfill = BackfillPolicyMonitor(core: core)
        }

        func start() {
            // This Mac's directory, manage and attention conversations reach a new iPhone first.
            Task.detached(priority: .utility) { [core] in
                SyncDeviceFeedContract.offerSystemConversationsFirst(core: core)
                // No storage server yet: compact state hourly so a new iPhone downloads current state,
                // not every manage request, attention change and streaming write ever made.
                try? core.setCompactWithoutStorage(on: true)
            }
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append(
                workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
                    [core] _ in
                    try? SyncConversationStore.shared.performWrite { SyncAgentDirectory.writePresence(.sleeping, core: $0) }
                    _ = SyncService.blocking(timeout: 5) { try await core.suspend() }
                }
            )
            observers.append(
                workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
                    [core] _ in
                    guard SyncConfigurationStore.load().networkEnabled else { return }
                    Task.detached(priority: .utility) { try? await core.resume() }
                    Task { @MainActor in SyncAgentDirectory.shared.schedulePublish() }
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: nil
                ) { [core] _ in
                    core.syncNow()
                }
            )
            // Any change while online counts: Wi-Fi to Ethernet, a VPN, a
            // hotspot. Each can leave connections on the old route.
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self, path.status == .satisfied else { return }
                self.core.syncNow()
                SyncNetworkDirectoryStore.refreshInBackground()
            }
            pathMonitor.start(queue: DispatchQueue(label: "ai.osaurus.sync.path"))
            backfill.start()
        }

        func stop() {
            for observer in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            pathMonitor.cancel()
            backfill.stop()
        }
    }

    // MARK: - Blocking bridge

    /// Runs an async core call to completion from synchronous code. The work
    /// runs detached so it never needs the caller's actor while it waits.
    @discardableResult
    static func blocking<T: Sendable>(
        timeout: TimeInterval? = nil,
        _ body: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error>? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do {
                box.set(.success(try await body()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        if let timeout {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            semaphore.wait()
        }
        return box.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }
        func get() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    #if DEBUG
        /// Closes the core and forgets the last error, for test isolation.
        func _resetForTesting() {
            close()
            stateLock.lock()
            _lastOpenError = nil
            stateLock.unlock()
        }
    #endif
}
