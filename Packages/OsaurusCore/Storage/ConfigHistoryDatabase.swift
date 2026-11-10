//
//  ConfigHistoryDatabase.swift
//  osaurus
//
//  SQLite store of configuration snapshots (`~/.osaurus/config/history.sqlite`).
//  One row per landed change to the declarative document, written by
//  `ConfigHistoryRecorder`. Rows hold the exporter's output, which carries no
//  secret values, but they name agents, folders, and the user's requests, so
//  they follow chat history's storage rules through `OsaurusStorageOpener`.
//

import Foundation
import OsaurusSQLCipher

public enum ConfigHistoryDatabaseError: Error, LocalizedError, Equatable {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen
    case labelTaken(String)
    case notFound(Int)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open configuration history: \(m)"
        case .failedToExecute(let m): return "Failed to execute configuration history query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare configuration history statement: \(m)"
        case .migrationFailed(let m): return "Configuration history migration failed: \(m)"
        case .notOpen: return "Configuration history is not open"
        case .labelTaken(let label): return "Another version is already named “\(label)”."
        case .notFound(let sequence): return "No configuration version \(sequence)."
        }
    }
}

public final class ConfigHistoryDatabase: @unchecked Sendable {
    public static let shared = ConfigHistoryDatabase()

    private static let latestSchemaVersion = 1
    /// Newest unlabeled snapshots kept; labeled rows and sequence 0 are
    /// kept on top of these.
    public static let retainedUnlabeled = 200

    private var db: OpaquePointer?
    /// A fixed file for tests that relaunch against the same store.
    private var testPath: String?
    private let queue = DispatchQueue(label: "ai.osaurus.config.history")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
            let path = OsaurusPaths.configHistoryDatabaseFile().path
            do {
                db = try OsaurusStorageOpener.open(path: path, cacheTier: .cold)
                try runMigrations()
            } catch {
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.configHistory.rawValue, error: error, path: path)
                if let error = error as? EncryptedSQLiteError {
                    throw ConfigHistoryDatabaseError.failedToOpen(error.localizedDescription)
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "configHistory",
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

    /// Plaintext on-disk database for tests that close and reopen the store.
    func openForTests(path: String) throws {
        try queue.sync {
            guard db == nil else { return }
            testPath = path
            db = try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: false)
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "configHistory")
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
        }
    }

    /// Opens on first use and again after a storage maintenance close;
    /// in-memory under tests unless a test opened a file.
    @discardableResult
    func ensureOpen() -> Bool {
        if isOpen { return true }
        do {
            if let testPath = queue.sync(execute: { testPath }) {
                try openForTests(path: testPath)
            } else if RuntimeEnvironment.isUnderTests {
                try openInMemory()
            } else {
                try open()
            }
            return true
        } catch {
            print("[Osaurus] Configuration history unavailable: \(error.localizedDescription)")
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
                    CREATE TABLE IF NOT EXISTS config_snapshots (
                        id TEXT PRIMARY KEY,
                        sequence INTEGER NOT NULL UNIQUE,
                        taken_at REAL NOT NULL,
                        document BLOB NOT NULL,
                        document_hash TEXT NOT NULL,
                        sections_changed TEXT NOT NULL,
                        caller_kind TEXT NOT NULL,
                        caller_detail TEXT,
                        approval_id TEXT,
                        request_text TEXT,
                        label TEXT
                    )
                    """)
                try executeRaw(
                    "CREATE UNIQUE INDEX IF NOT EXISTS idx_config_snapshots_label ON config_snapshots(label COLLATE NOCASE) WHERE label IS NOT NULL"
                )
                try executeRaw("PRAGMA user_version = 1")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw ConfigHistoryDatabaseError.migrationFailed("v1: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Writes

    /// Appends a snapshot of `yaml` (canonical) unless it equals the latest
    /// one, then prunes. Returns the new row, or nil when nothing changed.
    @discardableResult
    public func append(
        yaml: String, caller: ConfigChangeCaller, approvalId: UUID? = nil, requestText: String? = nil,
        takenAt: Date = Date()
    ) throws -> ConfigSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            let latest = try latestLocked()
            if latest?.documentHash == ConfigSnapshot.hash(yaml) { return nil }
            let snapshot = ConfigSnapshot(
                sequence: (latest?.sequence ?? -1) + 1, takenAt: takenAt, yaml: yaml,
                sectionsChanged: ConfigSnapshot.sectionsChanged(from: latest?.yaml, to: yaml),
                caller: caller, approvalId: approvalId, requestText: requestText)
            try insertLocked(snapshot)
            try pruneLocked()
            return snapshot
        }
    }

    /// Names a snapshot (nil or blank clears it). Labeled rows survive retention.
    public func setLabel(_ label: String?, sequence: Int) throws {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        try queue.sync {
            if let value, let owner = try selectLocked(where: "label = ?1 COLLATE NOCASE", bind: { Self.bindText($0, 1, value) }).first,
                owner.sequence != sequence
            {
                throw ConfigHistoryDatabaseError.labelTaken(value)
            }
            try statementLocked(
                "UPDATE config_snapshots SET label = ?1 WHERE sequence = ?2",
                bind: { stmt in
                    Self.bindOptionalText(stmt, 1, value)
                    sqlite3_bind_int64(stmt, 2, Int64(sequence))
                },
                process: { stmt in
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw ConfigHistoryDatabaseError.failedToExecute("set label")
                    }
                })
            guard sqlite3_changes(db) > 0 else { throw ConfigHistoryDatabaseError.notFound(sequence) }
        }
    }

    /// Keeps the newest `retainedUnlabeled` unlabeled rows, every labeled
    /// row, and sequence 0.
    public func prune() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        try queue.sync { try pruneLocked() }
    }

    public func deleteAll() throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        try queue.sync { try executeRaw("DELETE FROM config_snapshots") }
    }

    // MARK: - Reads

    public func latest() throws -> ConfigSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync { try latestLocked() }
    }

    /// Newest first. `section` keeps rows that changed it; `since` keeps
    /// rows taken at or after it.
    public func list(limit: Int = 50, section: ConfigSectionID? = nil, since: Date? = nil) throws -> [ConfigSnapshot] {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            try selectLocked(
                where: "(?1 IS NULL OR sections_changed LIKE ?1) AND (?2 IS NULL OR taken_at >= ?2)",
                order: "sequence DESC", limit: limit,
                bind: { stmt in
                    Self.bindOptionalText(stmt, 1, section.map { "%\"\($0.rawValue)\"%" })
                    if let since {
                        sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
                    } else {
                        sqlite3_bind_null(stmt, 2)
                    }
                })
        }
    }

    public func snapshot(sequence: Int) throws -> ConfigSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            try selectLocked(where: "sequence = ?1", bind: { sqlite3_bind_int64($0, 1, Int64(sequence)) }).first
        }
    }

    public func snapshot(label: String) throws -> ConfigSnapshot? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            try selectLocked(where: "label = ?1 COLLATE NOCASE", bind: { Self.bindText($0, 1, trimmed) }).first
        }
    }

    /// The snapshot that came before `sequence` (the state its change started from).
    public func snapshot(before sequence: Int) throws -> ConfigSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            try selectLocked(
                where: "sequence < ?1", order: "sequence DESC", limit: 1,
                bind: { sqlite3_bind_int64($0, 1, Int64(sequence)) }
            ).first
        }
    }

    public func count() throws -> Int {
        dispatchPrecondition(condition: .notOnQueue(queue))
        ensureOpen()
        return try queue.sync {
            var count = 0
            try statementLocked(
                "SELECT COUNT(*) FROM config_snapshots", bind: { _ in },
                process: { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int64(stmt, 0)) }
                })
            return count
        }
    }

    /// Every stored document, for audits (the no-secret check).
    func allDocuments() throws -> [String] {
        try list(limit: Int(Int32.max)).map(\.yaml)
    }

    // MARK: - Locked helpers (on `queue`)

    private func latestLocked() throws -> ConfigSnapshot? {
        try selectLocked(where: "1", order: "sequence DESC", limit: 1, bind: { _ in }).first
    }

    private func insertLocked(_ snapshot: ConfigSnapshot) throws {
        let sections = String(
            decoding: try JSONEncoder().encode(snapshot.sectionsChanged.map(\.rawValue)), as: UTF8.self)
        try statementLocked(
            """
            INSERT INTO config_snapshots (id, sequence, taken_at, document, document_hash, sections_changed,
                caller_kind, caller_detail, approval_id, request_text, label)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, snapshot.id.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(snapshot.sequence))
                sqlite3_bind_double(stmt, 3, snapshot.takenAt.timeIntervalSince1970)
                let bytes = Array(snapshot.yaml.utf8)
                sqlite3_bind_blob(stmt, 4, bytes, Int32(bytes.count), configHistorySQLiteTransient)
                Self.bindText(stmt, 5, snapshot.documentHash)
                Self.bindText(stmt, 6, sections)
                Self.bindText(stmt, 7, snapshot.caller.kind)
                Self.bindOptionalText(stmt, 8, snapshot.caller.detail)
                Self.bindOptionalText(stmt, 9, snapshot.approvalId?.uuidString)
                Self.bindOptionalText(stmt, 10, snapshot.requestText)
                Self.bindOptionalText(stmt, 11, snapshot.label)
            },
            process: { stmt in
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw ConfigHistoryDatabaseError.failedToExecute("insert snapshot")
                }
            })
    }

    private func pruneLocked() throws {
        try statementLocked(
            """
            DELETE FROM config_snapshots WHERE label IS NULL AND sequence != 0 AND id NOT IN (
                SELECT id FROM config_snapshots WHERE label IS NULL AND sequence != 0
                ORDER BY sequence DESC LIMIT ?1)
            """,
            bind: { sqlite3_bind_int($0, 1, Int32(Self.retainedUnlabeled)) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    private func selectLocked(
        where clause: String, order: String = "sequence DESC", limit: Int? = nil,
        bind: (OpaquePointer) -> Void
    ) throws -> [ConfigSnapshot] {
        var rows: [ConfigSnapshot] = []
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        try statementLocked(
            """
            SELECT id, sequence, taken_at, document, sections_changed, caller_kind, caller_detail,
                approval_id, request_text, label
            FROM config_snapshots WHERE \(clause) ORDER BY \(order)\(limitClause)
            """,
            bind: bind,
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let row = Self.row(stmt) { rows.append(row) }
                }
            })
        return rows
    }

    private static func row(_ stmt: OpaquePointer) -> ConfigSnapshot? {
        guard let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, 3))
        let yaml: String
        if let blob = sqlite3_column_blob(stmt, 3), length > 0 {
            yaml = String(decoding: Data(bytes: blob, count: length), as: UTF8.self)
        } else {
            yaml = ""
        }
        let sectionNames = text(stmt, 4).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return ConfigSnapshot(
            id: id,
            sequence: Int(sqlite3_column_int64(stmt, 1)),
            takenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            yaml: yaml,
            sectionsChanged: sectionNames.compactMap(ConfigSectionID.init(rawValue:)),
            caller: ConfigChangeCaller(kind: text(stmt, 5) ?? "other", detail: text(stmt, 6)),
            approvalId: text(stmt, 7).flatMap(UUID.init(uuidString:)),
            requestText: text(stmt, 8),
            label: text(stmt, 9))
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    // MARK: - SQLite plumbing

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw ConfigHistoryDatabaseError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(connection, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw ConfigHistoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        try statementLocked(sql, bind: { _ in }, process: handler)
    }

    private func statementLocked(
        _ sql: String, bind: (OpaquePointer) -> Void, process: (OpaquePointer) throws -> Void
    ) throws {
        guard let connection = db else { throw ConfigHistoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ConfigHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        try process(stmt)
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, configHistorySQLiteTransient)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }
}

private let configHistorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
