//
//  WorkDatabase.swift
//  osaurus
//
//  SQLite database management for Osaurus Agents.
//  Handles schema creation, migrations, and database lifecycle.
//

import Foundation
import SQLite3

/// Errors that can occur during database operations
public enum WorkDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let message): return "Failed to open database: \(message)"
        case .failedToExecute(let message): return "Failed to execute query: \(message)"
        case .failedToPrepare(let message): return "Failed to prepare statement: \(message)"
        case .migrationFailed(let message): return "Migration failed: \(message)"
        case .notOpen: return "Database is not open"
        }
    }
}

/// SQLite database manager for Osaurus Agents
/// Manages the work.db database containing issues, dependencies, and events
public final class WorkDatabase: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = WorkDatabase()

    /// Current schema version
    private static let schemaVersion = 2

    /// Database connection pointer
    private var db: OpaquePointer?

    /// Serial queue for database operations
    private let queue = DispatchQueue(label: "ai.osaurus.work.database")

    /// Whether the database is currently open
    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    private init() {}

    deinit {
        close()
    }

    // MARK: - Lifecycle

    private static let legacyDatabasePath: URL = OsaurusPaths.root()
        .appendingPathComponent("agent", isDirectory: true)
        .appendingPathComponent("agent.db")

    /// Opens the database connection and runs migrations
    public func open() throws {
        try queue.sync {
            guard db == nil else { return }

            OsaurusPaths.ensureExistsSilent(OsaurusPaths.workData())

            try openConnection()
            try runMigrations()
            try recoverLegacyDataIfNeeded()
        }
    }

    /// Closes the database connection
    public func close() {
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Legacy Database Recovery

    /// Replaces an empty work.db with agent.db if the user already launched
    /// the broken version (schema exists but no data).
    private func recoverLegacyDataIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: Self.legacyDatabasePath.path) else { return }

        var hasData = false
        try executeRaw("SELECT COUNT(*) FROM tasks") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                hasData = sqlite3_column_int(stmt, 0) > 0
            }
        }
        guard !hasData else { return }

        if let connection = db { sqlite3_close(connection); db = nil }

        let newPath = OsaurusPaths.workDatabaseFile()
        try? FileManager.default.removeItem(at: newPath)
        try FileManager.default.copyItem(at: Self.legacyDatabasePath, to: newPath)
        print("[WorkDatabase] Recovered data from legacy agent.db")

        try openConnection()
        try runMigrations()
    }

    /// Opens the SQLite connection and enables foreign keys.
    private func openConnection() throws {
        let path = OsaurusPaths.workDatabaseFile().path
        var dbPointer: OpaquePointer?
        let result = sqlite3_open(path, &dbPointer)
        guard result == SQLITE_OK, let connection = dbPointer else {
            let message = String(cString: sqlite3_errmsg(dbPointer))
            sqlite3_close(dbPointer)
            throw WorkDatabaseError.failedToOpen(message)
        }
        db = connection
        try executeRaw("PRAGMA foreign_keys = ON")
    }

    // MARK: - Schema & Migrations

    /// Runs database migrations to bring schema to current version
    private func runMigrations() throws {
        // Get current version
        let currentVersion = try getSchemaVersion()

        if currentVersion < 1 {
            try migrateToV1()
        }

        if currentVersion < 2 {
            try migrateToV2()
        }
    }

    /// Gets the current schema version from the database
    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    /// Sets the schema version in the database
    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    /// Migration to schema version 1 - initial schema
    private func migrateToV1() throws {

        // Create issues table
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS issues (
                    id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    description TEXT,
                    context TEXT,
                    status TEXT NOT NULL DEFAULT 'open',
                    priority INTEGER NOT NULL DEFAULT 2,
                    type TEXT NOT NULL DEFAULT 'task',
                    result TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """
        )

        // Create index on task_id for efficient task queries
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_issues_task_id ON issues(task_id)")

        // Create index on status for ready/blocked queries
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_issues_status ON issues(status)")

        // Create dependencies table
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS dependencies (
                    id TEXT PRIMARY KEY,
                    from_issue_id TEXT NOT NULL,
                    to_issue_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (from_issue_id) REFERENCES issues(id) ON DELETE CASCADE,
                    FOREIGN KEY (to_issue_id) REFERENCES issues(id) ON DELETE CASCADE
                )
            """
        )

        // Create indexes for dependency lookups
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_deps_from ON dependencies(from_issue_id)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_deps_to ON dependencies(to_issue_id)")

        // Create events table (append-only audit log)
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    issue_id TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    payload TEXT,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
                )
            """
        )

        // Create index for event history queries
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_events_issue ON events(issue_id)")

        // Create tasks table (groups issues by original query)
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    query TEXT NOT NULL,
                    persona_id TEXT,
                    status TEXT NOT NULL DEFAULT 'active',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """
        )

        // Create index for task listing
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_persona ON tasks(persona_id)")

        // Create artifacts table for storing generated content
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS artifacts (
                    id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    content TEXT NOT NULL,
                    content_type TEXT NOT NULL,
                    is_final_result INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
                )
            """
        )

        // Create index for efficient artifact lookups by task
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_artifacts_task ON artifacts(task_id)")

        try setSchemaVersion(1)
    }

    /// Migration to schema version 2 - add conversation turns table
    private func migrateToV2() throws {
        // Direct conversation turn storage (replaces event-sourcing reconstruction)
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS conversation_turns (
                    id TEXT PRIMARY KEY,
                    issue_id TEXT NOT NULL,
                    turn_order INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT,
                    thinking TEXT,
                    tool_calls_json TEXT,
                    tool_results_json TEXT,
                    tool_call_id TEXT,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
                )
            """
        )

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_conv_turns_issue ON conversation_turns(issue_id, turn_order)"
        )

        try setSchemaVersion(2)
    }

    // MARK: - Query Execution

    /// Executes a raw SQL statement without results
    private func executeRaw(_ sql: String) throws {
        guard let connection = db else {
            throw WorkDatabaseError.notOpen
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)

        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw WorkDatabaseError.failedToExecute(message)
        }
    }

    /// Executes a raw SQL statement with a result handler
    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else {
            throw WorkDatabaseError.notOpen
        }

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)

        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw WorkDatabaseError.failedToPrepare(message)
        }

        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    /// Executes a query on the database queue
    public func execute<T>(_ operation: @escaping (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else {
                throw WorkDatabaseError.notOpen
            }
            return try operation(connection)
        }
    }

    /// Prepares and executes a parameterized statement
    public func prepareAndExecute(_ sql: String, bind: (OpaquePointer) -> Void, process: (OpaquePointer) throws -> Void)
        throws
    {
        try queue.sync {
            guard let connection = db else {
                throw WorkDatabaseError.notOpen
            }

            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)

            guard prepareResult == SQLITE_OK, let statement = stmt else {
                let message = String(cString: sqlite3_errmsg(connection))
                throw WorkDatabaseError.failedToPrepare(message)
            }

            defer { sqlite3_finalize(statement) }

            bind(statement)
            try process(statement)
        }
    }

    /// Executes an INSERT/UPDATE/DELETE statement and returns success
    public func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        var success = false
        try prepareAndExecute(sql, bind: bind) { stmt in
            let result = sqlite3_step(stmt)
            success = (result == SQLITE_DONE)
        }
        return success
    }

    /// Begins a transaction
    public func beginTransaction() throws {
        try queue.sync {
            try executeRaw("BEGIN TRANSACTION")
        }
    }

    /// Commits the current transaction
    public func commitTransaction() throws {
        try queue.sync {
            try executeRaw("COMMIT")
        }
    }

    /// Rolls back the current transaction
    public func rollbackTransaction() throws {
        try queue.sync {
            try executeRaw("ROLLBACK")
        }
    }

    /// Executes multiple operations in a transaction
    public func inTransaction<T>(_ operation: () throws -> T) throws -> T {
        try beginTransaction()
        do {
            let result = try operation()
            try commitTransaction()
            return result
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }
}

// MARK: - SQLite Helpers

extension WorkDatabase {
    /// Binds a string value to a statement parameter
    public static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Binds an integer value to a statement parameter
    public static func bindInt(_ stmt: OpaquePointer, index: Int32, value: Int) {
        sqlite3_bind_int(stmt, index, Int32(value))
    }

    /// Binds a date value to a statement parameter (as ISO8601 string)
    public static func bindDate(_ stmt: OpaquePointer, index: Int32, value: Date) {
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: value)
        bindText(stmt, index: index, value: dateString)
    }

    /// Gets a string column value
    public static func getText(_ stmt: OpaquePointer, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    /// Gets an integer column value
    public static func getInt(_ stmt: OpaquePointer, column: Int32) -> Int {
        Int(sqlite3_column_int(stmt, column))
    }

    /// Gets a date column value (from ISO8601 string)
    public static func getDate(_ stmt: OpaquePointer, column: Int32) -> Date? {
        guard let dateString = getText(stmt, column: column) else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: dateString)
    }
}
