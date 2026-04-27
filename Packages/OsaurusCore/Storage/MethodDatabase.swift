//
//  MethodDatabase.swift
//  osaurus
//
//  SQLite database for the methods subsystem.
//  WAL mode, serial queue, versioned migrations — follows MemoryDatabase patterns.
//

import Foundation
import OsaurusSQLCipher

// MARK: - Error

public enum MethodDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open method database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Method migration failed: \(msg)"
        case .notOpen: return "Method database is not open"
        }
    }
}

// MARK: - MethodDatabase

public final class MethodDatabase: @unchecked Sendable {
    public static let shared = MethodDatabase()

    private static let schemaVersion = 1

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    static func dateFromISO8601(_ string: String) -> Date {
        iso8601Formatter.date(from: string) ?? Date()
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.methods.database")
    private let stmtCache = PreparedStatementCache(capacity: 32)

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
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.methods())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "methods",
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
        OsaurusDatabaseHandle.deregister(name: "methods")
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
        let path = OsaurusPaths.methodsDatabaseFile().path
        let key = try StorageKeyManager.shared.currentKey()
        do {
            db = try EncryptedSQLiteOpener.open(path: path, key: key)
        } catch let error as EncryptedSQLiteError {
            throw MethodDatabaseError.failedToOpen(error.localizedDescription)
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
        MethodLogger.database.info("Running migration to v1")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS methods (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    description     TEXT NOT NULL,
                    trigger_text    TEXT,
                    body            TEXT NOT NULL,
                    source          TEXT NOT NULL,
                    source_model    TEXT,
                    tier            TEXT NOT NULL DEFAULT 'active',
                    tools_used      TEXT,
                    skills_used     TEXT,
                    token_count     INTEGER NOT NULL,
                    version         INTEGER NOT NULL DEFAULT 1,
                    created_at      TEXT NOT NULL,
                    updated_at      TEXT NOT NULL
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_methods_tier ON methods(tier)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_methods_name ON methods(name)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS method_events (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    method_id       TEXT NOT NULL REFERENCES methods(id) ON DELETE CASCADE,
                    event_type      TEXT NOT NULL,
                    model_used      TEXT,
                    agent_id        TEXT,
                    notes           TEXT,
                    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_method_events_method ON method_events(method_id, event_type)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_method_events_created ON method_events(created_at)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS method_scores (
                    method_id       TEXT PRIMARY KEY REFERENCES methods(id) ON DELETE CASCADE,
                    times_loaded    INTEGER NOT NULL DEFAULT 0,
                    times_succeeded INTEGER NOT NULL DEFAULT 0,
                    times_failed    INTEGER NOT NULL DEFAULT 0,
                    success_rate    REAL NOT NULL DEFAULT 0.0,
                    last_used_at    TEXT,
                    score           REAL NOT NULL DEFAULT 0.0
                )
            """
        )

        try setSchemaVersion(1)
        MethodLogger.database.info("Migration to v1 completed")
    }

    // MARK: - Raw Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else {
            throw MethodDatabaseError.notOpen
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw MethodDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else {
            throw MethodDatabaseError.notOpen
        }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw MethodDatabaseError.failedToPrepare(message)
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
            guard let connection = db else {
                throw MethodDatabaseError.notOpen
            }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                let message = String(cString: sqlite3_errmsg(connection))
                throw MethodDatabaseError.failedToPrepare(message)
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepareAndExecute(sql, bind: bind) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw MethodDatabaseError.failedToExecute("step failed")
            }
        }
    }

    // MARK: - Methods CRUD

    private static let methodColumns = """
        id, name, description, trigger_text, body, source, source_model,
        tier, tools_used, skills_used, token_count, version, created_at, updated_at
        """

    public func insertMethod(_ method: Method) throws {
        let now = Self.iso8601Now()
        try executeUpdate(
            """
            INSERT INTO methods (\(Self.methodColumns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: method.id)
            Self.bindText(stmt, index: 2, value: method.name)
            Self.bindText(stmt, index: 3, value: method.description)
            Self.bindText(stmt, index: 4, value: method.triggerText)
            Self.bindText(stmt, index: 5, value: method.body)
            Self.bindText(stmt, index: 6, value: method.source.rawValue)
            Self.bindText(stmt, index: 7, value: method.sourceModel)
            Self.bindText(stmt, index: 8, value: method.tier.rawValue)
            Self.bindText(stmt, index: 9, value: Self.encodeJSON(method.toolsUsed))
            Self.bindText(stmt, index: 10, value: Self.encodeJSON(method.skillsUsed))
            sqlite3_bind_int(stmt, 11, Int32(method.tokenCount))
            sqlite3_bind_int(stmt, 12, Int32(method.version))
            Self.bindText(stmt, index: 13, value: now)
            Self.bindText(stmt, index: 14, value: now)
        }

        try upsertScore(MethodScore(methodId: method.id))
    }

    public func updateMethod(_ method: Method) throws {
        let now = Self.iso8601Now()
        try executeUpdate(
            """
            UPDATE methods SET name = ?1, description = ?2, trigger_text = ?3, body = ?4,
                source = ?5, source_model = ?6, tier = ?7, tools_used = ?8, skills_used = ?9,
                token_count = ?10, version = ?11, updated_at = ?12
            WHERE id = ?13
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: method.name)
            Self.bindText(stmt, index: 2, value: method.description)
            Self.bindText(stmt, index: 3, value: method.triggerText)
            Self.bindText(stmt, index: 4, value: method.body)
            Self.bindText(stmt, index: 5, value: method.source.rawValue)
            Self.bindText(stmt, index: 6, value: method.sourceModel)
            Self.bindText(stmt, index: 7, value: method.tier.rawValue)
            Self.bindText(stmt, index: 8, value: Self.encodeJSON(method.toolsUsed))
            Self.bindText(stmt, index: 9, value: Self.encodeJSON(method.skillsUsed))
            sqlite3_bind_int(stmt, 10, Int32(method.tokenCount))
            sqlite3_bind_int(stmt, 11, Int32(method.version))
            Self.bindText(stmt, index: 12, value: now)
            Self.bindText(stmt, index: 13, value: method.id)
        }
    }

    public func loadMethod(id: String) throws -> Method? {
        var method: Method?
        try prepareAndExecute(
            "SELECT \(Self.methodColumns) FROM methods WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    method = Self.readMethod(from: stmt)
                }
            }
        )
        return method
    }

    public func loadAllMethods() throws -> [Method] {
        var methods: [Method] = []
        try prepareAndExecute(
            "SELECT \(Self.methodColumns) FROM methods ORDER BY updated_at DESC",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    methods.append(Self.readMethod(from: stmt))
                }
            }
        )
        return methods
    }

    public func loadMethodsByIds(_ ids: [String]) throws -> [Method] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        var methods: [Method] = []
        try prepareAndExecute(
            "SELECT \(Self.methodColumns) FROM methods WHERE id IN (\(placeholders))",
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    Self.bindText(stmt, index: Int32(i + 1), value: id)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    methods.append(Self.readMethod(from: stmt))
                }
            }
        )
        return methods
    }

    public func deleteMethod(id: String) throws {
        try executeUpdate("DELETE FROM methods WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    // MARK: - Method Events

    public func insertEvent(_ event: MethodEvent) throws {
        try executeUpdate(
            """
            INSERT INTO method_events (method_id, event_type, model_used, agent_id, notes, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: event.methodId)
            Self.bindText(stmt, index: 2, value: event.eventType.rawValue)
            Self.bindText(stmt, index: 3, value: event.modelUsed)
            Self.bindText(stmt, index: 4, value: event.agentId)
            Self.bindText(stmt, index: 5, value: event.notes)
            Self.bindText(stmt, index: 6, value: Self.iso8601Formatter.string(from: event.createdAt))
        }
    }

    public func loadEvents(methodId: String, ofType type: MethodEventType? = nil) throws -> [MethodEvent] {
        var events: [MethodEvent] = []
        let sql: String
        let bindFn: (OpaquePointer) -> Void

        if let type {
            sql =
                "SELECT id, method_id, event_type, model_used, agent_id, notes, created_at FROM method_events WHERE method_id = ?1 AND event_type = ?2 ORDER BY created_at"
            bindFn = { stmt in
                Self.bindText(stmt, index: 1, value: methodId)
                Self.bindText(stmt, index: 2, value: type.rawValue)
            }
        } else {
            sql =
                "SELECT id, method_id, event_type, model_used, agent_id, notes, created_at FROM method_events WHERE method_id = ?1 ORDER BY created_at"
            bindFn = { stmt in
                Self.bindText(stmt, index: 1, value: methodId)
            }
        }

        try prepareAndExecute(sql, bind: bindFn) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(Self.readEvent(from: stmt))
            }
        }
        return events
    }

    // MARK: - Method Scores

    public func loadScore(methodId: String) throws -> MethodScore? {
        var score: MethodScore?
        try prepareAndExecute(
            """
            SELECT method_id, times_loaded, times_succeeded, times_failed,
                   success_rate, last_used_at, score
            FROM method_scores WHERE method_id = ?1
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: methodId) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    score = Self.readScore(from: stmt)
                }
            }
        )
        return score
    }

    public func upsertScore(_ score: MethodScore) throws {
        try executeUpdate(
            """
            INSERT INTO method_scores (method_id, times_loaded, times_succeeded, times_failed,
                                       success_rate, last_used_at, score)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(method_id) DO UPDATE SET
                times_loaded = excluded.times_loaded,
                times_succeeded = excluded.times_succeeded,
                times_failed = excluded.times_failed,
                success_rate = excluded.success_rate,
                last_used_at = excluded.last_used_at,
                score = excluded.score
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: score.methodId)
            sqlite3_bind_int(stmt, 2, Int32(score.timesLoaded))
            sqlite3_bind_int(stmt, 3, Int32(score.timesSucceeded))
            sqlite3_bind_int(stmt, 4, Int32(score.timesFailed))
            sqlite3_bind_double(stmt, 5, score.successRate)
            if let last = score.lastUsedAt {
                Self.bindText(stmt, index: 6, value: Self.iso8601Formatter.string(from: last))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_double(stmt, 7, score.score)
        }
    }

    // MARK: - Row Readers

    private static func readMethod(from stmt: OpaquePointer) -> Method {
        Method(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            description: String(cString: sqlite3_column_text(stmt, 2)),
            triggerText: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            body: String(cString: sqlite3_column_text(stmt, 4)),
            source: MethodSource(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .user,
            sourceModel: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
            tier: MethodTier(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .active,
            toolsUsed: decodeJSON(sqlite3_column_text(stmt, 8).map { String(cString: $0) }),
            skillsUsed: decodeJSON(sqlite3_column_text(stmt, 9).map { String(cString: $0) }),
            tokenCount: Int(sqlite3_column_int(stmt, 10)),
            version: Int(sqlite3_column_int(stmt, 11)),
            createdAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 12))),
            updatedAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 13)))
        )
    }

    private static func readEvent(from stmt: OpaquePointer) -> MethodEvent {
        MethodEvent(
            id: Int(sqlite3_column_int(stmt, 0)),
            methodId: String(cString: sqlite3_column_text(stmt, 1)),
            eventType: MethodEventType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .loaded,
            modelUsed: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            agentId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            notes: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            createdAt: dateFromISO8601(String(cString: sqlite3_column_text(stmt, 6)))
        )
    }

    private static func readScore(from stmt: OpaquePointer) -> MethodScore {
        MethodScore(
            methodId: String(cString: sqlite3_column_text(stmt, 0)),
            timesLoaded: Int(sqlite3_column_int(stmt, 1)),
            timesSucceeded: Int(sqlite3_column_int(stmt, 2)),
            timesFailed: Int(sqlite3_column_int(stmt, 3)),
            successRate: sqlite3_column_double(stmt, 4),
            lastUsedAt: sqlite3_column_text(stmt, 5).map { dateFromISO8601(String(cString: $0)) },
            score: sqlite3_column_double(stmt, 6)
        )
    }

    // MARK: - JSON Helpers

    private static func encodeJSON(_ array: [String]) -> String {
        (try? JSONEncoder().encode(array)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decodeJSON(_ string: String?) -> [String] {
        guard let string, let data = string.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - SQLite Helpers

private let methodSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension MethodDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, methodSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
