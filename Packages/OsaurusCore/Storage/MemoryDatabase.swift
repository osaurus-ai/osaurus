//
//  MemoryDatabase.swift
//  osaurus
//
//  SQLite database for the v2 memory system.
//  WAL mode, serial queue, versioned migrations.
//
//  Tables:
//    identity        — single row of stable user facts
//    pinned_facts    — promoted, salience-scored facts (replaces v1 memory_entries)
//    episodes        — per-session digests (replaces v1 conversation_summaries)
//    transcript      — raw conversation turns (renamed from v1 conversation_chunks)
//    pending_signals — buffered turns awaiting end-of-session distillation
//    processing_log  — distillation/consolidation latency + status
//
//  v5 migration carries forward identity, episodes, and transcript from
//  the old schema. The noisy v1 working-memory entries, profile events,
//  verification audit log, agent activity, embeddings cache, and graph
//  tables are all dropped — `pinned_facts` rebuilds organically from new
//  conversations and consolidator promotion.
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

    private static let schemaVersion = 5

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
    public func openInMemory() throws {
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
        if currentVersion < 5 {
            try migrateToV5(from: currentVersion)
        }
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

    /// V5 migration: rebuild around the v2 schema. Carries forward
    /// `user_profile` → `identity.content`, `user_edits` → `identity.overrides`,
    /// `conversation_summaries` → `episodes`, and `conversation_chunks` → `transcript`.
    /// Drops `memory_entries`, `profile_events`, `memory_events`, `agent_activity`,
    /// `embeddings`, and the graph tables (`entities` / `relationships`).
    private func migrateToV5(from previousVersion: Int) throws {
        MemoryLogger.database.info("Running v5 migration (previous version: \(previousVersion))")

        // Create v2 tables first so we can copy into them within the same migration.
        try createV5Tables()

        // Carry-over from v1-v4 if those tables exist.
        if previousVersion >= 1 {
            try carryOverIdentityFromV1()
            try carryOverEpisodesFromV1()
            try carryOverTranscriptFromV1()
        }

        // Drop everything we don't need anymore.
        if previousVersion >= 1 {
            for table in [
                "memory_entries",
                "memory_events",
                "profile_events",
                "user_profile",
                "user_edits",
                "conversation_summaries",
                "conversation_chunks",
                "conversations",
                "agent_activity",
                "embeddings",
                "entities",
                "relationships",
                "schema_version",
            ] {
                try executeRaw("DROP TABLE IF EXISTS \(table)")
            }
        }

        try setSchemaVersion(5)
        MemoryLogger.database.info("v5 migration completed")
    }

    private func createV5Tables() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS identity (
                    id            INTEGER PRIMARY KEY CHECK (id = 1),
                    content       TEXT NOT NULL DEFAULT '',
                    overrides     TEXT NOT NULL DEFAULT '[]',
                    token_count   INTEGER NOT NULL DEFAULT 0,
                    version       INTEGER NOT NULL DEFAULT 0,
                    model         TEXT NOT NULL DEFAULT '',
                    generated_at  TEXT NOT NULL DEFAULT ''
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS pinned_facts (
                    id                  TEXT PRIMARY KEY,
                    agent_id            TEXT NOT NULL,
                    content             TEXT NOT NULL,
                    salience            REAL NOT NULL DEFAULT 0.5,
                    source_count        INTEGER NOT NULL DEFAULT 1,
                    source_episode_id   INTEGER,
                    last_used           TEXT NOT NULL DEFAULT (datetime('now')),
                    use_count           INTEGER NOT NULL DEFAULT 0,
                    status              TEXT NOT NULL DEFAULT 'active',
                    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
                    tags_csv            TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pinned_agent_status ON pinned_facts(agent_id, status, salience DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS episodes (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    summary           TEXT NOT NULL,
                    topics_csv        TEXT NOT NULL DEFAULT '',
                    entities_csv      TEXT NOT NULL DEFAULT '',
                    decisions         TEXT NOT NULL DEFAULT '',
                    action_items      TEXT NOT NULL DEFAULT '',
                    salience          REAL NOT NULL DEFAULT 0.5,
                    token_count       INTEGER NOT NULL DEFAULT 0,
                    model             TEXT NOT NULL DEFAULT '',
                    conversation_at   TEXT NOT NULL,
                    status            TEXT NOT NULL DEFAULT 'active',
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_episodes_agent_at ON episodes(agent_id, status, conversation_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS transcript (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    chunk_index       INTEGER NOT NULL,
                    role              TEXT NOT NULL,
                    content           TEXT NOT NULL,
                    token_count       INTEGER NOT NULL,
                    title             TEXT,
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_transcript_conv ON transcript(conversation_id, chunk_index)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_transcript_agent_created ON transcript(agent_id, created_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS pending_signals (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    user_message      TEXT NOT NULL,
                    assistant_message TEXT,
                    status            TEXT NOT NULL DEFAULT 'pending',
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_conv_status ON pending_signals(conversation_id, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_agent_status ON pending_signals(agent_id, status)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS processing_log (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id        TEXT NOT NULL,
                    task_type       TEXT NOT NULL,
                    model           TEXT,
                    status          TEXT NOT NULL,
                    details         TEXT,
                    input_tokens    INTEGER,
                    output_tokens   INTEGER,
                    duration_ms     INTEGER,
                    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_processing_log_created ON processing_log(created_at)")
    }

    private func carryOverIdentityFromV1() throws {
        guard try tableExists("user_profile") else { return }

        var content = ""
        var version = 0
        var generatedAt = ""
        var model = ""
        try executeRaw(
            "SELECT content, version, model, generated_at FROM user_profile WHERE id = 1"
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                content = String(cString: sqlite3_column_text(stmt, 0))
                version = Int(sqlite3_column_int(stmt, 1))
                model = String(cString: sqlite3_column_text(stmt, 2))
                generatedAt = String(cString: sqlite3_column_text(stmt, 3))
            }
        }

        var overrides: [String] = []
        if try tableExists("user_edits") {
            try executeRaw(
                "SELECT content FROM user_edits WHERE deleted_at IS NULL ORDER BY created_at"
            ) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    overrides.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        }

        // Skip if both are empty — leave the row uninitialized so the
        // Identity sheet shows a clean "no profile yet" state.
        guard !content.isEmpty || !overrides.isEmpty else { return }

        let overridesJSON =
            (try? JSONEncoder().encode(overrides)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let tokenCount = max(0, content.count / MemoryConfiguration.charsPerToken)

        try executeRaw("DELETE FROM identity WHERE id = 1")
        try insertRow(
            """
            INSERT INTO identity (id, content, overrides, token_count, version, model, generated_at)
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: content)
            Self.bindText(stmt, index: 2, value: overridesJSON)
            sqlite3_bind_int(stmt, 3, Int32(tokenCount))
            sqlite3_bind_int(stmt, 4, Int32(version))
            Self.bindText(stmt, index: 5, value: model.isEmpty ? "v1-import" : model)
            Self.bindText(
                stmt,
                index: 6,
                value: generatedAt.isEmpty ? Self.iso8601Now() : generatedAt
            )
        }

        MemoryLogger.database.info(
            "v5 migration: carried over identity (v\(version), \(overrides.count) overrides)"
        )
    }

    private func carryOverEpisodesFromV1() throws {
        guard try tableExists("conversation_summaries") else { return }

        var copied = 0
        try executeRaw(
            """
            SELECT agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
            FROM conversation_summaries
            """
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let agentId = String(cString: sqlite3_column_text(stmt, 0))
                let conversationId = String(cString: sqlite3_column_text(stmt, 1))
                let summary = String(cString: sqlite3_column_text(stmt, 2))
                let tokenCount = Int(sqlite3_column_int(stmt, 3))
                let model = String(cString: sqlite3_column_text(stmt, 4))
                let conversationAt = String(cString: sqlite3_column_text(stmt, 5))
                let status = String(cString: sqlite3_column_text(stmt, 6))
                let createdAt = String(cString: sqlite3_column_text(stmt, 7))

                do {
                    try insertRow(
                        """
                        INSERT INTO episodes
                            (agent_id, conversation_id, summary, token_count, model,
                             conversation_at, status, created_at, salience)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0.5)
                        """
                    ) { ins in
                        Self.bindText(ins, index: 1, value: agentId)
                        Self.bindText(ins, index: 2, value: conversationId)
                        Self.bindText(ins, index: 3, value: summary)
                        sqlite3_bind_int(ins, 4, Int32(tokenCount))
                        Self.bindText(ins, index: 5, value: model)
                        Self.bindText(ins, index: 6, value: conversationAt)
                        Self.bindText(ins, index: 7, value: status)
                        Self.bindText(ins, index: 8, value: createdAt)
                    }
                    copied += 1
                } catch {
                    MemoryLogger.database.warning("v5 migration: failed to carry over summary: \(error)")
                }
            }
        }

        if copied > 0 {
            MemoryLogger.database.info("v5 migration: carried over \(copied) episodes from conversation_summaries")
        }
    }

    private func carryOverTranscriptFromV1() throws {
        guard try tableExists("conversation_chunks"), try tableExists("conversations") else { return }

        var copied = 0
        try executeRaw(
            """
            SELECT cc.conversation_id, cc.chunk_index, cc.role, cc.content, cc.token_count, cc.created_at,
                   c.agent_id, c.title
            FROM conversation_chunks cc
            JOIN conversations c ON c.id = cc.conversation_id
            """
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let conversationId = String(cString: sqlite3_column_text(stmt, 0))
                let chunkIndex = Int(sqlite3_column_int(stmt, 1))
                let role = String(cString: sqlite3_column_text(stmt, 2))
                let content = String(cString: sqlite3_column_text(stmt, 3))
                let tokenCount = Int(sqlite3_column_int(stmt, 4))
                let createdAt = String(cString: sqlite3_column_text(stmt, 5))
                let agentId = String(cString: sqlite3_column_text(stmt, 6))
                let title = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

                do {
                    try insertRow(
                        """
                        INSERT INTO transcript
                            (agent_id, conversation_id, chunk_index, role, content,
                             token_count, title, created_at)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                        """
                    ) { ins in
                        Self.bindText(ins, index: 1, value: agentId)
                        Self.bindText(ins, index: 2, value: conversationId)
                        sqlite3_bind_int(ins, 3, Int32(chunkIndex))
                        Self.bindText(ins, index: 4, value: role)
                        Self.bindText(ins, index: 5, value: content)
                        sqlite3_bind_int(ins, 6, Int32(tokenCount))
                        Self.bindText(ins, index: 7, value: title)
                        Self.bindText(ins, index: 8, value: createdAt)
                    }
                    copied += 1
                } catch {
                    MemoryLogger.database.warning("v5 migration: failed to carry over chunk: \(error)")
                }
            }
        }

        if copied > 0 {
            MemoryLogger.database.info("v5 migration: carried over \(copied) transcript turns")
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        var found = false
        try executeRaw("SELECT name FROM sqlite_master WHERE type='table' AND name=?") { stmt in
            Self.bindText(stmt, index: 1, value: name)
            if sqlite3_step(stmt) == SQLITE_ROW {
                found = true
            }
        }
        return found
    }

    // MARK: - Query Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw MemoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw MemoryDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    /// Execute a non-row-returning insert/update with bindings (must be on `queue`).
    private func insertRow(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        let step = sqlite3_step(s)
        guard step == SQLITE_DONE else {
            throw MemoryDatabaseError.failedToExecute(
                "INSERT step returned \(step): \(String(cString: sqlite3_errmsg(connection)))"
            )
        }
    }

    func execute<T>(_ operation: @escaping (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
            return try operation(connection)
        }
    }

    func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
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
        try prepareAndExecute(
            sql,
            bind: bind,
            process: { stmt in success = sqlite3_step(stmt) == SQLITE_DONE }
        )
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

    // MARK: - Identity

    public func loadIdentity() throws -> Identity? {
        var identity: Identity?
        try prepareAndExecute(
            "SELECT content, overrides, token_count, version, model, generated_at FROM identity WHERE id = 1",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let content = String(cString: sqlite3_column_text(stmt, 0))
                    let overridesJSON = String(cString: sqlite3_column_text(stmt, 1))
                    let overrides =
                        (overridesJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    identity = Identity(
                        content: content,
                        overrides: overrides,
                        tokenCount: Int(sqlite3_column_int(stmt, 2)),
                        version: Int(sqlite3_column_int(stmt, 3)),
                        model: String(cString: sqlite3_column_text(stmt, 4)),
                        generatedAt: String(cString: sqlite3_column_text(stmt, 5))
                    )
                }
            }
        )
        return identity
    }

    public func saveIdentity(_ identity: Identity) throws {
        let overridesJSON =
            (try? JSONEncoder().encode(identity.overrides)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        _ = try executeUpdate(
            """
            INSERT INTO identity (id, content, overrides, token_count, version, model, generated_at)
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
                content = excluded.content,
                overrides = excluded.overrides,
                token_count = excluded.token_count,
                version = excluded.version,
                model = excluded.model,
                generated_at = excluded.generated_at
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: identity.content)
            Self.bindText(stmt, index: 2, value: overridesJSON)
            sqlite3_bind_int(stmt, 3, Int32(identity.tokenCount))
            sqlite3_bind_int(stmt, 4, Int32(identity.version))
            Self.bindText(stmt, index: 5, value: identity.model)
            Self.bindText(stmt, index: 6, value: identity.generatedAt)
        }
    }

    public func setIdentityOverrides(_ overrides: [String]) throws {
        var current = try loadIdentity() ?? Identity()
        current.overrides = overrides
        try saveIdentity(current)
    }

    public func appendIdentityOverride(_ text: String) throws {
        var current = try loadIdentity() ?? Identity()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lowered = trimmed.lowercased()
        guard !current.overrides.contains(where: { $0.lowercased() == lowered }) else { return }
        current.overrides.append(trimmed)
        try saveIdentity(current)
    }

    public func removeIdentityOverride(at index: Int) throws {
        var current = try loadIdentity() ?? Identity()
        guard index >= 0, index < current.overrides.count else { return }
        current.overrides.remove(at: index)
        try saveIdentity(current)
    }

    // MARK: - Pinned Facts

    public func insertPinnedFact(_ fact: PinnedFact) throws {
        _ = try executeUpdate(
            """
            INSERT INTO pinned_facts
                (id, agent_id, content, salience, source_count, source_episode_id,
                 last_used, use_count, status, created_at, tags_csv)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6,
                    COALESCE(NULLIF(?7, ''), datetime('now')),
                    ?8, ?9,
                    COALESCE(NULLIF(?10, ''), datetime('now')),
                    ?11)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: fact.id)
            Self.bindText(stmt, index: 2, value: fact.agentId)
            Self.bindText(stmt, index: 3, value: fact.content)
            sqlite3_bind_double(stmt, 4, fact.salience)
            sqlite3_bind_int(stmt, 5, Int32(fact.sourceCount))
            if let sid = fact.sourceEpisodeId {
                sqlite3_bind_int(stmt, 6, Int32(sid))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            Self.bindText(stmt, index: 7, value: fact.lastUsed)
            sqlite3_bind_int(stmt, 8, Int32(fact.useCount))
            Self.bindText(stmt, index: 9, value: fact.status)
            Self.bindText(stmt, index: 10, value: fact.createdAt)
            Self.bindText(stmt, index: 11, value: fact.tagsCSV)
        }
    }

    public func updatePinnedFactSalience(id: String, salience: Double) throws {
        _ = try executeUpdate(
            "UPDATE pinned_facts SET salience = ?1 WHERE id = ?2"
        ) { stmt in
            sqlite3_bind_double(stmt, 1, max(0, min(1, salience)))
            Self.bindText(stmt, index: 2, value: id)
        }
    }

    public func bumpPinnedFactUsage(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        _ = try executeUpdate(
            """
            UPDATE pinned_facts
            SET last_used = datetime('now'), use_count = use_count + 1
            WHERE id IN (\(placeholders))
            """
        ) { stmt in
            for (i, id) in ids.enumerated() {
                Self.bindText(stmt, index: Int32(i + 1), value: id)
            }
        }
    }

    public func deletePinnedFact(id: String) throws {
        _ = try executeUpdate("DELETE FROM pinned_facts WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    public func evictPinnedFacts(belowSalience floor: Double, idleDays: Int) throws -> Int {
        var evicted = 0
        try prepareAndExecute(
            """
            DELETE FROM pinned_facts
            WHERE status = 'active'
              AND salience < ?1
              AND last_used <= datetime('now', '-' || ?2 || ' days')
            """,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, floor)
                sqlite3_bind_int(stmt, 2, Int32(max(0, idleDays)))
            },
            process: { stmt in
                _ = sqlite3_step(stmt)
                evicted = Int(sqlite3_changes(self.db))
            }
        )
        return evicted
    }

    public func loadPinnedFacts(
        agentId: String? = nil,
        limit: Int = 0,
        minSalience: Double = 0
    ) throws -> [PinnedFact] {
        var facts: [PinnedFact] = []
        var sql = "SELECT \(Self.pinnedColumns) FROM pinned_facts WHERE status = 'active' AND salience >= ?1"
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY salience DESC, last_used DESC"
        if limit > 0 {
            let limitParam = agentId != nil ? 3 : 2
            sql += " LIMIT ?\(limitParam)"
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, minSalience)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                if limit > 0 {
                    let limitIndex = Int32(agentId != nil ? 3 : 2)
                    sqlite3_bind_int(stmt, limitIndex, Int32(limit))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func loadPinnedFactsByIds(_ ids: [String]) throws -> [PinnedFact] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        let sql = """
            SELECT \(Self.pinnedColumns)
            FROM pinned_facts
            WHERE status = 'active' AND id IN (\(placeholders))
            """
        var facts: [PinnedFact] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    Self.bindText(stmt, index: Int32(i + 1), value: id)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func searchPinnedFactsText(
        query: String,
        agentId: String? = nil,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [PinnedFact] {
        var facts: [PinnedFact] = []
        var sql = """
            SELECT \(Self.pinnedColumns)
            FROM pinned_facts
            WHERE status = 'active' AND content LIKE '%' || ?1 || '%'
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY salience DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func decayPinnedSalience(halfLifeDays: Double) throws {
        try decaySalience(
            selectSQL: """
                SELECT id, salience, julianday('now') - julianday(last_used) AS dt_days
                FROM pinned_facts WHERE status = 'active'
                """,
            updateSQL: "UPDATE pinned_facts SET salience = ?1 WHERE id = ?2",
            halfLifeDays: halfLifeDays,
            bindId: { stmt, id in Self.bindText(stmt, index: 2, value: id) }
        )
    }

    public func pinnedFactStats(agentId: String? = nil) throws -> Int {
        var count = 0
        let sql =
            agentId == nil
            ? "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active'"
            : "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active' AND agent_id = ?1"
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

    public func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)] {
        var results: [(String, Int)] = []
        try prepareAndExecute(
            """
            SELECT agent_id, COUNT(*) FROM pinned_facts
            WHERE status = 'active'
            GROUP BY agent_id
            ORDER BY 2 DESC
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let count = Int(sqlite3_column_int(stmt, 1))
                    results.append((id, count))
                }
            }
        )
        return results
    }

    private static let pinnedColumns =
        "id, agent_id, content, salience, source_count, source_episode_id, last_used, use_count, status, created_at, tags_csv"

    private static func readPinnedFact(_ stmt: OpaquePointer) -> PinnedFact {
        PinnedFact(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            content: String(cString: sqlite3_column_text(stmt, 2)),
            salience: sqlite3_column_double(stmt, 3),
            sourceCount: Int(sqlite3_column_int(stmt, 4)),
            sourceEpisodeId: sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? Int(sqlite3_column_int(stmt, 5)) : nil,
            lastUsed: String(cString: sqlite3_column_text(stmt, 6)),
            useCount: Int(sqlite3_column_int(stmt, 7)),
            status: String(cString: sqlite3_column_text(stmt, 8)),
            createdAt: String(cString: sqlite3_column_text(stmt, 9)),
            tagsCSV: sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        )
    }

    // MARK: - Episodes

    public func insertEpisode(_ ep: Episode) throws -> Int {
        _ = try executeUpdate(
            """
            INSERT INTO episodes
                (agent_id, conversation_id, summary, topics_csv, entities_csv,
                 decisions, action_items, salience, token_count, model,
                 conversation_at, status, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                    COALESCE(NULLIF(?13, ''), datetime('now')))
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: ep.agentId)
            Self.bindText(stmt, index: 2, value: ep.conversationId)
            Self.bindText(stmt, index: 3, value: ep.summary)
            Self.bindText(stmt, index: 4, value: ep.topicsCSV)
            Self.bindText(stmt, index: 5, value: ep.entitiesCSV)
            Self.bindText(stmt, index: 6, value: ep.decisions)
            Self.bindText(stmt, index: 7, value: ep.actionItems)
            sqlite3_bind_double(stmt, 8, ep.salience)
            sqlite3_bind_int(stmt, 9, Int32(ep.tokenCount))
            Self.bindText(stmt, index: 10, value: ep.model)
            Self.bindText(stmt, index: 11, value: ep.conversationAt)
            Self.bindText(stmt, index: 12, value: ep.status)
            Self.bindText(stmt, index: 13, value: ep.createdAt)
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Atomically insert an episode and mark its pending signals as processed.
    public func insertEpisodeAndMarkProcessed(_ ep: Episode) throws -> Int {
        try inTransaction { _ in
            var rowid: Int = 0
            var stmt: OpaquePointer?
            let insertSQL = """
                INSERT INTO episodes
                    (agent_id, conversation_id, summary, topics_csv, entities_csv,
                     decisions, action_items, salience, token_count, model,
                     conversation_at, status, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                        COALESCE(NULLIF(?13, ''), datetime('now')))
                """
            guard sqlite3_prepare_v2(self.db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(self.db)))
            }
            Self.bindText(s, index: 1, value: ep.agentId)
            Self.bindText(s, index: 2, value: ep.conversationId)
            Self.bindText(s, index: 3, value: ep.summary)
            Self.bindText(s, index: 4, value: ep.topicsCSV)
            Self.bindText(s, index: 5, value: ep.entitiesCSV)
            Self.bindText(s, index: 6, value: ep.decisions)
            Self.bindText(s, index: 7, value: ep.actionItems)
            sqlite3_bind_double(s, 8, ep.salience)
            sqlite3_bind_int(s, 9, Int32(ep.tokenCount))
            Self.bindText(s, index: 10, value: ep.model)
            Self.bindText(s, index: 11, value: ep.conversationAt)
            Self.bindText(s, index: 12, value: ep.status)
            Self.bindText(s, index: 13, value: ep.createdAt)
            guard sqlite3_step(s) == SQLITE_DONE else {
                sqlite3_finalize(s)
                throw MemoryDatabaseError.failedToExecute("episode insert step failed")
            }
            sqlite3_finalize(s)
            rowid = Int(sqlite3_last_insert_rowid(self.db))

            var clear: OpaquePointer?
            let clearSQL =
                "UPDATE pending_signals SET status = 'processed' WHERE conversation_id = ?1 AND status = 'pending'"
            guard sqlite3_prepare_v2(self.db, clearSQL, -1, &clear, nil) == SQLITE_OK, let c = clear else {
                throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(self.db)))
            }
            Self.bindText(c, index: 1, value: ep.conversationId)
            _ = sqlite3_step(c)
            sqlite3_finalize(c)
            return rowid
        }
    }

    public func loadEpisodes(
        agentId: String? = nil,
        days: Int = 0,
        limit: Int = 0
    ) throws -> [Episode] {
        var episodes: [Episode] = []
        var sql = "SELECT \(Self.episodeColumns) FROM episodes WHERE status = 'active'"
        var paramIndex = 1
        var agentIndex: Int = 0
        var daysIndex: Int = 0
        var limitIndex: Int = 0
        if agentId != nil {
            sql += " AND agent_id = ?\(paramIndex)"
            agentIndex = paramIndex
            paramIndex += 1
        }
        if days > 0 {
            sql += " AND conversation_at >= datetime('now', '-' || ?\(paramIndex) || ' days')"
            daysIndex = paramIndex
            paramIndex += 1
        }
        sql += " ORDER BY conversation_at DESC"
        if limit > 0 {
            sql += " LIMIT ?\(paramIndex)"
            limitIndex = paramIndex
        }

        try prepareAndExecute(
            sql,
            bind: { stmt in
                if agentIndex > 0, let agentId { Self.bindText(stmt, index: Int32(agentIndex), value: agentId) }
                if daysIndex > 0 { sqlite3_bind_int(stmt, Int32(daysIndex), Int32(days)) }
                if limitIndex > 0 { sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit)) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    episodes.append(Self.readEpisode(stmt))
                }
            }
        )
        return episodes
    }

    public func loadEpisodesByIds(_ ids: [Int]) throws -> [Episode] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        let sql = """
            SELECT \(Self.episodeColumns) FROM episodes
            WHERE status = 'active' AND id IN (\(placeholders))
            ORDER BY conversation_at DESC
            """
        var results: [Episode] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(Self.readEpisode(stmt))
                }
            }
        )
        return results
    }

    public func searchEpisodesText(
        query: String,
        agentId: String? = nil,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [Episode] {
        var episodes: [Episode] = []
        var sql = """
            SELECT \(Self.episodeColumns) FROM episodes
            WHERE status = 'active'
              AND (summary LIKE '%' || ?1 || '%'
                   OR topics_csv LIKE '%' || ?1 || '%'
                   OR entities_csv LIKE '%' || ?1 || '%')
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY conversation_at DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    episodes.append(Self.readEpisode(stmt))
                }
            }
        )
        return episodes
    }

    public func episodeStats(agentId: String? = nil) throws -> Int {
        var count = 0
        let sql =
            agentId == nil
            ? "SELECT COUNT(*) FROM episodes WHERE status = 'active'"
            : "SELECT COUNT(*) FROM episodes WHERE status = 'active' AND agent_id = ?1"
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

    public func deleteEpisode(id: Int) throws {
        _ = try executeUpdate("DELETE FROM episodes WHERE id = ?1") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    public func pruneEpisodes(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        var deleted = 0
        try prepareAndExecute(
            "DELETE FROM episodes WHERE conversation_at < datetime('now', '-' || ?1 || ' days')",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                _ = sqlite3_step(stmt)
                deleted = Int(sqlite3_changes(self.db))
            }
        )
        return deleted
    }

    public func decayEpisodeSalience(halfLifeDays: Double) throws {
        try decaySalience(
            selectSQL: """
                SELECT id, salience, julianday('now') - julianday(conversation_at) AS dt_days
                FROM episodes WHERE status = 'active'
                """,
            updateSQL: "UPDATE episodes SET salience = ?1 WHERE id = ?2",
            halfLifeDays: halfLifeDays,
            bindId: { stmt, id in
                if let intId = Int(id) {
                    sqlite3_bind_int(stmt, 2, Int32(intId))
                } else {
                    Self.bindText(stmt, index: 2, value: id)
                }
            }
        )
    }

    /// Apply `salience *= 0.5 ^ (Δdays / halfLife)` to every active row
    /// returned by `selectSQL`. SQLite has no `exp()` in this build, so we
    /// pull rows into Swift and compute the decay there. Shared between
    /// `decayPinnedSalience` (TEXT id) and `decayEpisodeSalience` (INTEGER id);
    /// the caller's `bindId` closure handles whichever binding shape is right.
    private func decaySalience(
        selectSQL: String,
        updateSQL: String,
        halfLifeDays: Double,
        bindId: @escaping (OpaquePointer, String) -> Void
    ) throws {
        let factor = halfLifeDays > 0 ? halfLifeDays : 1
        var rows: [(id: String, salience: Double, deltaDays: Double)] = []
        try prepareAndExecute(
            selectSQL,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    // Reading column 0 as text works for both INTEGER and TEXT
                    // primary keys; SQLite coerces.
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let sal = sqlite3_column_double(stmt, 1)
                    let dt = sqlite3_column_double(stmt, 2)
                    rows.append((id, sal, dt))
                }
            }
        )
        for row in rows {
            let scaled = max(0, min(1, row.salience * pow(0.5, max(0, row.deltaDays) / factor)))
            _ = try executeUpdate(updateSQL) { stmt in
                sqlite3_bind_double(stmt, 1, scaled)
                bindId(stmt, row.id)
            }
        }
    }

    public func loadAllEpisodeKeys() throws -> [(id: Int, agentId: String, conversationId: String)] {
        var keys: [(id: Int, agentId: String, conversationId: String)] = []
        try prepareAndExecute(
            "SELECT id, agent_id, conversation_id FROM episodes WHERE status = 'active'",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            Int(sqlite3_column_int(stmt, 0)),
                            String(cString: sqlite3_column_text(stmt, 1)),
                            String(cString: sqlite3_column_text(stmt, 2))
                        )
                    )
                }
            }
        )
        return keys
    }

    private static let episodeColumns =
        "id, agent_id, conversation_id, summary, topics_csv, entities_csv, decisions, action_items, salience, token_count, model, conversation_at, status, created_at"

    private static func readEpisode(_ stmt: OpaquePointer) -> Episode {
        Episode(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            summary: String(cString: sqlite3_column_text(stmt, 3)),
            topicsCSV: String(cString: sqlite3_column_text(stmt, 4)),
            entitiesCSV: String(cString: sqlite3_column_text(stmt, 5)),
            decisions: String(cString: sqlite3_column_text(stmt, 6)),
            actionItems: String(cString: sqlite3_column_text(stmt, 7)),
            salience: sqlite3_column_double(stmt, 8),
            tokenCount: Int(sqlite3_column_int(stmt, 9)),
            model: String(cString: sqlite3_column_text(stmt, 10)),
            conversationAt: String(cString: sqlite3_column_text(stmt, 11)),
            status: String(cString: sqlite3_column_text(stmt, 12)),
            createdAt: String(cString: sqlite3_column_text(stmt, 13))
        )
    }

    // MARK: - Transcript

    public func insertTranscriptTurn(
        agentId: String,
        conversationId: String,
        chunkIndex: Int,
        role: String,
        content: String,
        tokenCount: Int,
        title: String? = nil,
        createdAt: String? = nil
    ) throws {
        let effectiveDate = (createdAt?.isEmpty == false) ? createdAt : nil
        _ = try executeUpdate(
            """
            INSERT INTO transcript
                (agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(?8, datetime('now')))
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
            Self.bindText(stmt, index: 2, value: conversationId)
            sqlite3_bind_int(stmt, 3, Int32(chunkIndex))
            Self.bindText(stmt, index: 4, value: role)
            Self.bindText(stmt, index: 5, value: content)
            sqlite3_bind_int(stmt, 6, Int32(tokenCount))
            Self.bindText(stmt, index: 7, value: title)
            Self.bindText(stmt, index: 8, value: effectiveDate)
        }
    }

    public func deleteTranscriptForConversation(_ conversationId: String) throws {
        _ = try executeUpdate("DELETE FROM transcript WHERE conversation_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    public func loadTranscript(
        agentId: String? = nil,
        days: Int = 30,
        limit: Int = 200
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE created_at >= datetime('now', '-' || ?1 || ' days')
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY created_at DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(days))
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func loadTranscriptByCompositeKeys(
        _ keys: [(conversationId: String, chunkIndex: Int)]
    ) throws -> [TranscriptTurn] {
        guard !keys.isEmpty else { return [] }
        let conditions = keys.enumerated().map { (i, _) in
            "(conversation_id = ?\(i * 2 + 1) AND chunk_index = ?\(i * 2 + 2))"
        }.joined(separator: " OR ")
        let sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript WHERE \(conditions)
            ORDER BY created_at DESC
            """
        var turns: [TranscriptTurn] = []
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
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func loadTranscriptForConversation(
        conversationId: String,
        limit: Int = 500
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE conversation_id = ?1
            ORDER BY chunk_index ASC
            LIMIT ?2
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: conversationId)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func searchTranscriptText(
        query: String,
        agentId: String? = nil,
        days: Int = 365,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE content LIKE '%' || ?1 || '%'
              AND created_at >= datetime('now', '-' || ?2 || ' days')
            """
        if agentId != nil { sql += " AND agent_id = ?3" }
        sql += " ORDER BY created_at DESC LIMIT ?\(agentId != nil ? 4 : 3)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: query)
                sqlite3_bind_int(stmt, 2, Int32(days))
                if let agentId { Self.bindText(stmt, index: 3, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 4 : 3)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func pruneTranscript(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        var deleted = 0
        try prepareAndExecute(
            "DELETE FROM transcript WHERE created_at < datetime('now', '-' || ?1 || ' days')",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                _ = sqlite3_step(stmt)
                deleted = Int(sqlite3_changes(self.db))
            }
        )
        return deleted
    }

    public func loadAllTranscriptKeys(days: Int = 365) throws -> [(id: Int, conversationId: String, chunkIndex: Int)] {
        var keys: [(id: Int, conversationId: String, chunkIndex: Int)] = []
        try prepareAndExecute(
            """
            SELECT id, conversation_id, chunk_index FROM transcript
            WHERE created_at >= datetime('now', '-' || ?1 || ' days')
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            Int(sqlite3_column_int(stmt, 0)),
                            String(cString: sqlite3_column_text(stmt, 1)),
                            Int(sqlite3_column_int(stmt, 2))
                        )
                    )
                }
            }
        )
        return keys
    }

    private static func readTranscriptTurn(_ stmt: OpaquePointer) -> TranscriptTurn {
        TranscriptTurn(
            id: Int(sqlite3_column_int(stmt, 0)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            chunkIndex: Int(sqlite3_column_int(stmt, 3)),
            role: String(cString: sqlite3_column_text(stmt, 4)),
            content: String(cString: sqlite3_column_text(stmt, 5)),
            tokenCount: Int(sqlite3_column_int(stmt, 6)),
            createdAt: String(cString: sqlite3_column_text(stmt, 8)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationTitle: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        )
    }

    // MARK: - Pending Signals

    public func insertPendingSignal(_ signal: PendingSignal) throws {
        _ = try executeUpdate(
            """
            INSERT INTO pending_signals
                (agent_id, conversation_id, user_message, assistant_message, status)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: signal.agentId)
            Self.bindText(stmt, index: 2, value: signal.conversationId)
            Self.bindText(stmt, index: 3, value: signal.userMessage)
            Self.bindText(stmt, index: 4, value: signal.assistantMessage)
            Self.bindText(stmt, index: 5, value: signal.status)
        }
    }

    public func loadPendingSignals(conversationId: String) throws -> [PendingSignal] {
        var signals: [PendingSignal] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, conversation_id, user_message, assistant_message, status, created_at
            FROM pending_signals WHERE conversation_id = ?1 AND status = 'pending'
            ORDER BY created_at ASC
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: conversationId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    signals.append(Self.readPendingSignal(stmt))
                }
            }
        )
        return signals
    }

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

    public func markSignalsProcessed(conversationId: String) throws {
        _ = try executeUpdate(
            "UPDATE pending_signals SET status = 'processed' WHERE conversation_id = ?1 AND status = 'pending'"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    private static func readPendingSignal(_ stmt: OpaquePointer) -> PendingSignal {
        PendingSignal(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            userMessage: String(cString: sqlite3_column_text(stmt, 3)),
            assistantMessage: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            status: String(cString: sqlite3_column_text(stmt, 5)),
            createdAt: String(cString: sqlite3_column_text(stmt, 6))
        )
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
            INSERT INTO processing_log
                (agent_id, task_type, model, status, details, input_tokens, output_tokens, duration_ms)
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

    // MARK: - Database Info & Maintenance

    public func databaseSizeBytes() -> Int64 {
        let path = OsaurusPaths.memoryDatabaseFile().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    public func optimize() {
        queue.sync {
            guard db != nil else { return }
            try? executeRaw("PRAGMA optimize")
        }
    }

    public func vacuum() throws {
        try queue.sync {
            guard db != nil else { throw MemoryDatabaseError.notOpen }
            try executeRaw("VACUUM")
        }
    }

    /// Trim old processing logs and processed pending signals.
    public func purgeOldEventData(retentionDays: Int = 30) throws {
        _ = try executeUpdate(
            "DELETE FROM processing_log WHERE created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in sqlite3_bind_int(stmt, 1, Int32(retentionDays)) }
        _ = try executeUpdate(
            "DELETE FROM pending_signals WHERE status = 'processed' AND created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in sqlite3_bind_int(stmt, 1, Int32(retentionDays)) }
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
