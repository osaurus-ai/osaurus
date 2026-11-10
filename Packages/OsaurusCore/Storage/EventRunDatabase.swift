//
//  EventRunDatabase.swift
//  osaurus
//
//  Encrypted SQLite ledger of event occurrences
//  (`~/.osaurus/events/runs.sqlite`). One row per occurrence, including the
//  ones that never ran (filtered, duplicate, suppressed). Rows hold
//  metadata only — never message bodies or webhook payloads — but they
//  still name people and rooms, so they follow chat history's storage
//  rules: SQLCipher at rest with the shared storage key.
//

import Foundation
import OsaurusSQLCipher

public enum EventRunDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open event ledger: \(m)"
        case .failedToExecute(let m): return "Failed to execute event ledger query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare event ledger statement: \(m)"
        case .migrationFailed(let m): return "Event ledger migration failed: \(m)"
        case .notOpen: return "Event ledger is not open"
        }
    }
}

public final class EventRunDatabase: @unchecked Sendable {
    public static let shared = EventRunDatabase()

    private static let latestSchemaVersion = 2
    /// Newest rows kept per event.
    static let retentionPerEvent = 500
    /// Rows older than this are pruned regardless of count.
    static let retentionAge: TimeInterval = 30 * 24 * 3600
    /// Seen delivery ids kept per event, and for how long.
    static let seenKeysPerEvent = 50_000
    static let seenKeyRetentionAge: TimeInterval = 90 * 24 * 3600

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.event.runs")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.events())
            do {
                db = try OsaurusStorageOpener.open(path: OsaurusPaths.eventRunsDatabaseFile().path, cacheTier: .cold)
                try runMigrations()
            } catch {
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.automationRuns.rawValue, error: error,
                    path: OsaurusPaths.eventRunsDatabaseFile().path)
                if let error = error as? EncryptedSQLiteError {
                    throw EventRunDatabaseError.failedToOpen(error.localizedDescription)
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "eventRuns",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Plaintext in-memory database for tests.
    public func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(path: ":memory:", key: nil, applyPerfPragmas: false)
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "eventRuns")
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
        }
    }

    /// Opens on first use and again after a storage maintenance close;
    /// in-memory under tests (test roots swap per test, and an on-disk
    /// handle would outlive its root).
    @discardableResult
    func ensureOpen() -> Bool {
        if isOpen { return true }
        do {
            if RuntimeEnvironment.isUnderTests {
                try openInMemory()
            } else {
                try open()
            }
            return true
        } catch {
            print("[Osaurus] Event ledger unavailable: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Schema

    private func runMigrations() throws {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { version = Int(sqlite3_column_int(stmt, 0)) }
        }
        if version > Self.latestSchemaVersion { return }
        if version < 1 {
            try executeRaw("BEGIN TRANSACTION")
            do {
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS event_runs (
                        id TEXT PRIMARY KEY,
                        event_id TEXT NOT NULL,
                        status TEXT NOT NULL,
                        fired_at REAL NOT NULL,
                        dedupe_key TEXT,
                        workflow_run_id TEXT,
                        record_json TEXT NOT NULL
                    )
                    """)
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_event_runs_event ON event_runs(event_id, fired_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_event_runs_recent ON event_runs(fired_at DESC)")
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_event_runs_dedupe ON event_runs(event_id, dedupe_key, fired_at DESC)")
                try executeRaw("PRAGMA user_version = 1")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw EventRunDatabaseError.migrationFailed("v1: \(error.localizedDescription)")
            }
        }
        if version < 2 {
            try executeRaw("BEGIN TRANSACTION")
            do {
                // Delivery ids an event has admitted, for `.durable` dedupe.
                // Pruned on their own retention, never with `event_runs`.
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS event_seen_keys (
                        event_id TEXT NOT NULL,
                        dedupe_key TEXT NOT NULL,
                        run_id TEXT NOT NULL,
                        seen_at REAL NOT NULL,
                        PRIMARY KEY (event_id, dedupe_key)
                    )
                    """)
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_event_seen_keys_age ON event_seen_keys(event_id, seen_at DESC)")
                // Adapter-defined JSON per scope: poll cursors, folder
                // baselines, provider webhook ids and expiries.
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS event_source_state (
                        scope_key TEXT PRIMARY KEY,
                        state_json TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """)
                try executeRaw("PRAGMA user_version = 2")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw EventRunDatabaseError.migrationFailed("v2: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Records

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func upsert(_ run: EventRun) throws {
        let json = String(decoding: try Self.encoder.encode(run), as: UTF8.self)
        try prepareAndExecute(
            """
            INSERT INTO event_runs (id, event_id, status, fired_at, dedupe_key, workflow_run_id, record_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status,
                workflow_run_id = excluded.workflow_run_id, record_json = excluded.record_json
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, run.id.uuidString)
                Self.bindText(stmt, 2, run.eventId.uuidString)
                Self.bindText(stmt, 3, run.status.rawValue)
                sqlite3_bind_double(stmt, 4, run.firedAt.timeIntervalSince1970)
                Self.bindOptionalText(stmt, 5, run.dedupeKey)
                Self.bindOptionalText(stmt, 6, run.workflowRunId?.uuidString)
                Self.bindText(stmt, 7, json)
            },
            process: { stmt in
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventRunDatabaseError.failedToExecute("upsert event run")
                }
            })
    }

    /// Drops rows beyond the per-event cap and rows past the age limit.
    public func prune(eventId: UUID, now: Date = Date()) throws {
        try prepareAndExecute(
            """
            DELETE FROM event_runs WHERE event_id = ?1 AND id NOT IN (
                SELECT id FROM event_runs WHERE event_id = ?1 ORDER BY fired_at DESC LIMIT ?2)
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, eventId.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(Self.retentionPerEvent))
            },
            process: { stmt in _ = sqlite3_step(stmt) })
        try pruneExpired(now: now)
    }

    /// `prune(eventId:)` for every event at once, including events that were
    /// deleted or never ran an action (filtered-only traffic).
    public func pruneAll(now: Date = Date()) throws {
        try prepareAndExecute(
            """
            DELETE FROM event_runs WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY fired_at DESC) AS rn
                    FROM event_runs)
                WHERE rn > ?1)
            """,
            bind: { sqlite3_bind_int($0, 1, Int32(Self.retentionPerEvent)) },
            process: { stmt in _ = sqlite3_step(stmt) })
        try pruneExpired(now: now)
        try pruneSeenKeys(now: now)
    }

    private func pruneExpired(now: Date) throws {
        try prepareAndExecute(
            "DELETE FROM event_runs WHERE fired_at < ?1",
            bind: { sqlite3_bind_double($0, 1, now.addingTimeInterval(-Self.retentionAge).timeIntervalSince1970) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    public func run(id: UUID) throws -> EventRun? {
        try query(
            "SELECT record_json FROM event_runs WHERE id = ?1",
            bind: { Self.bindText($0, 1, id.uuidString) }
        ).first
    }

    public func runs(eventId: UUID, limit: Int = 100) throws -> [EventRun] {
        try query(
            "SELECT record_json FROM event_runs WHERE event_id = ?1 ORDER BY fired_at DESC LIMIT ?2",
            bind: { stmt in
                Self.bindText(stmt, 1, eventId.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            })
    }

    public func recentRuns(limit: Int = 200) throws -> [EventRun] {
        try query(
            "SELECT record_json FROM event_runs ORDER BY fired_at DESC LIMIT ?1",
            bind: { sqlite3_bind_int($0, 1, Int32(limit)) })
    }

    /// The newest row for `(eventId, dedupeKey)` fired at or after `since`
    /// that was not itself a duplicate or a rejection.
    public func firstOccurrence(eventId: UUID, dedupeKey: String, since: Date) throws -> EventRun? {
        try query(
            """
            SELECT record_json FROM event_runs
            WHERE event_id = ?1 AND dedupe_key = ?2 AND fired_at >= ?3
                AND status NOT IN ('duplicate', 'suppressed', 'filtered')
            ORDER BY fired_at DESC LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, eventId.uuidString)
                Self.bindText(stmt, 2, dedupeKey)
                sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)
            }
        ).first
    }

    /// Rows a crash or quit left in a non-terminal state.
    public func openRuns() throws -> [EventRun] {
        try query(
            "SELECT record_json FROM event_runs WHERE status IN ('received', 'queued', 'running', 'awaiting_user') ORDER BY fired_at",
            bind: { _ in })
    }

    public func deleteRuns(eventId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM event_runs WHERE event_id = ?1",
            bind: { Self.bindText($0, 1, eventId.uuidString) },
            process: { stmt in _ = sqlite3_step(stmt) })
        try deleteSeenKeys(eventId: eventId)
        try deleteSourceState(prefix: Self.eventScopePrefix(eventId))
    }

    // MARK: - Seen keys

    /// The run that first admitted `dedupeKey` for the event, if any.
    public func seenKey(eventId: UUID, dedupeKey: String) throws -> UUID? {
        var runId: UUID?
        try prepareAndExecute(
            "SELECT run_id FROM event_seen_keys WHERE event_id = ?1 AND dedupe_key = ?2",
            bind: { stmt in
                Self.bindText(stmt, 1, eventId.uuidString)
                Self.bindText(stmt, 2, dedupeKey)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                    runId = UUID(uuidString: String(cString: text))
                }
            })
        return runId
    }

    /// Records the first admission of `dedupeKey`; a later insert of the
    /// same key keeps the original run.
    public func insertSeenKey(eventId: UUID, dedupeKey: String, runId: UUID, at: Date = Date()) throws {
        try prepareAndExecute(
            """
            INSERT OR IGNORE INTO event_seen_keys (event_id, dedupe_key, run_id, seen_at)
            VALUES (?1, ?2, ?3, ?4)
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, eventId.uuidString)
                Self.bindText(stmt, 2, dedupeKey)
                Self.bindText(stmt, 3, runId.uuidString)
                sqlite3_bind_double(stmt, 4, at.timeIntervalSince1970)
            },
            process: { stmt in
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventRunDatabaseError.failedToExecute("insert seen key")
                }
            })
    }

    public func seenKeyCount(eventId: UUID) throws -> Int {
        var count = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM event_seen_keys WHERE event_id = ?1",
            bind: { Self.bindText($0, 1, eventId.uuidString) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
            })
        return count
    }

    /// Drops seen keys past the age limit and beyond the per-event cap.
    public func pruneSeenKeys(now: Date = Date()) throws {
        try prepareAndExecute(
            "DELETE FROM event_seen_keys WHERE seen_at < ?1",
            bind: {
                sqlite3_bind_double($0, 1, now.addingTimeInterval(-Self.seenKeyRetentionAge).timeIntervalSince1970)
            },
            process: { stmt in _ = sqlite3_step(stmt) })
        try prepareAndExecute(
            """
            DELETE FROM event_seen_keys WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY seen_at DESC) AS rn
                    FROM event_seen_keys)
                WHERE rn > ?1)
            """,
            bind: { sqlite3_bind_int($0, 1, Int32(Self.seenKeysPerEvent)) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    public func deleteSeenKeys(eventId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM event_seen_keys WHERE event_id = ?1",
            bind: { Self.bindText($0, 1, eventId.uuidString) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    // MARK: - Source state

    /// Scope keys an adapter keeps per event start with this.
    public static func eventScopePrefix(_ eventId: UUID) -> String {
        "event:\(eventId.uuidString.lowercased())"
    }

    public func sourceState(scope: String) throws -> JSONValue? {
        var state: JSONValue?
        try prepareAndExecute(
            "SELECT state_json FROM event_source_state WHERE scope_key = ?1",
            bind: { Self.bindText($0, 1, scope) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                    state = try? Self.decoder.decode(JSONValue.self, from: Data(String(cString: text).utf8))
                }
            })
        return state
    }

    public func setSourceState(_ state: JSONValue, scope: String, at: Date = Date()) throws {
        let json = String(decoding: try Self.encoder.encode(state), as: UTF8.self)
        try prepareAndExecute(
            """
            INSERT INTO event_source_state (scope_key, state_json, updated_at) VALUES (?1, ?2, ?3)
            ON CONFLICT(scope_key) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, scope)
                Self.bindText(stmt, 2, json)
                sqlite3_bind_double(stmt, 3, at.timeIntervalSince1970)
            },
            process: { stmt in
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventRunDatabaseError.failedToExecute("set source state")
                }
            })
    }

    public func deleteSourceState(scope: String) throws {
        try prepareAndExecute(
            "DELETE FROM event_source_state WHERE scope_key = ?1",
            bind: { Self.bindText($0, 1, scope) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    /// Removes `prefix` and every scope under it (`prefix:…`).
    public func deleteSourceState(prefix: String) throws {
        try prepareAndExecute(
            "DELETE FROM event_source_state WHERE scope_key = ?1 OR substr(scope_key, 1, ?2) = ?3",
            bind: { stmt in
                Self.bindText(stmt, 1, prefix)
                sqlite3_bind_int(stmt, 2, Int32((prefix + ":").utf8.count))
                Self.bindText(stmt, 3, prefix + ":")
            },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void) throws -> [EventRun] {
        var runs: [EventRun] = []
        try prepareAndExecute(
            sql, bind: bind,
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let text = sqlite3_column_text(stmt, 0) else { continue }
                    if let run = try? Self.decoder.decode(EventRun.self, from: Data(String(cString: text).utf8)) {
                        runs.append(run)
                    }
                }
            })
        return runs
    }

    // MARK: - SQLite plumbing

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw EventRunDatabaseError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(connection, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw EventRunDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw EventRunDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw EventRunDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        try handler(stmt)
    }

    private func prepareAndExecute(
        _ sql: String, bind: (OpaquePointer) -> Void, process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        try queue.sync {
            guard let connection = db else { throw EventRunDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw EventRunDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            try process(stmt)
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, eventRunSQLiteTransient)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }
}

private let eventRunSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
