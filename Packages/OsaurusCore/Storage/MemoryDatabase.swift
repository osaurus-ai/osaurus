//
//  MemoryDatabase.swift
//  osaurus
//
//  SQLite database for the 4-layer memory system.
//  WAL mode, serial queue, versioned migrations — follows WorkDatabase patterns.
//

import CryptoKit
import Foundation
import SQLite3

public enum MemoryDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open memory database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Memory migration failed: \(msg)"
        case .notOpen: return "Memory database is not open"
        }
    }
}

public final class MemoryDatabase: @unchecked Sendable {
    public static let shared = MemoryDatabase()

    private static let schemaVersion = 3

    private static let memoryEntryColumns = """
        id, agent_id, type, content, confidence, model, source_conversation_id, tags, status,
        superseded_by, created_at, last_accessed, access_count, valid_from, valid_until
        """

    private static let insertMemoryEventSQL =
        "INSERT INTO memory_events (entry_id, event_type, agent_id, model, reason) VALUES (?1, ?2, ?3, ?4, ?5)"

    private static let touchMemoryEntrySQL =
        "UPDATE memory_entries SET last_accessed = datetime('now'), access_count = access_count + 1 WHERE id = ?1"

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.memory.database")

    private var cachedStatements: [String: OpaquePointer] = [:]

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.memory())
            try openConnection()
            try runMigrations()
        }
    }

    /// Open an in-memory database for testing.
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            var dbPointer: OpaquePointer?
            let result = sqlite3_open(":memory:", &dbPointer)
            guard result == SQLITE_OK, let connection = dbPointer else {
                let message = String(cString: sqlite3_errmsg(dbPointer))
                sqlite3_close(dbPointer)
                throw MemoryDatabaseError.failedToOpen(message)
            }
            db = connection
            try executeRaw("PRAGMA foreign_keys = ON")
            try runMigrations()
        }
    }

    public func close() {
        queue.sync {
            for (_, stmt) in cachedStatements {
                sqlite3_finalize(stmt)
            }
            cachedStatements.removeAll()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    /// Get or create a cached prepared statement for the given SQL (must be called within queue).
    private func cachedStatement(for sql: String) throws -> OpaquePointer {
        if let stmt = cachedStatements[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        cachedStatements[sql] = statement
        return statement
    }

    /// Execute a cached prepared statement with bind/process closures (must be called within queue).
    func prepareAndExecuteCached(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            let stmt = try cachedStatement(for: sql)
            bind(stmt)
            try process(stmt)
        }
    }

    private func openConnection() throws {
        let path = OsaurusPaths.memoryDatabaseFile().path
        var dbPointer: OpaquePointer?
        let result = sqlite3_open(path, &dbPointer)
        guard result == SQLITE_OK, let connection = dbPointer else {
            let message = String(cString: sqlite3_errmsg(dbPointer))
            sqlite3_close(dbPointer)
            throw MemoryDatabaseError.failedToOpen(message)
        }
        db = connection
        try executeRaw("PRAGMA journal_mode = WAL")
        try executeRaw("PRAGMA foreign_keys = ON")
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        if currentVersion < 1 { try migrateToV1() }
        if currentVersion < 2 { try migrateToV2() }
        if currentVersion < 3 { try migrateToV3() }
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
        // Schema management
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS schema_version (
                    version      INTEGER PRIMARY KEY,
                    applied_at   TEXT NOT NULL DEFAULT (datetime('now')),
                    description  TEXT
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS config (
                    key          TEXT PRIMARY KEY,
                    value        TEXT NOT NULL,
                    updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        // Layer 1: User Profile
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS user_profile (
                    id               INTEGER PRIMARY KEY CHECK (id = 1),
                    content          TEXT NOT NULL,
                    token_count      INTEGER NOT NULL,
                    version          INTEGER NOT NULL DEFAULT 1,
                    model            TEXT NOT NULL,
                    generated_at     TEXT NOT NULL
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS profile_events (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id         TEXT NOT NULL,
                    conversation_id  TEXT,
                    event_type       TEXT NOT NULL,
                    content          TEXT NOT NULL,
                    model            TEXT,
                    status           TEXT NOT NULL DEFAULT 'active',
                    incorporated_in  INTEGER,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS user_edits (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    content          TEXT NOT NULL,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
                    deleted_at       TEXT
                )
            """
        )

        // Layer 2: Working Memory
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS memory_entries (
                    id               TEXT PRIMARY KEY,
                    agent_id         TEXT NOT NULL,
                    type             TEXT NOT NULL,
                    content          TEXT NOT NULL,
                    confidence       REAL NOT NULL DEFAULT 0.8,
                    model            TEXT NOT NULL,
                    source_conversation_id TEXT,
                    tags             TEXT,
                    status           TEXT NOT NULL DEFAULT 'active',
                    superseded_by    TEXT REFERENCES memory_entries(id),
                    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
                    last_accessed    TEXT NOT NULL DEFAULT (datetime('now')),
                    access_count     INTEGER NOT NULL DEFAULT 0,
                    valid_from       TEXT NOT NULL DEFAULT (datetime('now')),
                    valid_until      TEXT
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_entries_agent ON memory_entries(agent_id, status)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_entries_created ON memory_entries(created_at)")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_entries_temporal ON memory_entries(agent_id, valid_from, valid_until)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS memory_events (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    entry_id         TEXT NOT NULL REFERENCES memory_entries(id),
                    event_type       TEXT NOT NULL,
                    agent_id         TEXT,
                    model            TEXT,
                    reason           TEXT,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        // Layer 3: Conversation Summaries
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS conversation_summaries (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id         TEXT NOT NULL,
                    conversation_id  TEXT NOT NULL,
                    summary          TEXT NOT NULL,
                    token_count      INTEGER NOT NULL,
                    model            TEXT NOT NULL,
                    conversation_at  TEXT NOT NULL,
                    status           TEXT NOT NULL DEFAULT 'active',
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_summaries_agent ON conversation_summaries(agent_id, conversation_at)"
        )

        // Layer 4: Conversations (for recall)
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS conversations (
                    id               TEXT PRIMARY KEY,
                    agent_id         TEXT NOT NULL,
                    title            TEXT,
                    started_at       TEXT NOT NULL,
                    last_message_at  TEXT NOT NULL,
                    message_count    INTEGER NOT NULL DEFAULT 0,
                    status           TEXT NOT NULL DEFAULT 'active'
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS conversation_chunks (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id  TEXT NOT NULL REFERENCES conversations(id),
                    chunk_index      INTEGER NOT NULL,
                    role             TEXT NOT NULL,
                    content          TEXT NOT NULL,
                    token_count      INTEGER NOT NULL,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_chunks_conversation ON conversation_chunks(conversation_id, chunk_index)"
        )

        // Embeddings
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS embeddings (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_type      TEXT NOT NULL,
                    source_id        TEXT NOT NULL,
                    embedding        BLOB NOT NULL,
                    model            TEXT NOT NULL,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw("CREATE UNIQUE INDEX IF NOT EXISTS idx_embeddings_source ON embeddings(source_type, source_id)")

        // Background Processing
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_activity (
                    agent_id         TEXT PRIMARY KEY,
                    last_activity_at TEXT NOT NULL,
                    pending_signals  INTEGER NOT NULL DEFAULT 0,
                    processing_status TEXT NOT NULL DEFAULT 'idle',
                    last_processed_at TEXT
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS pending_signals (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id         TEXT NOT NULL,
                    conversation_id  TEXT NOT NULL,
                    signal_type      TEXT NOT NULL,
                    user_message     TEXT NOT NULL,
                    assistant_message TEXT,
                    status           TEXT NOT NULL DEFAULT 'pending',
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS processing_log (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id         TEXT NOT NULL,
                    task_type        TEXT NOT NULL,
                    model            TEXT,
                    status           TEXT NOT NULL,
                    details          TEXT,
                    input_tokens     INTEGER,
                    output_tokens    INTEGER,
                    duration_ms      INTEGER,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        // Knowledge Graph
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS entities (
                    id               TEXT PRIMARY KEY,
                    name             TEXT NOT NULL,
                    type             TEXT NOT NULL,
                    metadata         TEXT,
                    model            TEXT NOT NULL,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(type)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_entities_name ON entities(name COLLATE NOCASE)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS relationships (
                    id               TEXT PRIMARY KEY,
                    source_id        TEXT NOT NULL REFERENCES entities(id),
                    target_id        TEXT NOT NULL REFERENCES entities(id),
                    relation         TEXT NOT NULL,
                    confidence       REAL NOT NULL DEFAULT 0.8,
                    model            TEXT NOT NULL,
                    valid_from       TEXT NOT NULL DEFAULT (datetime('now')),
                    valid_until      TEXT,
                    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_rel_source ON relationships(source_id, valid_until)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_rel_target ON relationships(target_id, valid_until)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_rel_relation ON relationships(relation)")

        try executeRaw("CREATE INDEX IF NOT EXISTS idx_memory_events_created ON memory_events(created_at)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_processing_log_created ON processing_log(created_at)")

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_signals_agent_status ON pending_signals(agent_id, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_profile_events_type_status ON profile_events(event_type, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_profile_events_incorporated ON profile_events(event_type, status, incorporated_in)"
        )

        try executeRaw(
            "INSERT OR IGNORE INTO schema_version (version, description) VALUES (1, 'Initial memory schema with knowledge graph')"
        )
        try setSchemaVersion(1)
    }

    /// V2 migration: adds indexes that were missing in v1 (safe to re-run with IF NOT EXISTS).
    /// Future schema changes (new columns, tables) should follow this pattern.
    private func migrateToV2() throws {
        MemoryLogger.database.info("Running migration to v2")

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_signals_agent_status ON pending_signals(agent_id, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_profile_events_type_status ON profile_events(event_type, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_profile_events_incorporated ON profile_events(event_type, status, incorporated_in)"
        )

        try executeRaw(
            "INSERT OR IGNORE INTO schema_version (version, description) VALUES (2, 'Add missing indexes for pending_signals and profile_events')"
        )
        try setSchemaVersion(2)
        MemoryLogger.database.info("Migration to v2 completed")
    }

    /// V3 migration: add index on conversation_chunks(created_at) for time-range queries.
    private func migrateToV3() throws {
        MemoryLogger.database.info("Running migration to v3")

        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_chunks_created_at ON conversation_chunks(created_at)"
        )

        try executeRaw(
            "INSERT OR IGNORE INTO schema_version (version, description) VALUES (3, 'Add created_at index for conversation_chunks')"
        )
        try setSchemaVersion(3)
        MemoryLogger.database.info("Migration to v3 completed")
    }

    // MARK: - Query Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else {
            throw MemoryDatabaseError.notOpen
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw MemoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else {
            throw MemoryDatabaseError.notOpen
        }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw MemoryDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    func execute<T>(_ operation: @escaping (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else {
                throw MemoryDatabaseError.notOpen
            }
            return try operation(connection)
        }
    }

    func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else {
                throw MemoryDatabaseError.notOpen
            }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                let message = String(cString: sqlite3_errmsg(connection))
                throw MemoryDatabaseError.failedToPrepare(message)
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        var success = false
        try prepareAndExecute(sql, bind: bind) { stmt in
            success = sqlite3_step(stmt) == SQLITE_DONE
        }
        return success
    }

    func inTransaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
            try executeRaw("BEGIN TRANSACTION")
            do {
                let result = try operation(connection)
                try executeRaw("COMMIT")
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    /// Prepare, bind, step, and finalize a statement within an already-open transaction.
    /// Must only be called inside `inTransaction` (i.e. on the serial queue with `db` valid).
    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw MemoryDatabaseError.failedToExecute("step failed")
        }
    }

    // MARK: - User Profile

    public func loadUserProfile() throws -> UserProfile? {
        var profile: UserProfile?
        try prepareAndExecute(
            "SELECT content, token_count, version, model, generated_at FROM user_profile WHERE id = 1",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    profile = UserProfile(
                        content: String(cString: sqlite3_column_text(stmt, 0)),
                        tokenCount: Int(sqlite3_column_int(stmt, 1)),
                        version: Int(sqlite3_column_int(stmt, 2)),
                        model: String(cString: sqlite3_column_text(stmt, 3)),
                        generatedAt: String(cString: sqlite3_column_text(stmt, 4))
                    )
                }
            }
        )
        return profile
    }

    public func saveUserProfile(_ profile: UserProfile) throws {
        _ = try executeUpdate(
            """
            INSERT INTO user_profile (id, content, token_count, version, model, generated_at)
            VALUES (1, ?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO UPDATE SET
                content = excluded.content,
                token_count = excluded.token_count,
                version = excluded.version,
                model = excluded.model,
                generated_at = excluded.generated_at
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: profile.content)
            sqlite3_bind_int(stmt, 2, Int32(profile.tokenCount))
            sqlite3_bind_int(stmt, 3, Int32(profile.version))
            Self.bindText(stmt, index: 4, value: profile.model)
            Self.bindText(stmt, index: 5, value: profile.generatedAt)
        }
    }

    // MARK: - User Edits

    public func loadUserEdits() throws -> [UserEdit] {
        var edits: [UserEdit] = []
        try prepareAndExecute(
            "SELECT id, content, created_at, deleted_at FROM user_edits WHERE deleted_at IS NULL ORDER BY created_at",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    edits.append(
                        UserEdit(
                            id: Int(sqlite3_column_int(stmt, 0)),
                            content: String(cString: sqlite3_column_text(stmt, 1)),
                            createdAt: String(cString: sqlite3_column_text(stmt, 2)),
                            deletedAt: sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                        )
                    )
                }
            }
        )
        return edits
    }

    public func insertUserEdit(_ content: String) throws {
        _ = try executeUpdate("INSERT INTO user_edits (content) VALUES (?1)") { stmt in
            Self.bindText(stmt, index: 1, value: content)
        }
    }

    public func deleteUserEdit(id: Int) throws {
        _ = try executeUpdate("UPDATE user_edits SET deleted_at = datetime('now') WHERE id = ?1") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    // MARK: - Profile Events

    public func insertProfileEvent(_ event: ProfileEvent) throws {
        _ = try executeUpdate(
            """
            INSERT INTO profile_events (agent_id, conversation_id, event_type, content, model, status)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: event.agentId)
            Self.bindText(stmt, index: 2, value: event.conversationId)
            Self.bindText(stmt, index: 3, value: event.eventType)
            Self.bindText(stmt, index: 4, value: event.content)
            Self.bindText(stmt, index: 5, value: event.model)
            Self.bindText(stmt, index: 6, value: event.status)
        }
    }

    public func loadRecentProfileEvents(limit: Int = 20) throws -> [ProfileEvent] {
        var events: [ProfileEvent] = []
        try prepareAndExecute(
            "SELECT id, agent_id, conversation_id, event_type, content, model, status, incorporated_in, created_at FROM profile_events ORDER BY created_at DESC LIMIT ?1",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(limit)) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    events.append(Self.readProfileEvent(stmt))
                }
            }
        )
        return events
    }

    public func loadActiveContributions() throws -> [ProfileEvent] {
        var events: [ProfileEvent] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, conversation_id, event_type, content, model, status, incorporated_in, created_at
            FROM profile_events
            WHERE event_type = 'contribution' AND status = 'active'
            ORDER BY created_at ASC
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    events.append(Self.readProfileEvent(stmt))
                }
            }
        )
        return events
    }

    private static func readProfileEvent(_ stmt: OpaquePointer) -> ProfileEvent {
        ProfileEvent(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            eventType: String(cString: sqlite3_column_text(stmt, 3)),
            content: String(cString: sqlite3_column_text(stmt, 4)),
            model: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            status: String(cString: sqlite3_column_text(stmt, 6)),
            incorporatedIn: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil,
            createdAt: String(cString: sqlite3_column_text(stmt, 8))
        )
    }

    public func markContributionsIncorporated(version: Int) throws {
        _ = try executeUpdate(
            """
            UPDATE profile_events SET incorporated_in = ?1
            WHERE event_type = 'contribution' AND status = 'active' AND incorporated_in IS NULL
            """
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(version))
        }
    }

    public func activeProfileContributionCount() throws -> Int {
        var count = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM profile_events WHERE event_type = 'contribution' AND status = 'active'",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    /// Count contributions created after the most recent profile regeneration.
    public func contributionCountSinceLastRegeneration() throws -> Int {
        var count = 0
        try prepareAndExecute(
            """
            SELECT COUNT(*) FROM profile_events
            WHERE event_type = 'contribution' AND status = 'active'
              AND created_at > COALESCE(
                (SELECT MAX(created_at) FROM profile_events WHERE event_type = 'regeneration'),
                '1970-01-01'
              )
            """,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    // MARK: - Memory Entries

    private static let insertEntrySQL = """
        INSERT INTO memory_entries (id, agent_id, type, content, confidence, model,
            source_conversation_id, tags, status, valid_from)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """

    private static let supersedeEntrySQL =
        "UPDATE memory_entries SET status = 'superseded', superseded_by = ?1, valid_until = ?3 WHERE id = ?2"

    public func insertMemoryEntry(_ entry: MemoryEntry) throws {
        let validFrom = entry.validFrom.isEmpty ? Self.iso8601Now() : entry.validFrom
        try inTransaction { _ in
            try self.bindInsertEntry(entry, validFrom: validFrom)
            try self.bindInsertEvent(
                entryId: entry.id,
                eventType: "created",
                agentId: entry.agentId,
                model: entry.model,
                reason: nil
            )
        }
    }

    private func bindInsertEntry(_ entry: MemoryEntry, validFrom: String) throws {
        try transactionalStep(Self.insertEntrySQL) { stmt in
            Self.bindText(stmt, index: 1, value: entry.id)
            Self.bindText(stmt, index: 2, value: entry.agentId)
            Self.bindText(stmt, index: 3, value: entry.type.rawValue)
            Self.bindText(stmt, index: 4, value: entry.content)
            sqlite3_bind_double(stmt, 5, entry.confidence)
            Self.bindText(stmt, index: 6, value: entry.model)
            Self.bindText(stmt, index: 7, value: entry.sourceConversationId)
            Self.bindText(stmt, index: 8, value: entry.tagsJSON)
            Self.bindText(stmt, index: 9, value: entry.status)
            Self.bindText(stmt, index: 10, value: validFrom)
        }
    }

    private func bindInsertEvent(entryId: String, eventType: String, agentId: String?, model: String?, reason: String?)
        throws
    {
        try transactionalStep(Self.insertMemoryEventSQL) { stmt in
            Self.bindText(stmt, index: 1, value: entryId)
            Self.bindText(stmt, index: 2, value: eventType)
            Self.bindText(stmt, index: 3, value: agentId)
            Self.bindText(stmt, index: 4, value: model)
            Self.bindText(stmt, index: 5, value: reason)
        }
    }

    public func loadActiveEntries(agentId: String, limit: Int = 0) throws -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        var sql = """
            SELECT \(Self.memoryEntryColumns)
            FROM memory_entries WHERE agent_id = ?1 AND status = 'active'
            ORDER BY last_accessed DESC
            """
        if limit > 0 { sql += " LIMIT ?2" }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId)
                if limit > 0 { sqlite3_bind_int(stmt, 2, Int32(limit)) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    public func loadAllActiveEntries(limit: Int = 5000) throws -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        try prepareAndExecute(
            """
            SELECT \(Self.memoryEntryColumns)
            FROM memory_entries WHERE status = 'active'
            ORDER BY last_accessed DESC
            LIMIT ?1
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(min(limit, 10_000))) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    public func loadEntriesByIds(_ ids: [String], agentId: String? = nil) throws -> [MemoryEntry] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        var sql = """
            SELECT \(Self.memoryEntryColumns)
            FROM memory_entries WHERE status = 'active' AND id IN (\(placeholders))
            """
        if agentId != nil { sql += " AND agent_id = ?\(ids.count + 1)" }
        sql += " ORDER BY last_accessed DESC"

        var entries: [MemoryEntry] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    Self.bindText(stmt, index: Int32(i + 1), value: id)
                }
                if let agentId { Self.bindText(stmt, index: Int32(ids.count + 1), value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    public func supersede(entryId: String, by newId: String, reason: String?) throws {
        let now = Self.iso8601Now()
        _ = try executeUpdate(Self.supersedeEntrySQL) { stmt in
            Self.bindText(stmt, index: 1, value: newId)
            Self.bindText(stmt, index: 2, value: entryId)
            Self.bindText(stmt, index: 3, value: now)
        }
        try insertMemoryEvent(entryId: entryId, eventType: "superseded", agentId: nil, model: nil, reason: reason)
    }

    /// Atomically supersede an old entry and insert its replacement in a single transaction.
    public func supersedeAndInsert(
        oldEntryId: String,
        newEntry: MemoryEntry,
        reason: String?
    ) throws {
        try inTransaction { _ in
            let now = Self.iso8601Now()
            let validFrom = newEntry.validFrom.isEmpty ? now : newEntry.validFrom

            try self.transactionalStep(Self.supersedeEntrySQL) { stmt in
                Self.bindText(stmt, index: 1, value: newEntry.id)
                Self.bindText(stmt, index: 2, value: oldEntryId)
                Self.bindText(stmt, index: 3, value: now)
            }
            try self.bindInsertEntry(newEntry, validFrom: validFrom)
            try self.bindInsertEvent(
                entryId: oldEntryId,
                eventType: "superseded",
                agentId: nil,
                model: nil,
                reason: reason
            )
            try self.bindInsertEvent(
                entryId: newEntry.id,
                eventType: "created",
                agentId: newEntry.agentId,
                model: newEntry.model,
                reason: nil
            )
        }
    }

    public func deleteMemoryEntry(id: String) throws {
        _ = try executeUpdate("UPDATE memory_entries SET status = 'deleted' WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
        try insertMemoryEvent(entryId: id, eventType: "deleted", agentId: nil, model: nil, reason: nil)
    }

    public func touchMemoryEntry(id: String) throws {
        try prepareAndExecuteCached(
            Self.touchMemoryEntrySQL,
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    public func touchMemoryEntries(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        _ = try executeUpdate(
            "UPDATE memory_entries SET last_accessed = datetime('now'), access_count = access_count + 1 WHERE id IN (\(placeholders))"
        ) { stmt in
            for (i, id) in ids.enumerated() {
                Self.bindText(stmt, index: Int32(i + 1), value: id)
            }
        }
    }

    public func activeEntryCount(agentId: String? = nil) throws -> Int {
        var count = 0
        let sql: String
        if agentId != nil {
            sql = "SELECT COUNT(*) FROM memory_entries WHERE status = 'active' AND agent_id = ?1"
        } else {
            sql = "SELECT COUNT(*) FROM memory_entries WHERE status = 'active'"
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    /// Archive oldest entries for an agent when count exceeds the cap.
    /// Returns the number of entries archived.
    @discardableResult
    public func archiveExcessEntries(agentId: String, maxEntries: Int) throws -> Int {
        guard maxEntries > 0 else { return 0 }
        let count = try activeEntryCount(agentId: agentId)
        guard count > maxEntries else { return 0 }

        let excess = count - maxEntries
        _ = try executeUpdate(
            """
            UPDATE memory_entries SET status = 'archived', valid_until = datetime('now')
            WHERE id IN (
                SELECT id FROM memory_entries
                WHERE agent_id = ?1 AND status = 'active'
                ORDER BY last_accessed ASC, access_count ASC
                LIMIT ?2
            )
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
            sqlite3_bind_int(stmt, 2, Int32(excess))
        }
        return excess
    }

    public func agentIdsWithEntries() throws -> [(agentId: String, count: Int)] {
        var results: [(String, Int)] = []
        try prepareAndExecute(
            "SELECT agent_id, COUNT(*) as cnt FROM memory_entries WHERE status = 'active' GROUP BY agent_id ORDER BY cnt DESC",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(
                        (
                            String(cString: sqlite3_column_text(stmt, 0)),
                            Int(sqlite3_column_int(stmt, 1))
                        )
                    )
                }
            }
        )
        return results
    }

    func insertMemoryEvent(
        entryId: String,
        eventType: String,
        agentId: String?,
        model: String?,
        reason: String?
    ) throws {
        try prepareAndExecuteCached(
            Self.insertMemoryEventSQL,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: entryId)
                Self.bindText(stmt, index: 2, value: eventType)
                Self.bindText(stmt, index: 3, value: agentId)
                Self.bindText(stmt, index: 4, value: model)
                Self.bindText(stmt, index: 5, value: reason)
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    private static func readMemoryEntry(_ stmt: OpaquePointer) -> MemoryEntry {
        MemoryEntry(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            type: MemoryEntryType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .fact,
            content: String(cString: sqlite3_column_text(stmt, 3)),
            confidence: sqlite3_column_double(stmt, 4),
            model: String(cString: sqlite3_column_text(stmt, 5)),
            sourceConversationId: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
            tagsJSON: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
            status: String(cString: sqlite3_column_text(stmt, 8)),
            supersededBy: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
            createdAt: String(cString: sqlite3_column_text(stmt, 10)),
            lastAccessed: String(cString: sqlite3_column_text(stmt, 11)),
            accessCount: Int(sqlite3_column_int(stmt, 12)),
            validFrom: String(cString: sqlite3_column_text(stmt, 13)),
            validUntil: sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        )
    }

    // MARK: - Conversation Summaries

    public func insertSummary(_ summary: ConversationSummary) throws {
        _ = try executeUpdate(
            """
            INSERT INTO conversation_summaries (agent_id, conversation_id, summary, token_count, model, conversation_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: summary.agentId)
            Self.bindText(stmt, index: 2, value: summary.conversationId)
            Self.bindText(stmt, index: 3, value: summary.summary)
            sqlite3_bind_int(stmt, 4, Int32(summary.tokenCount))
            Self.bindText(stmt, index: 5, value: summary.model)
            Self.bindText(stmt, index: 6, value: summary.conversationAt)
        }
    }

    /// Atomically insert a summary and mark its pending signals as processed.
    public func insertSummaryAndMarkProcessed(_ summary: ConversationSummary) throws {
        try inTransaction { _ in
            try self.transactionalStep(
                """
                INSERT INTO conversation_summaries (agent_id, conversation_id, summary, token_count, model, conversation_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: summary.agentId)
                Self.bindText(stmt, index: 2, value: summary.conversationId)
                Self.bindText(stmt, index: 3, value: summary.summary)
                sqlite3_bind_int(stmt, 4, Int32(summary.tokenCount))
                Self.bindText(stmt, index: 5, value: summary.model)
                Self.bindText(stmt, index: 6, value: summary.conversationAt)
            }
            try self.transactionalStep(
                "UPDATE pending_signals SET status = 'processed' WHERE conversation_id = ?1 AND status = 'pending'"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: summary.conversationId)
            }
        }
    }

    public func loadSummaries(agentId: String, days: Int = 0) throws -> [ConversationSummary] {
        var summaries: [ConversationSummary] = []
        let sql: String
        if days > 0 {
            sql = """
                SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
                FROM conversation_summaries
                WHERE agent_id = ?1 AND status = 'active'
                  AND conversation_at >= datetime('now', '-' || ?2 || ' days')
                ORDER BY conversation_at DESC
                """
        } else {
            sql = """
                SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
                FROM conversation_summaries
                WHERE agent_id = ?1 AND status = 'active'
                ORDER BY conversation_at DESC
                """
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId)
                if days > 0 { sqlite3_bind_int(stmt, 2, Int32(days)) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    summaries.append(Self.readSummary(stmt))
                }
            }
        )
        return summaries
    }

    public func loadAllSummaries(days: Int? = nil) throws -> [ConversationSummary] {
        var summaries: [ConversationSummary] = []
        let sql: String
        if days != nil {
            sql = """
                    SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
                    FROM conversation_summaries WHERE status = 'active'
                    AND conversation_at >= datetime('now', '-' || ?1 || ' days')
                    ORDER BY conversation_at DESC
                """
        } else {
            sql = """
                    SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
                    FROM conversation_summaries WHERE status = 'active'
                    ORDER BY conversation_at DESC
                """
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let days { sqlite3_bind_int(stmt, 1, Int32(days)) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    summaries.append(Self.readSummary(stmt))
                }
            }
        )
        return summaries
    }

    public func loadSummariesByIds(_ ids: [Int], agentId: String? = nil) throws -> [ConversationSummary] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        var sql = """
            SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
            FROM conversation_summaries WHERE status = 'active' AND id IN (\(placeholders))
            """
        if agentId != nil { sql += " AND agent_id = ?\(ids.count + 1)" }
        sql += " ORDER BY conversation_at DESC"

        var summaries: [ConversationSummary] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
                }
                if let agentId { Self.bindText(stmt, index: Int32(ids.count + 1), value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    summaries.append(Self.readSummary(stmt))
                }
            }
        )
        return summaries
    }

    public func summaryStats() throws -> (today: Int, thisWeek: Int, total: Int) {
        var today = 0, week = 0, total = 0
        try prepareAndExecute(
            """
            SELECT
                (SELECT COUNT(*) FROM conversation_summaries WHERE status = 'active' AND conversation_at >= datetime('now', 'start of day')),
                (SELECT COUNT(*) FROM conversation_summaries WHERE status = 'active' AND conversation_at >= datetime('now', '-7 days')),
                (SELECT COUNT(*) FROM conversation_summaries WHERE status = 'active')
            """,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    today = Int(sqlite3_column_int(stmt, 0))
                    week = Int(sqlite3_column_int(stmt, 1))
                    total = Int(sqlite3_column_int(stmt, 2))
                }
            }
        )
        return (today, week, total)
    }

    private static func readSummary(_ stmt: OpaquePointer) -> ConversationSummary {
        ConversationSummary(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            summary: String(cString: sqlite3_column_text(stmt, 3)),
            tokenCount: Int(sqlite3_column_int(stmt, 4)),
            model: String(cString: sqlite3_column_text(stmt, 5)),
            conversationAt: String(cString: sqlite3_column_text(stmt, 6)),
            status: String(cString: sqlite3_column_text(stmt, 7)),
            createdAt: String(cString: sqlite3_column_text(stmt, 8))
        )
    }

    // MARK: - Conversations & Chunks

    public func upsertConversation(id: String, agentId: String, title: String?) throws {
        _ = try executeUpdate(
            """
            INSERT INTO conversations (id, agent_id, title, started_at, last_message_at, message_count)
            VALUES (?1, ?2, ?3, datetime('now'), datetime('now'), 0)
            ON CONFLICT(id) DO UPDATE SET
                last_message_at = datetime('now'),
                message_count = conversations.message_count + 1,
                title = COALESCE(?3, conversations.title)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id)
            Self.bindText(stmt, index: 2, value: agentId)
            Self.bindText(stmt, index: 3, value: title)
        }
    }

    public func insertChunk(
        conversationId: String,
        chunkIndex: Int,
        role: String,
        content: String,
        tokenCount: Int,
        createdAt: String? = nil
    ) throws {
        let effectiveDate = (createdAt?.isEmpty == false) ? createdAt : nil
        _ = try executeUpdate(
            """
            INSERT INTO conversation_chunks (conversation_id, chunk_index, role, content, token_count, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6, datetime('now')))
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
            sqlite3_bind_int(stmt, 2, Int32(chunkIndex))
            Self.bindText(stmt, index: 3, value: role)
            Self.bindText(stmt, index: 4, value: content)
            sqlite3_bind_int(stmt, 5, Int32(tokenCount))
            Self.bindText(stmt, index: 6, value: effectiveDate)
        }
    }

    public func deleteChunksForConversation(_ conversationId: String) throws {
        _ = try executeUpdate(
            "DELETE FROM conversation_chunks WHERE conversation_id = ?1"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    public func deleteChunksForAgent(_ agentId: String) throws {
        _ = try executeUpdate(
            """
            DELETE FROM conversation_chunks WHERE conversation_id IN (
                SELECT id FROM conversations WHERE agent_id = ?1
            )
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
        }
    }

    public func loadAllChunks(agentId: String? = nil, days: Int = 30, limit: Int = 5000) throws -> [ConversationChunk] {
        var chunks: [ConversationChunk] = []
        var sql = """
                SELECT cc.id, cc.conversation_id, cc.chunk_index, cc.role, cc.content, cc.token_count, cc.created_at,
                       c.agent_id, c.title
                FROM conversation_chunks cc
                JOIN conversations c ON c.id = cc.conversation_id
                WHERE cc.created_at >= datetime('now', '-' || ?1 || ' days')
            """
        if agentId != nil { sql += " AND c.agent_id = ?2" }
        sql += " ORDER BY cc.created_at DESC"
        let limitParam = agentId != nil ? 3 : 2
        sql += " LIMIT ?\(limitParam)"

        try prepareAndExecute(
            sql,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(days))
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                sqlite3_bind_int(stmt, Int32(limitParam), Int32(min(limit, 10_000)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    chunks.append(Self.readChunk(stmt))
                }
            }
        )
        return chunks
    }

    public func loadChunksByKeys(_ keys: [(conversationId: String, chunkIndex: Int)]) throws -> [ConversationChunk] {
        guard !keys.isEmpty else { return [] }
        let conditions = keys.enumerated().map { (i, _) in
            "(cc.conversation_id = ?\(i * 2 + 1) AND cc.chunk_index = ?\(i * 2 + 2))"
        }.joined(separator: " OR ")
        let sql = """
            SELECT cc.id, cc.conversation_id, cc.chunk_index, cc.role, cc.content, cc.token_count, cc.created_at,
                   c.agent_id, c.title
            FROM conversation_chunks cc
            JOIN conversations c ON c.id = cc.conversation_id
            WHERE \(conditions)
            ORDER BY cc.created_at DESC
            """
        var chunks: [ConversationChunk] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, key) in keys.enumerated() {
                    Self.bindText(stmt, index: Int32(i * 2 + 1), value: key.conversationId)
                    sqlite3_bind_int(stmt, Int32(i * 2 + 2), Int32(key.chunkIndex))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    chunks.append(Self.readChunk(stmt))
                }
            }
        )
        return chunks
    }

    public func searchChunks(query: String, agentId: String? = nil, days: Int = 30) throws -> [ConversationChunk] {
        var chunks: [ConversationChunk] = []
        var sql = """
                SELECT cc.id, cc.conversation_id, cc.chunk_index, cc.role, cc.content, cc.token_count, cc.created_at,
                       c.agent_id, c.title
                FROM conversation_chunks cc
                JOIN conversations c ON c.id = cc.conversation_id
                WHERE cc.content LIKE '%' || ?1 || '%'
                  AND cc.created_at >= datetime('now', '-' || ?2 || ' days')
            """
        if agentId != nil { sql += " AND c.agent_id = ?3" }
        sql += " ORDER BY cc.created_at DESC LIMIT 20"

        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                sqlite3_bind_int(stmt, 2, Int32(days))
                if let agentId { Self.bindText(stmt, index: 3, value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    chunks.append(Self.readChunk(stmt))
                }
            }
        )
        return chunks
    }

    private static func readChunk(_ stmt: OpaquePointer) -> ConversationChunk {
        ConversationChunk(
            id: Int(sqlite3_column_int(stmt, 0)),
            conversationId: String(cString: sqlite3_column_text(stmt, 1)),
            chunkIndex: Int(sqlite3_column_int(stmt, 2)),
            role: String(cString: sqlite3_column_text(stmt, 3)),
            content: String(cString: sqlite3_column_text(stmt, 4)),
            tokenCount: Int(sqlite3_column_int(stmt, 5)),
            createdAt: String(cString: sqlite3_column_text(stmt, 6)),
            agentId: String(cString: sqlite3_column_text(stmt, 7)),
            conversationTitle: sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        )
    }

    // MARK: - Pending Signals

    public func insertPendingSignal(_ signal: PendingSignal) throws {
        _ = try executeUpdate(
            """
            INSERT INTO pending_signals (agent_id, conversation_id, signal_type, user_message, assistant_message, status)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: signal.agentId)
            Self.bindText(stmt, index: 2, value: signal.conversationId)
            Self.bindText(stmt, index: 3, value: signal.signalType)
            Self.bindText(stmt, index: 4, value: signal.userMessage)
            Self.bindText(stmt, index: 5, value: signal.assistantMessage)
            Self.bindText(stmt, index: 6, value: signal.status)
        }
    }

    public func loadPendingSignals(agentId: String) throws -> [PendingSignal] {
        var signals: [PendingSignal] = []
        try prepareAndExecute(
            "SELECT id, agent_id, conversation_id, signal_type, user_message, assistant_message, status, created_at FROM pending_signals WHERE agent_id = ?1 AND status = 'pending' ORDER BY created_at",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    signals.append(
                        PendingSignal(
                            id: Int(sqlite3_column_int(stmt, 0)),
                            agentId: String(cString: sqlite3_column_text(stmt, 1)),
                            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
                            signalType: String(cString: sqlite3_column_text(stmt, 3)),
                            userMessage: String(cString: sqlite3_column_text(stmt, 4)),
                            assistantMessage: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                            status: String(cString: sqlite3_column_text(stmt, 6)),
                            createdAt: String(cString: sqlite3_column_text(stmt, 7))
                        )
                    )
                }
            }
        )
        return signals
    }

    public func loadPendingSignals(conversationId: String) throws -> [PendingSignal] {
        var signals: [PendingSignal] = []
        try prepareAndExecute(
            "SELECT id, agent_id, conversation_id, signal_type, user_message, assistant_message, status, created_at FROM pending_signals WHERE conversation_id = ?1 AND status = 'pending' ORDER BY created_at",
            bind: { stmt in Self.bindText(stmt, index: 1, value: conversationId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    signals.append(
                        PendingSignal(
                            id: Int(sqlite3_column_int(stmt, 0)),
                            agentId: String(cString: sqlite3_column_text(stmt, 1)),
                            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
                            signalType: String(cString: sqlite3_column_text(stmt, 3)),
                            userMessage: String(cString: sqlite3_column_text(stmt, 4)),
                            assistantMessage: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                            status: String(cString: sqlite3_column_text(stmt, 6)),
                            createdAt: String(cString: sqlite3_column_text(stmt, 7))
                        )
                    )
                }
            }
        )
        return signals
    }

    public func markSignalsProcessed(conversationId: String) throws {
        _ = try executeUpdate(
            "UPDATE pending_signals SET status = 'processed' WHERE conversation_id = ?1 AND status = 'pending'"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    // MARK: - Agent Activity

    public func updateAgentActivity(agentId: String) throws {
        _ = try executeUpdate(
            """
            INSERT INTO agent_activity (agent_id, last_activity_at, pending_signals, processing_status)
            VALUES (?1, datetime('now'), 0, 'idle')
            ON CONFLICT(agent_id) DO UPDATE SET last_activity_at = datetime('now')
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
        }
    }

    /// Distinct (agentId, conversationId) pairs that have at least one pending signal.
    public func pendingConversations() throws -> [(agentId: String, conversationId: String)] {
        var results: [(agentId: String, conversationId: String)] = []
        try prepareAndExecute(
            "SELECT DISTINCT agent_id, conversation_id FROM pending_signals WHERE status = 'pending'",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(
                        (
                            agentId: String(cString: sqlite3_column_text(stmt, 0)),
                            conversationId: String(cString: sqlite3_column_text(stmt, 1))
                        )
                    )
                }
            }
        )
        return results
    }

    // MARK: - Processing Log

    public func insertProcessingLog(
        agentId: String,
        taskType: String,
        model: String?,
        status: String,
        details: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        durationMs: Int? = nil
    ) throws {
        _ = try executeUpdate(
            """
            INSERT INTO processing_log (agent_id, task_type, model, status, details, input_tokens, output_tokens, duration_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
            Self.bindText(stmt, index: 2, value: taskType)
            Self.bindText(stmt, index: 3, value: model)
            Self.bindText(stmt, index: 4, value: status)
            Self.bindText(stmt, index: 5, value: details)
            if let t = inputTokens { sqlite3_bind_int(stmt, 6, Int32(t)) } else { sqlite3_bind_null(stmt, 6) }
            if let t = outputTokens { sqlite3_bind_int(stmt, 7, Int32(t)) } else { sqlite3_bind_null(stmt, 7) }
            if let t = durationMs { sqlite3_bind_int(stmt, 8, Int32(t)) } else { sqlite3_bind_null(stmt, 8) }
        }
    }

    public func processingStats() throws -> ProcessingStats {
        var stats = ProcessingStats()
        try prepareAndExecute(
            """
            SELECT COUNT(*), AVG(duration_ms),
                   SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END)
            FROM processing_log
            """,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    stats.totalCalls = Int(sqlite3_column_int(stmt, 0))
                    stats.avgDurationMs =
                        sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : 0
                    stats.successCount = Int(sqlite3_column_int(stmt, 2))
                    stats.errorCount = Int(sqlite3_column_int(stmt, 3))
                }
            }
        )
        return stats
    }

    // MARK: - Database Info

    public func databaseSizeBytes() -> Int64 {
        let path = OsaurusPaths.memoryDatabaseFile().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: - Database Maintenance

    /// Run PRAGMA optimize to let SQLite update internal statistics.
    /// Best called on close or periodically.
    public func optimize() {
        queue.sync {
            guard db != nil else { return }
            try? executeRaw("PRAGMA optimize")
        }
    }

    /// Run VACUUM to reclaim space and defragment the database.
    /// This is expensive and should only be run infrequently (e.g., weekly).
    public func vacuum() throws {
        try queue.sync {
            guard db != nil else { throw MemoryDatabaseError.notOpen }
            try executeRaw("VACUUM")
        }
    }

    // MARK: - Retention Cleanup

    /// Delete old rows from memory_events and processing_log to prevent unbounded growth.
    public func purgeOldEventData(retentionDays: Int = 30) throws {
        _ = try executeUpdate(
            "DELETE FROM memory_events WHERE created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(retentionDays))
        }
        _ = try executeUpdate(
            "DELETE FROM processing_log WHERE created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(retentionDays))
        }
        _ = try executeUpdate(
            "DELETE FROM pending_signals WHERE status = 'processed' AND created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(retentionDays))
        }
    }

    // MARK: - Text Search (BM25 fallback)

    public func searchMemoryEntries(query: String, agentId: String? = nil) throws -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        var sql = """
                SELECT \(Self.memoryEntryColumns)
                FROM memory_entries
                WHERE status = 'active' AND content LIKE '%' || ?1 || '%'
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY last_accessed DESC LIMIT 20"

        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    /// Returns entries that were active at a specific point in time.
    public func loadEntriesAsOf(agentId: String, asOf: String) throws -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        try prepareAndExecute(
            """
            SELECT \(Self.memoryEntryColumns)
            FROM memory_entries
            WHERE agent_id = ?1
              AND valid_from <= ?2
              AND (valid_until IS NULL OR valid_until > ?2)
            ORDER BY valid_from DESC
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId)
                Self.bindText(stmt, index: 2, value: asOf)
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    /// Returns the history of entries of a given type, optionally filtered by keyword.
    public func loadEntryHistory(agentId: String, type: String, containing: String? = nil) throws -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        var sql = """
                SELECT \(Self.memoryEntryColumns)
                FROM memory_entries
                WHERE agent_id = ?1 AND type = ?2
            """
        if containing != nil {
            sql += " AND content LIKE '%' || ?3 || '%'"
        }
        sql += " ORDER BY valid_from ASC"

        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId)
                Self.bindText(stmt, index: 2, value: type)
                if let keyword = containing {
                    Self.bindText(stmt, index: 3, value: keyword)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readMemoryEntry(stmt))
                }
            }
        )
        return entries
    }

    public func searchSummaries(query: String, agentId: String? = nil, days: Int = 30) throws -> [ConversationSummary] {
        var summaries: [ConversationSummary] = []
        var sql = """
                SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
                FROM conversation_summaries
                WHERE status = 'active' AND summary LIKE '%' || ?1 || '%'
                  AND conversation_at >= datetime('now', '-' || ?2 || ' days')
            """
        if agentId != nil { sql += " AND agent_id = ?3" }
        sql += " ORDER BY conversation_at DESC LIMIT 20"

        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                sqlite3_bind_int(stmt, 2, Int32(days))
                if let agentId { Self.bindText(stmt, index: 3, value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    summaries.append(Self.readSummary(stmt))
                }
            }
        )
        return summaries
    }

    // MARK: - Lightweight Key Queries (for search reverse-map building)

    public func loadAllChunkKeys(days: Int = 365) throws -> [(conversationId: String, chunkIndex: Int)] {
        var keys: [(conversationId: String, chunkIndex: Int)] = []
        try prepareAndExecute(
            """
            SELECT conversation_id, chunk_index
            FROM conversation_chunks
            WHERE created_at >= datetime('now', '-' || ?1 || ' days')
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            conversationId: String(cString: sqlite3_column_text(stmt, 0)),
                            chunkIndex: Int(sqlite3_column_int(stmt, 1))
                        )
                    )
                }
            }
        )
        return keys
    }

    public func loadAllSummaryKeys() throws -> [(agentId: String, conversationId: String, conversationAt: String)] {
        var keys: [(agentId: String, conversationId: String, conversationAt: String)] = []
        try prepareAndExecute(
            """
            SELECT agent_id, conversation_id, conversation_at
            FROM conversation_summaries WHERE status = 'active'
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            agentId: String(cString: sqlite3_column_text(stmt, 0)),
                            conversationId: String(cString: sqlite3_column_text(stmt, 1)),
                            conversationAt: String(cString: sqlite3_column_text(stmt, 2))
                        )
                    )
                }
            }
        )
        return keys
    }

    public func loadSummariesByCompositeKeys(
        _ keys: [(agentId: String, conversationId: String, conversationAt: String)],
        filterAgentId: String? = nil
    ) throws -> [ConversationSummary] {
        guard !keys.isEmpty else { return [] }
        let conditions = keys.enumerated().map { (i, _) in
            "(agent_id = ?\(i * 3 + 1) AND conversation_id = ?\(i * 3 + 2) AND conversation_at = ?\(i * 3 + 3))"
        }.joined(separator: " OR ")
        var sql = """
            SELECT id, agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
            FROM conversation_summaries WHERE status = 'active' AND (\(conditions))
            """
        if filterAgentId != nil { sql += " AND agent_id = ?\(keys.count * 3 + 1)" }
        sql += " ORDER BY conversation_at DESC"

        var summaries: [ConversationSummary] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, key) in keys.enumerated() {
                    Self.bindText(stmt, index: Int32(i * 3 + 1), value: key.agentId)
                    Self.bindText(stmt, index: Int32(i * 3 + 2), value: key.conversationId)
                    Self.bindText(stmt, index: Int32(i * 3 + 3), value: key.conversationAt)
                }
                if let agentId = filterAgentId {
                    Self.bindText(stmt, index: Int32(keys.count * 3 + 1), value: agentId)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    summaries.append(Self.readSummary(stmt))
                }
            }
        )
        return summaries
    }

    // MARK: - Knowledge Graph

    public func resolveEntity(name: String, type: String, model: String) throws -> GraphEntity {
        if let existing = try findEntity(name: name, type: type) {
            return existing
        }
        if type == "unknown", let existing = try findEntityByName(name: name) {
            return existing
        }
        let id = deterministicId(name.lowercased(), type)
        let entity = GraphEntity(id: id, name: name, type: type, model: model)
        try insertEntity(entity)
        return entity
    }

    private func findEntity(name: String, type: String) throws -> GraphEntity? {
        var entity: GraphEntity?
        try prepareAndExecute(
            "SELECT id, name, type, metadata, model, created_at, updated_at FROM entities WHERE name = ?1 COLLATE NOCASE AND type = ?2",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: name)
                Self.bindText(stmt, index: 2, value: type)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entity = Self.readGraphEntity(stmt)
                }
            }
        )
        return entity
    }

    private func findEntityByName(name: String) throws -> GraphEntity? {
        var entity: GraphEntity?
        try prepareAndExecute(
            "SELECT id, name, type, metadata, model, created_at, updated_at FROM entities WHERE name = ?1 COLLATE NOCASE LIMIT 1",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: name)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entity = Self.readGraphEntity(stmt)
                }
            }
        )
        return entity
    }

    private func insertEntity(_ entity: GraphEntity) throws {
        _ = try executeUpdate(
            """
            INSERT OR IGNORE INTO entities (id, name, type, metadata, model)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: entity.id)
            Self.bindText(stmt, index: 2, value: entity.name)
            Self.bindText(stmt, index: 3, value: entity.type)
            Self.bindText(stmt, index: 4, value: entity.metadata)
            Self.bindText(stmt, index: 5, value: entity.model)
        }
    }

    public func insertRelationship(
        sourceId: String,
        targetId: String,
        relation: String,
        confidence: Double,
        model: String
    ) throws {
        let existing = try findActiveRelationship(sourceId: sourceId, relation: relation)
        if let existing, existing.targetId != targetId {
            try invalidateRelationship(id: existing.id)
        }

        let id = deterministicId(sourceId, relation, targetId)
        _ = try executeUpdate(
            """
            INSERT OR IGNORE INTO relationships (id, source_id, target_id, relation, confidence, model)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id)
            Self.bindText(stmt, index: 2, value: sourceId)
            Self.bindText(stmt, index: 3, value: targetId)
            Self.bindText(stmt, index: 4, value: relation)
            sqlite3_bind_double(stmt, 5, confidence)
            Self.bindText(stmt, index: 6, value: model)
        }
    }

    private func findActiveRelationship(sourceId: String, relation: String) throws -> GraphRelationship? {
        var rel: GraphRelationship?
        try prepareAndExecute(
            """
            SELECT id, source_id, target_id, relation, confidence, model, valid_from, valid_until, created_at
            FROM relationships
            WHERE source_id = ?1 AND relation = ?2 AND valid_until IS NULL
            LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: sourceId)
                Self.bindText(stmt, index: 2, value: relation)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    rel = GraphRelationship(
                        id: String(cString: sqlite3_column_text(stmt, 0)),
                        sourceId: String(cString: sqlite3_column_text(stmt, 1)),
                        targetId: String(cString: sqlite3_column_text(stmt, 2)),
                        relation: String(cString: sqlite3_column_text(stmt, 3)),
                        confidence: sqlite3_column_double(stmt, 4),
                        model: String(cString: sqlite3_column_text(stmt, 5)),
                        validFrom: String(cString: sqlite3_column_text(stmt, 6)),
                        validUntil: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                        createdAt: String(cString: sqlite3_column_text(stmt, 8))
                    )
                }
            }
        )
        return rel
    }

    private func invalidateRelationship(id: String) throws {
        _ = try executeUpdate(
            "UPDATE relationships SET valid_until = datetime('now') WHERE id = ?1"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    public func queryEntityGraph(name: String, depth: Int) throws -> [GraphResult] {
        let maxDepth = min(depth, 4)
        var results: [GraphResult] = []
        try prepareAndExecute(
            """
            WITH RECURSIVE walk(entity_id, entity_name, entity_type, depth, path) AS (
                SELECT id, name, type, 0, name
                FROM entities WHERE name LIKE ?1 COLLATE NOCASE
                UNION ALL
                SELECT e.id, e.name, e.type, w.depth + 1,
                       w.path || ' -> ' || r.relation || ' -> ' || e.name
                FROM walk w
                JOIN relationships r ON r.source_id = w.entity_id AND r.valid_until IS NULL
                JOIN entities e ON e.id = r.target_id
                WHERE w.depth < ?2
            )
            SELECT entity_name, entity_type, depth, path FROM walk WHERE depth > 0
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: name)
                sqlite3_bind_int(stmt, 2, Int32(maxDepth))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(
                        GraphResult(
                            entityName: String(cString: sqlite3_column_text(stmt, 0)),
                            entityType: String(cString: sqlite3_column_text(stmt, 1)),
                            depth: Int(sqlite3_column_int(stmt, 2)),
                            path: String(cString: sqlite3_column_text(stmt, 3))
                        )
                    )
                }
            }
        )
        return results
    }

    public func queryRelationships(relation: String) throws -> [GraphResult] {
        var results: [GraphResult] = []
        try prepareAndExecute(
            """
            SELECT e_src.name, e_src.type, e_tgt.name, r.relation
            FROM relationships r
            JOIN entities e_src ON e_src.id = r.source_id
            JOIN entities e_tgt ON e_tgt.id = r.target_id
            WHERE r.relation = ?1 AND r.valid_until IS NULL
            ORDER BY r.created_at DESC
            LIMIT 50
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: relation)
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let srcName = String(cString: sqlite3_column_text(stmt, 0))
                    let srcType = String(cString: sqlite3_column_text(stmt, 1))
                    let tgtName = String(cString: sqlite3_column_text(stmt, 2))
                    let rel = String(cString: sqlite3_column_text(stmt, 3))
                    results.append(
                        GraphResult(
                            entityName: srcName,
                            entityType: srcType,
                            depth: 1,
                            path: "\(srcName) -> \(rel) -> \(tgtName)"
                        )
                    )
                }
            }
        )
        return results
    }

    public func loadRecentRelationships(limit: Int) throws -> [GraphResult] {
        var results: [GraphResult] = []
        try prepareAndExecute(
            """
            SELECT e_src.name, e_src.type, e_tgt.name, r.relation
            FROM relationships r
            JOIN entities e_src ON e_src.id = r.source_id
            JOIN entities e_tgt ON e_tgt.id = r.target_id
            WHERE r.valid_until IS NULL
            ORDER BY r.created_at DESC
            LIMIT ?1
            """,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let srcName = String(cString: sqlite3_column_text(stmt, 0))
                    let srcType = String(cString: sqlite3_column_text(stmt, 1))
                    let tgtName = String(cString: sqlite3_column_text(stmt, 2))
                    let rel = String(cString: sqlite3_column_text(stmt, 3))
                    results.append(
                        GraphResult(
                            entityName: srcName,
                            entityType: srcType,
                            depth: 1,
                            path: "\(srcName) -> \(rel) -> \(tgtName)"
                        )
                    )
                }
            }
        )
        return results
    }

    private static func readGraphEntity(_ stmt: OpaquePointer) -> GraphEntity {
        GraphEntity(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            type: String(cString: sqlite3_column_text(stmt, 2)),
            metadata: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            model: String(cString: sqlite3_column_text(stmt, 4)),
            createdAt: String(cString: sqlite3_column_text(stmt, 5)),
            updatedAt: String(cString: sqlite3_column_text(stmt, 6))
        )
    }

    private func deterministicId(_ components: String...) -> String {
        let input = components.joined(separator: ":")
        let hash = SHA256.hash(data: Data(input.utf8))
        return Array(hash).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SQLite Helpers

/// SQLITE_TRANSIENT tells SQLite to make its own copy of the string data immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension MemoryDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
