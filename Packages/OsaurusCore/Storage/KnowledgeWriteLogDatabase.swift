//
//  KnowledgeWriteLogDatabase.swift
//  osaurus
//
//  Durable log of agent-made changes to knowledge collection folders.
//  WAL mode, serial queue, versioned migrations.
//
//  Tables:
//    knowledge_writes — one row per applied mutation, with the content it
//                       replaced, so the change can be reverted later
//
//  Deliberately a SEPARATE file from `knowledge.sqlite`.
//
//  That database is a derived index: the markdown files are the source of
//  truth, every row is rebuildable, and deleting the file is the supported
//  recovery for a corrupt or stale index. This log breaks that invariant —
//  `prior_content` exists nowhere else once a document is overwritten, so it
//  is primary data, not a derived artifact. Folding it into the index would
//  mean the standard fix for an unrelated indexing problem silently destroys
//  the undo history that makes call-time write approval safe (osaurus#2439).
//
//  Retention is bounded (see `pruneToRetentionLimit`): the log stores whole
//  prior documents, so an unbounded history of a frequently rewritten
//  collection would grow without limit.
//

import Foundation
import OsaurusSQLCipher

public enum KnowledgeWriteLogError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open knowledge write log: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Knowledge write log migration failed: \(msg)"
        case .notOpen: return "Knowledge write log is not open"
        }
    }
}

public final class KnowledgeWriteLogDatabase: @unchecked Sendable {
    public static let shared = KnowledgeWriteLogDatabase()

    private static let latestSchemaVersion = 1

    /// Same additive-only contract as the other stores, so a database stamped
    /// by a newer build opens instead of being refused. Refusing here would
    /// present as "my undo history vanished", which is the failure mode this
    /// log exists to prevent.
    static let migrationsAreAdditiveOnly = true

    /// Newest N records kept per collection. Whole prior documents are stored,
    /// so history has to be bounded; 500 is far more than any plausible
    /// review-and-revert window while staying small on disk.
    static let retentionLimitPerCollection = 500

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.knowledge.writelog")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.knowledge())
            do {
                db = try OsaurusStorageOpener.open(
                    path: OsaurusPaths.knowledgeWriteLogDatabaseFile().path
                )
            } catch let error as EncryptedSQLiteError {
                throw KnowledgeWriteLogError.failedToOpen(error.localizedDescription)
            }
            do {
                try runMigrations()
            } catch {
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "knowledgeWriteLog",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext**.
    public func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "knowledgeWriteLog")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Schema

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        if currentVersion > Self.latestSchemaVersion { return }
        if currentVersion < 1 {
            try runMigrationStep(1, migrateToV1)
        }
    }

    private func runMigrationStep(_ version: Int, _ body: () throws -> Void) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            try body()
            try setSchemaVersion(version)
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw KnowledgeWriteLogError.migrationFailed(
                "v\(version): \(error.localizedDescription)"
            )
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    /// `prior_content` holds the entire previous document rather than a diff:
    /// a revert must not depend on the current file still being what the agent
    /// left behind. `result_content_hash` is what the write PUT on disk ("" for
    /// a delete, matching an absent file), so a revert can tell in one uniform
    /// comparison whether anyone changed the document afterwards.
    ///
    /// `run_id` groups one agent run's writes so a bad bulk import reverts as
    /// a unit, which is the affordance that actually matters after an import
    /// goes wrong. Rows survive reverting (`reverted_at` stamped) so history
    /// stays readable instead of silently shrinking.
    private func migrateToV1() throws {
        KnowledgeLogger.database.info("Running knowledge write log v1 migration")
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS knowledge_writes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                collection_id TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                operation TEXT NOT NULL,
                prior_content TEXT NOT NULL DEFAULT '',
                prior_content_hash TEXT NOT NULL DEFAULT '',
                result_content_hash TEXT NOT NULL DEFAULT '',
                run_id TEXT NOT NULL DEFAULT '',
                created_by TEXT NOT NULL DEFAULT '',
                rationale TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                reverted_at TEXT
            )
            """
        )
        // The two access patterns: a collection's history view, and
        // "revert everything this run did".
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_knowledge_writes_collection "
                + "ON knowledge_writes(collection_id, id DESC)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_knowledge_writes_run ON knowledge_writes(run_id)"
        )
        KnowledgeLogger.database.info("Knowledge write log v1 migration completed")
    }

    // MARK: - Records

    private static let columns =
        "id, collection_id, rel_path, operation, prior_content, prior_content_hash, "
        + "result_content_hash, run_id, created_by, rationale, created_at, reverted_at"

    private static func readRecord(_ stmt: OpaquePointer) -> KnowledgeWriteRecord {
        KnowledgeWriteRecord(
            id: Int(sqlite3_column_int64(stmt, 0)),
            collectionId: columnText(stmt, 1),
            relPath: columnText(stmt, 2),
            operation: KnowledgeWriteOperation(rawValue: columnText(stmt, 3)) ?? .replace,
            priorContent: columnText(stmt, 4),
            priorContentHash: columnText(stmt, 5),
            resultContentHash: columnText(stmt, 6),
            runId: columnText(stmt, 7),
            createdBy: columnText(stmt, 8),
            rationale: columnText(stmt, 9),
            createdAt: columnText(stmt, 10),
            revertedAt: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : columnText(stmt, 11)
        )
    }

    /// Record one applied mutation, returning its row id.
    @discardableResult
    public func insert(
        collectionId: String,
        relPath: String,
        operation: KnowledgeWriteOperation,
        priorContent: String,
        priorContentHash: String,
        resultContentHash: String,
        runId: String,
        createdBy: String,
        rationale: String,
        createdAt: String
    ) throws -> Int {
        var rowId = 0
        try prepareAndExecute(
            """
            INSERT INTO knowledge_writes
                (collection_id, rel_path, operation, prior_content, prior_content_hash,
                 result_content_hash, run_id, created_by, rationale, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            RETURNING id
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
                Self.bindText(stmt, index: 3, value: operation.rawValue)
                Self.bindText(stmt, index: 4, value: priorContent)
                Self.bindText(stmt, index: 5, value: priorContentHash)
                Self.bindText(stmt, index: 6, value: resultContentHash)
                Self.bindText(stmt, index: 7, value: runId)
                Self.bindText(stmt, index: 8, value: createdBy)
                Self.bindText(stmt, index: 9, value: rationale)
                Self.bindText(stmt, index: 10, value: createdAt)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    rowId = Int(sqlite3_column_int64(stmt, 0))
                }
            }
        )
        guard rowId != 0 else {
            throw KnowledgeWriteLogError.failedToExecute("insert returned no id")
        }
        try? pruneToRetentionLimit(collectionId: collectionId)
        return rowId
    }

    public func record(id: Int) throws -> KnowledgeWriteRecord? {
        var record: KnowledgeWriteRecord?
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM knowledge_writes WHERE id = ?1 LIMIT 1",
            bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    record = Self.readRecord(stmt)
                }
            }
        )
        return record
    }

    /// One collection's write history, newest first.
    public func records(
        collectionId: String,
        includeReverted: Bool = true,
        limit: Int = 200
    ) throws -> [KnowledgeWriteRecord] {
        var records: [KnowledgeWriteRecord] = []
        var sql = "SELECT \(Self.columns) FROM knowledge_writes WHERE collection_id = ?1"
        if !includeReverted { sql += " AND reverted_at IS NULL" }
        sql += " ORDER BY id DESC LIMIT ?2"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    records.append(Self.readRecord(stmt))
                }
            }
        )
        return records
    }

    /// Every not-yet-reverted write from one agent run, NEWEST FIRST.
    ///
    /// The order is load-bearing: reverting in reverse application order is
    /// the only sequence that restores correctly when one run wrote the same
    /// path more than once.
    public func records(runId: String) throws -> [KnowledgeWriteRecord] {
        var records: [KnowledgeWriteRecord] = []
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM knowledge_writes "
                + "WHERE run_id = ?1 AND reverted_at IS NULL ORDER BY id DESC",
            bind: { stmt in Self.bindText(stmt, index: 1, value: runId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    records.append(Self.readRecord(stmt))
                }
            }
        )
        return records
    }

    /// Recent records across every collection, newest first. Drives the
    /// Knowledge tab's history view, which is not scoped to one collection.
    public func recentRecords(limit: Int = 200) throws -> [KnowledgeWriteRecord] {
        var records: [KnowledgeWriteRecord] = []
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM knowledge_writes ORDER BY id DESC LIMIT ?1",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(limit)) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    records.append(Self.readRecord(stmt))
                }
            }
        )
        return records
    }

    /// Stamp a record reverted. Keeps the row so history stays readable.
    public func markReverted(id: Int, revertedAt: String) throws {
        try prepareAndExecute(
            "UPDATE knowledge_writes SET reverted_at = ?2 WHERE id = ?1",
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(id))
                Self.bindText(stmt, index: 2, value: revertedAt)
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    /// Drop the oldest records for a collection past the retention limit.
    ///
    /// Already-reverted rows are discarded first: they hold prior content that
    /// has already been restored, so they are pure history, while an
    /// un-reverted row is still someone's undo. Only if the un-reverted rows
    /// alone exceed the limit does the oldest of those get dropped.
    func pruneToRetentionLimit(collectionId: String) throws {
        try prepareAndExecute(
            """
            DELETE FROM knowledge_writes WHERE id IN (
                SELECT id FROM knowledge_writes
                WHERE collection_id = ?1
                ORDER BY (reverted_at IS NULL) DESC, id DESC
                LIMIT -1 OFFSET ?2
            )
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                sqlite3_bind_int(stmt, 2, Int32(Self.retentionLimitPerCollection))
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    /// Discard a deleted collection's history. Nothing can be reverted into a
    /// collection that no longer exists.
    public func deleteRecords(collectionId: String) throws {
        try prepareAndExecute(
            "DELETE FROM knowledge_writes WHERE collection_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    // MARK: - SQLite plumbing

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw KnowledgeWriteLogError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(connection, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw KnowledgeWriteLogError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw KnowledgeWriteLogError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw KnowledgeWriteLogError.failedToPrepare(
                String(cString: sqlite3_errmsg(connection))
            )
        }
        defer { sqlite3_finalize(stmt) }
        guard let stmt else { throw KnowledgeWriteLogError.failedToPrepare("nil statement") }
        try handler(stmt)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw KnowledgeWriteLogError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw KnowledgeWriteLogError.failedToPrepare(
                    String(cString: sqlite3_errmsg(connection))
                )
            }
            defer { sqlite3_finalize(stmt) }
            guard let stmt else { throw KnowledgeWriteLogError.failedToPrepare("nil statement") }
            bind(stmt)
            try process(stmt)
        }
    }

    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, writeLogSQLiteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}

/// SQLITE_TRANSIENT: tell SQLite to copy the string immediately.
private let writeLogSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
