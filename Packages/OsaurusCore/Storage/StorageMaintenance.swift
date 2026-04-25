//
//  StorageMaintenance.swift
//  osaurus
//
//  Periodic SQLite maintenance for the five Osaurus databases. Runs:
//
//  - `PRAGMA optimize`         every `optimizeInterval` (default 6h)
//  - `PRAGMA wal_checkpoint(TRUNCATE)` every `checkpointInterval` (default 7d)
//  - `VACUUM` opportunistically every `vacuumInterval` (default 30d)
//
//  All work happens off the main actor, behind the existing serial
//  queues each `*Database` class owns. Last-run timestamps are kept
//  in `~/.osaurus/.storage-maintenance.json` so a long-lived process
//  doesn't churn through these in tight succession.
//
//  Schedule with `StorageMaintenance.shared.start()` from
//  `AppDelegate.applicationDidFinishLaunching`.
//

import Foundation
import OsaurusSQLCipher
import os

public actor StorageMaintenance {
    public static let shared = StorageMaintenance()

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.maintenance")

    /// How often we run the cheap `PRAGMA optimize` planner refresh.
    public var optimizeInterval: TimeInterval = 6 * 60 * 60
    /// How often we truncate the WAL.
    public var checkpointInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How often we run a full `VACUUM`.
    public var vacuumInterval: TimeInterval = 30 * 24 * 60 * 60

    private var timerTask: Task<Void, Never>?

    private var state = MaintenanceState()

    private init() {}

    // MARK: - Lifecycle

    /// Start the background ticker. Idempotent.
    public func start() {
        guard timerTask == nil else { return }
        loadState()
        timerTask = Task.detached(priority: .background) { [weak self] in
            // Run once a few seconds after launch (don't fight startup
            // contention) then every 30 minutes after.
            try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 30 * 60 * NSEC_PER_SEC)
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Force-run every maintenance pass right now (for tests + an
    /// admin button in Settings).
    public func runOnceNow() async {
        await runOptimize(force: true)
        await runWALCheckpoint(force: true)
        await runVacuum(force: true)
    }

    // MARK: - Tick

    private func tick() async {
        await runOptimize(force: false)
        await runWALCheckpoint(force: false)
        await runVacuum(force: false)
    }

    private func runOptimize(force: Bool) async {
        let now = Date()
        if !force, let last = state.lastOptimize, now.timeIntervalSince(last) < optimizeInterval {
            return
        }
        for db in OsaurusDatabaseHandle.allOpenHandles {
            db.executeMaintenance("PRAGMA optimize")
        }
        state.lastOptimize = now
        persistState()
        log.info("storage maintenance: PRAGMA optimize")
    }

    private func runWALCheckpoint(force: Bool) async {
        let now = Date()
        if !force, let last = state.lastCheckpoint, now.timeIntervalSince(last) < checkpointInterval {
            return
        }
        for db in OsaurusDatabaseHandle.allOpenHandles {
            db.executeMaintenance("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        state.lastCheckpoint = now
        persistState()
        log.info("storage maintenance: WAL checkpoint")
    }

    private func runVacuum(force: Bool) async {
        let now = Date()
        if !force, let last = state.lastVacuum, now.timeIntervalSince(last) < vacuumInterval {
            return
        }
        for db in OsaurusDatabaseHandle.allOpenHandles {
            db.executeMaintenance("VACUUM")
        }
        state.lastVacuum = now
        persistState()
        log.info("storage maintenance: VACUUM")
    }

    // MARK: - Persistent state

    private struct MaintenanceState: Codable {
        var lastOptimize: Date?
        var lastCheckpoint: Date?
        var lastVacuum: Date?
    }

    private func stateURL() -> URL {
        OsaurusPaths.root().appendingPathComponent(".storage-maintenance.json")
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL()),
            let decoded = try? JSONDecoder().decode(MaintenanceState.self, from: data)
        else {
            // First-ever launch: stamp every "lastRun" timestamp to
            // *now* so the initial maintenance tick (30s after
            // launch) doesn't immediately VACUUM every database.
            // Without this, the first install AND the first launch
            // after the encryption migration both pay a several-
            // minute VACUUM tax in the background that can serialise
            // behind the user's first DB read on the main actor.
            // After this, intervals proceed normally.
            let now = Date()
            state.lastOptimize = now
            state.lastCheckpoint = now
            state.lastVacuum = now
            persistState()
            return
        }
        state = decoded
    }

    private func persistState() {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL(), options: [.atomic])
        }
    }
}

// MARK: - Database handle abstraction

/// Type-erased handle for the five Osaurus databases so the
/// maintenance loop can iterate over them. Each `*Database` class
/// registers itself when it opens, deregisters when it closes.
public final class OsaurusDatabaseHandle: @unchecked Sendable {
    public typealias MaintenanceExec = @Sendable (String) -> Void
    public typealias Closer = @Sendable () -> Void
    public typealias Reopener = @Sendable () -> Void

    let name: String
    let exec: MaintenanceExec

    /// Closes the underlying SQLite handle. Used by key rotation to
    /// release exclusive access before `PRAGMA rekey`. Safe to call
    /// even when the DB is already closed.
    let closer: Closer

    /// Re-opens the SQLite handle after it was closed by `closer`.
    /// Used by key rotation so the rest of the app keeps running
    /// without the user noticing the cycle.
    let reopener: Reopener

    public init(
        name: String,
        exec: @escaping MaintenanceExec,
        closer: @escaping Closer = {},
        reopener: @escaping Reopener = {}
    ) {
        self.name = name
        self.exec = exec
        self.closer = closer
        self.reopener = reopener
    }

    func executeMaintenance(_ sql: String) {
        exec(sql)
    }

    // MARK: - Registry

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handles: [String: OsaurusDatabaseHandle] = [:]

    /// Snapshot of every currently registered handle.
    public static var allOpenHandles: [OsaurusDatabaseHandle] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handles.values)
    }

    public static func register(_ handle: OsaurusDatabaseHandle) {
        lock.lock()
        defer { lock.unlock() }
        handles[handle.name] = handle
    }

    public static func deregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        handles.removeValue(forKey: name)
    }

    /// Briefly close every registered DB handle while `body` runs,
    /// then reopen them. Used by key rotation so SQLCipher can take
    /// exclusive access for `PRAGMA rekey` without fighting the
    /// app's live connections.
    public static func withAllHandlesQuiesced<T>(_ body: () throws -> T) rethrows -> T {
        let snapshot = allOpenHandles
        for h in snapshot { h.closer() }
        defer {
            for h in snapshot { h.reopener() }
        }
        return try body()
    }
}
