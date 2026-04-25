//
//  ToolDatabase.swift
//  osaurus
//
//  SQLite database for the unified tool index across sandbox, native, and built-in tools.
//  WAL mode, serial queue, versioned migrations — follows MemoryDatabase patterns.
//

import Foundation
import OsaurusSQLCipher

// MARK: - Error

public enum ToolDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open tool database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Tool migration failed: \(msg)"
        case .notOpen: return "Tool database is not open"
        }
    }
}

// MARK: - ToolIndexEntry

public struct ToolIndexEntry: Sendable {
    public let id: String
    public var name: String
    public var description: String
    public var runtime: ToolRuntime
    public var manifestPath: String?
    public var bundleId: String?
    public var toolsJSON: String
    public var source: ToolIndexSource
    public var tokenCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        description: String,
        runtime: ToolRuntime,
        manifestPath: String? = nil,
        bundleId: String? = nil,
        toolsJSON: String = "[]",
        source: ToolIndexSource = .system,
        tokenCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.runtime = runtime
        self.manifestPath = manifestPath
        self.bundleId = bundleId
        self.toolsJSON = toolsJSON
        self.source = source
        self.tokenCount = tokenCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ToolRuntime: String, Codable, Sendable {
    case sandbox
    case native
    case builtin
    case mcp
}

public enum ToolIndexSource: String, Codable, Sendable {
    case manual
    case community
    case system
}

// MARK: - ToolDatabase

public final class ToolDatabase: @unchecked Sendable {
    public static let shared = ToolDatabase()

    private static let schemaVersion = 1

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private static func dateFromISO8601(_ string: String) -> Date {
        iso8601Formatter.date(from: string) ?? Date()
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.tools.database")
    private let stmtCache = PreparedStatementCache(capacity: 24)

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale.
        StorageMigrationCoordinator.blockingAwaitReady()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.toolIndex())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "tool-index",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    func openInMemory() throws {
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
        OsaurusDatabaseHandle.deregister(name: "tool-index")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Connection

    private func openConnection() throws {
        let path = OsaurusPaths.toolIndexDatabaseFile().path
        let key = try StorageKeyManager.shared.currentKey()
        do {
            db = try EncryptedSQLiteOpener.open(path: path, key: key)
        } catch let error as EncryptedSQLiteError {
            throw ToolDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        if currentVersion < 1 { try migrateToV1() }
    }

    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
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

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS tool_index (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    description     TEXT NOT NULL,
                    runtime         TEXT NOT NULL,
                    manifest_path   TEXT,
                    bundle_id       TEXT,
                    tools_json      TEXT NOT NULL,
                    source          TEXT NOT NULL,
                    token_count     INTEGER NOT NULL,
                    created_at      TEXT NOT NULL,
                    updated_at      TEXT NOT NULL
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tool_index_runtime ON tool_index(runtime)")
        try setSchemaVersion(1)
    }

    // MARK: - Raw Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw ToolDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw ToolDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw ToolDatabaseError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw ToolDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw ToolDatabaseError.notOpen }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                let message = String(cString: sqlite3_errmsg(connection))
                throw ToolDatabaseError.failedToPrepare(message)
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepareAndExecute(sql, bind: bind) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ToolDatabaseError.failedToExecute("step failed")
            }
        }
    }

    // MARK: - CRUD

    private static let columns =
        "id, name, description, runtime, manifest_path, bundle_id, tools_json, source, token_count, created_at, updated_at"

    public func upsertEntry(_ entry: ToolIndexEntry) throws {
        let now = Self.iso8601Now()
        try executeUpdate(
            """
            INSERT INTO tool_index (\(Self.columns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, description = excluded.description,
                runtime = excluded.runtime, manifest_path = excluded.manifest_path,
                bundle_id = excluded.bundle_id, tools_json = excluded.tools_json,
                source = excluded.source, token_count = excluded.token_count,
                updated_at = excluded.updated_at
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: entry.id)
            Self.bindText(stmt, index: 2, value: entry.name)
            Self.bindText(stmt, index: 3, value: entry.description)
            Self.bindText(stmt, index: 4, value: entry.runtime.rawValue)
            Self.bindText(stmt, index: 5, value: entry.manifestPath)
            Self.bindText(stmt, index: 6, value: entry.bundleId)
            Self.bindText(stmt, index: 7, value: entry.toolsJSON)
            Self.bindText(stmt, index: 8, value: entry.source.rawValue)
            sqlite3_bind_int(stmt, 9, Int32(entry.tokenCount))
            Self.bindText(stmt, index: 10, value: now)
            Self.bindText(stmt, index: 11, value: now)
        }
    }

    public func deleteEntry(id: String) throws {
        try executeUpdate("DELETE FROM tool_index WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    public func loadEntry(id: String) throws -> ToolIndexEntry? {
        var entry: ToolIndexEntry?
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM tool_index WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entry = Self.readEntry(from: stmt)
                }
            }
        )
        return entry
    }

    public func loadAllEntries() throws -> [ToolIndexEntry] {
        var entries: [ToolIndexEntry] = []
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM tool_index ORDER BY name",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readEntry(from: stmt))
                }
            }
        )
        return entries
    }

    public func entryCount() throws -> Int {
        var count = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM tool_index",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    public func deleteAll() throws {
        try queue.sync {
            try executeRaw("DELETE FROM tool_index")
        }
    }

    // MARK: - Row Reader

    private static func readEntry(from stmt: OpaquePointer) -> ToolIndexEntry {
        ToolIndexEntry(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            description: String(cString: sqlite3_column_text(stmt, 2)),
            runtime: ToolRuntime(rawValue: String(cString: sqlite3_column_text(stmt, 3))) ?? .builtin,
            manifestPath: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            bundleId: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            toolsJSON: String(cString: sqlite3_column_text(stmt, 6)),
            source: ToolIndexSource(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .system,
            tokenCount: Int(sqlite3_column_int(stmt, 8)),
            createdAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 9))),
            updatedAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 10)))
        )
    }
}

// MARK: - SQLite Helpers

private let toolSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension ToolDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, toolSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
