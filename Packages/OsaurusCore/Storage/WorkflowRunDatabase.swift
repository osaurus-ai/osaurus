//
//  WorkflowRunDatabase.swift
//  osaurus
//
//  Encrypted SQLite store for workflow run records
//  (`~/.osaurus/workflows/runs.sqlite`). Run records can hold client data,
//  so they follow chat history's storage rules: SQLCipher at rest, the
//  shared storage key, rekeyed on rotation, deletable per workflow.
//
//  One row per run. The indexed columns serve the history list; the full
//  record (every node's input and output) is the JSON column.
//

import Foundation
import OsaurusSQLCipher

public enum WorkflowRunDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open workflow run database: \(m)"
        case .failedToExecute(let m): return "Failed to execute workflow run query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare workflow run statement: \(m)"
        case .migrationFailed(let m): return "Workflow run migration failed: \(m)"
        case .notOpen: return "Workflow run database is not open"
        }
    }
}

public final class WorkflowRunDatabase: @unchecked Sendable {
    public static let shared = WorkflowRunDatabase()

    private static let latestSchemaVersion = 2
    /// Newest runs kept per workflow; older ones are pruned on insert.
    static let retentionPerWorkflow = 200

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.workflow.runs")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.workflows())
            do {
                db = try OsaurusStorageOpener.open(path: OsaurusPaths.workflowRunsDatabaseFile().path, cacheTier: .cold)
            } catch let error as EncryptedSQLiteError {
                throw WorkflowRunDatabaseError.failedToOpen(error.localizedDescription)
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
        name: "workflowRuns",
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
        OsaurusDatabaseHandle.deregister(name: "workflowRuns")
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
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
                    CREATE TABLE IF NOT EXISTS workflow_runs (
                        id TEXT PRIMARY KEY,
                        workflow_id TEXT NOT NULL,
                        status TEXT NOT NULL,
                        is_test INTEGER NOT NULL DEFAULT 0,
                        started_at REAL NOT NULL,
                        record_json TEXT NOT NULL
                    )
                    """)
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_workflow_runs_workflow ON workflow_runs(workflow_id, started_at DESC)"
                )
                try executeRaw("PRAGMA user_version = 1")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw WorkflowRunDatabaseError.migrationFailed("v1: \(error.localizedDescription)")
            }
        }
        if version < 2 {
            do {
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_workflow_runs_recent ON workflow_runs(is_test, started_at DESC)")
                try executeRaw("PRAGMA user_version = 2")
            } catch {
                throw WorkflowRunDatabaseError.migrationFailed("v2: \(error.localizedDescription)")
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

    /// Returns the ids of older runs of the workflow dropped past
    /// `retentionPerWorkflow`, whose files the caller removes.
    @discardableResult
    public func upsert(_ run: WorkflowRun) throws -> [UUID] {
        let json = String(decoding: try Self.encoder.encode(run), as: UTF8.self)
        try prepareAndExecute(
            """
            INSERT INTO workflow_runs (id, workflow_id, status, is_test, started_at, record_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status, record_json = excluded.record_json
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, run.id.uuidString)
                Self.bindText(stmt, 2, run.workflowID.uuidString)
                Self.bindText(stmt, 3, run.status.rawValue)
                sqlite3_bind_int(stmt, 4, run.isTest ? 1 : 0)
                sqlite3_bind_double(stmt, 5, run.startedAt.timeIntervalSince1970)
                Self.bindText(stmt, 6, json)
            },
            process: { stmt in
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw WorkflowRunDatabaseError.failedToExecute("upsert run")
                }
            })
        var pruned: [UUID] = []
        try prepareAndExecute(
            """
            DELETE FROM workflow_runs WHERE workflow_id = ?1 AND id NOT IN (
                SELECT id FROM workflow_runs WHERE workflow_id = ?1 ORDER BY started_at DESC LIMIT ?2)
            RETURNING id
            """,
            bind: { stmt in
                Self.bindText(stmt, 1, run.workflowID.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(Self.retentionPerWorkflow))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) {
                        pruned.append(id)
                    }
                }
            })
        return pruned
    }

    public func deleteRun(id: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM workflow_runs WHERE id = ?1",
            bind: { Self.bindText($0, 1, id.uuidString) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    public func run(id: UUID) throws -> WorkflowRun? {
        try query(
            "SELECT record_json FROM workflow_runs WHERE id = ?1",
            bind: { Self.bindText($0, 1, id.uuidString) }
        ).first
    }

    /// A workflow's newest runs. `includeTests: false` leaves out
    /// Architect test runs and eval runs, which are not what the workflow
    /// did for anyone.
    public func runs(workflowID: UUID, limit: Int = 50, includeTests: Bool = true) throws -> [WorkflowRun] {
        try query(
            "SELECT record_json FROM workflow_runs WHERE workflow_id = ?1"
                + (includeTests ? "" : " AND is_test = 0") + " ORDER BY started_at DESC LIMIT ?2",
            bind: { stmt in
                Self.bindText(stmt, 1, workflowID.uuidString)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            })
    }

    /// The newest runs of every workflow, test runs left out, for the
    /// History lens.
    public func recentRuns(limit: Int = 200) throws -> [WorkflowRun] {
        try query(
            "SELECT record_json FROM workflow_runs WHERE is_test = 0 ORDER BY started_at DESC LIMIT ?1",
            bind: { sqlite3_bind_int($0, 1, Int32(limit)) })
    }

    /// Runs not yet terminal (running or awaiting the user), for resume
    /// after relaunch.
    public func openRuns() throws -> [WorkflowRun] {
        try query(
            "SELECT record_json FROM workflow_runs WHERE status IN ('running', 'awaiting_user') ORDER BY started_at",
            bind: { _ in })
    }

    public func deleteRuns(workflowID: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM workflow_runs WHERE workflow_id = ?1",
            bind: { Self.bindText($0, 1, workflowID.uuidString) },
            process: { stmt in _ = sqlite3_step(stmt) })
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void) throws -> [WorkflowRun] {
        var runs: [WorkflowRun] = []
        try prepareAndExecute(
            sql, bind: bind,
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let text = sqlite3_column_text(stmt, 0) else { continue }
                    if let run = try? Self.decoder.decode(WorkflowRun.self, from: Data(String(cString: text).utf8)) {
                        runs.append(run)
                    }
                }
            })
        return runs
    }

    // MARK: - SQLite plumbing

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw WorkflowRunDatabaseError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(connection, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw WorkflowRunDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw WorkflowRunDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WorkflowRunDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        try handler(stmt)
    }

    private func prepareAndExecute(
        _ sql: String, bind: (OpaquePointer) -> Void, process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw WorkflowRunDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw WorkflowRunDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            try process(stmt)
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, workflowRunSQLiteTransient)
    }
}

private let workflowRunSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
