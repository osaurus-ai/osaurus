//
//  ChatHistoryDatabase.swift
//  osaurus
//
//  SQLite-backed chat history. One row per session + one row per turn,
//  with indices on (agent_id), (source), (source_plugin_id, external_session_key)
//  for fast sidebar queries and plugin-side find-or-create.
//
//  Mirrors the MemoryDatabase / PluginDatabase pattern: WAL pragma,
//  serial dispatch queue, versioned migrations via PRAGMA user_version,
//  and a real prepared-statement LRU cache (`PreparedStatementCache`).
//
//  All on-disk storage is encrypted via the vendored SQLCipher target
//  (`OsaurusSQLCipher`). The data-encryption key comes from
//  `StorageKeyManager`. In-memory test DBs are opened plaintext.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum ChatHistoryDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open chat-history database: \(m)"
        case .failedToExecute(let m): return "Failed to execute chat-history query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare chat-history statement: \(m)"
        case .migrationFailed(let m): return "Chat-history migration failed: \(m)"
        case .notOpen: return "Chat-history database is not open"
        }
    }
}

public final class ChatHistoryDatabase: @unchecked Sendable {
    public static let shared = ChatHistoryDatabase()

    private static let schemaVersion = 2

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.chatHistory.database")
    private let stmtCache = PreparedStatementCache(capacity: 64)

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // Defensive gate: production flow already awaits the
        // migrator in `AppDelegate.applicationDidFinishLaunching`,
        // but tests + future headless entry points may call
        // `open()` directly. Sync gate is a no-op once the
        // migrator's done.
        StorageMigrationCoordinator.blockingAwaitReady()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.chatHistory())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "chat-history",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext** — no
    /// encryption is applied; tests can still verify SQLCipher
    /// integration via `SQLCipherIntegrationTests`.
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
        OsaurusDatabaseHandle.deregister(name: "chat-history")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    // MARK: - Connection / Schema

    private func openConnection() throws {
        let path = OsaurusPaths.chatHistoryDatabaseFile().path
        let key = try StorageKeyManager.shared.currentKey()
        do {
            db = try EncryptedSQLiteOpener.open(path: path, key: key)
        } catch let error as EncryptedSQLiteError {
            throw ChatHistoryDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        if current < 1 { try migrateToV1() }
        if current < 2 { try migrateToV2() }
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

    private func setSchemaVersion(_ v: Int) throws {
        try executeRaw("PRAGMA user_version = \(v)")
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS sessions (
                    id                   TEXT PRIMARY KEY,
                    title                TEXT NOT NULL,
                    created_at           REAL NOT NULL,
                    updated_at           REAL NOT NULL,
                    selected_model       TEXT,
                    agent_id             TEXT,
                    source               TEXT NOT NULL DEFAULT 'chat',
                    source_plugin_id     TEXT,
                    external_session_key TEXT,
                    dispatch_task_id     TEXT,
                    turn_count           INTEGER NOT NULL DEFAULT 0
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions (agent_id)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions (source)")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_sessions_plugin_key ON sessions (source_plugin_id, external_session_key)"
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions (updated_at DESC)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS turns (
                    id            TEXT PRIMARY KEY,
                    session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    seq           INTEGER NOT NULL,
                    role          TEXT NOT NULL,
                    content       TEXT,
                    attachments   TEXT,
                    tool_calls    TEXT,
                    tool_call_id  TEXT,
                    tool_results  TEXT,
                    thinking      TEXT NOT NULL DEFAULT ''
                )
            """
        )
        try executeRaw("CREATE UNIQUE INDEX IF NOT EXISTS idx_turns_session_seq ON turns (session_id, seq)")

        try setSchemaVersion(1)
    }

    /// v2: add `content_hash` so `upsertTurnsIncrementally` can skip
    /// rewrites when a turn's persisted shape hasn't changed (massive
    /// win for the post-stream `save()` path that previously ran
    /// `DELETE all + INSERT all`).
    private func migrateToV2() throws {
        try executeRaw("ALTER TABLE turns ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''")
        try setSchemaVersion(2)
    }

    // MARK: - Public API: sessions

    /// Insert or replace the session row and incrementally upsert its
    /// turns. Compared to the pre-encryption implementation that did
    /// `DELETE all + INSERT all` on every save, this:
    ///
    /// - spills any large attachment payloads to the encrypted blob
    ///   store before writing rows;
    /// - reads the existing `(id, content_hash)` set inside the same
    ///   transaction;
    /// - issues `INSERT OR REPLACE` only for new / changed turns;
    /// - issues `DELETE` only for turns that disappeared;
    /// - leaves untouched turns alone (no row churn, no WAL pages).
    public func saveSession(_ session: ChatSessionData) throws {
        let preparedSession = sessionWithSpilledAttachments(session)

        try inTransaction { _ in
            try self.upsertSessionRow(preparedSession)
            try self.upsertTurnsIncrementally(
                sessionId: preparedSession.id,
                turns: preparedSession.turns
            )
            try self.transactionalStep(
                "UPDATE sessions SET turn_count = ?1, updated_at = ?2 WHERE id = ?3"
            ) { stmt in
                sqlite3_bind_int(stmt, 1, Int32(preparedSession.turns.count))
                sqlite3_bind_double(stmt, 2, preparedSession.updatedAt.timeIntervalSince1970)
                Self.bindText(stmt, index: 3, value: preparedSession.id.uuidString)
            }
        }
    }

    /// Returns a copy of `session` with every turn's attachment array
    /// passed through `AttachmentBlobStore.spillIfNeeded`.
    private func sessionWithSpilledAttachments(_ session: ChatSessionData) -> ChatSessionData {
        var copy = session
        copy.turns = session.turns.map { turn in
            var t = turn
            t.attachments = AttachmentBlobStore.spillIfNeeded(turn.attachments)
            return t
        }
        return copy
    }

    /// Append a single turn to an existing session and bump turn_count.
    public func appendTurn(sessionId: UUID, turn: ChatTurnData) throws {
        try inTransaction { _ in
            // Resolve next seq (max+1) atomically with the insert.
            var nextSeq: Int = 0
            try self.transactionalQuery(
                "SELECT COALESCE(MAX(seq) + 1, 0) FROM turns WHERE session_id = ?1",
                bind: { stmt in Self.bindText(stmt, index: 1, value: sessionId.uuidString) },
                process: { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        nextSeq = Int(sqlite3_column_int(stmt, 0))
                    }
                }
            )

            try self.transactionalStep(Self.insertTurnSQL) { stmt in
                Self.bindTurn(stmt, sessionId: sessionId, seq: nextSeq, turn: turn)
            }

            try self.transactionalStep(
                "UPDATE sessions SET turn_count = turn_count + 1, updated_at = ?1 WHERE id = ?2"
            ) { stmt in
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                Self.bindText(stmt, index: 2, value: sessionId.uuidString)
            }
        }
    }

    /// Load a session by id, including its turns in seq order. Returns
    /// nil if not found. Both the session row and its turns are
    /// fetched inside one `queue.sync` block so the main actor only
    /// pays a single round-trip across the serial queue.
    public func loadSession(id: UUID) -> ChatSessionData? {
        var session: ChatSessionData?
        do {
            try queue.sync {
                guard let connection = self.db else { throw ChatHistoryDatabaseError.notOpen }

                // 1. session row
                let sessionStmt = try self.stmtCache.statement(for: Self.selectSessionSQL, on: connection)
                Self.bindText(sessionStmt, index: 1, value: id.uuidString)
                if sqlite3_step(sessionStmt) == SQLITE_ROW {
                    session = Self.readSession(sessionStmt, turns: [])
                } else {
                    return
                }

                // 2. turns for that session, in seq order
                let turnsStmt = try self.stmtCache.statement(for: Self.selectTurnsSQL, on: connection)
                Self.bindText(turnsStmt, index: 1, value: id.uuidString)
                var turns: [ChatTurnData] = []
                while sqlite3_step(turnsStmt) == SQLITE_ROW {
                    if let turn = Self.readTurn(turnsStmt) {
                        turns.append(turn)
                    }
                }
                session?.turns = turns
            }
        } catch {
            print("[ChatHistoryDatabase] loadSession(\(id)) failed: \(error)")
            return nil
        }
        return session
    }

    /// Load all session rows (no turns) ordered by updated_at DESC.
    public func loadAllMetadata() -> [ChatSessionData] {
        loadMetadataInternal(filter: nil)
    }

    /// Load metadata filtered by agent and/or source. nil ⇒ no constraint.
    public func loadMetadata(forAgent agentId: UUID?, source: SessionSource?) -> [ChatSessionData] {
        loadMetadataInternal(filter: (agentId: agentId, source: source))
    }

    /// Find an existing session by `(source, external_session_key)`,
    /// optionally constrained to `agentId`. Used by HTTP / scheduler / watcher
    /// dispatch paths where there's no plugin id to scope by. Returns the
    /// most-recently-updated match (turns NOT loaded).
    public func findSession(
        source: SessionSource,
        externalKey: String,
        agentId: UUID?
    ) -> ChatSessionData? {
        var sessions: [ChatSessionData] = []
        let sql: String
        let bindAgent = agentId != nil
        if bindAgent {
            sql =
                Self.baseSessionSelectSQL + """
                     WHERE source = ?1 AND external_session_key = ?2 AND agent_id = ?3
                     ORDER BY updated_at DESC LIMIT 1
                    """
        } else {
            sql =
                Self.baseSessionSelectSQL + """
                     WHERE source = ?1 AND external_session_key = ?2 AND agent_id IS NULL
                     ORDER BY updated_at DESC LIMIT 1
                    """
        }
        do {
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: source.rawValue)
                    Self.bindText(stmt, index: 2, value: externalKey)
                    if let agentId { Self.bindText(stmt, index: 3, value: agentId.uuidString) }
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        sessions.append(Self.readSession(stmt, turns: []))
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] findSession(source:) failed: \(error)")
            return nil
        }
        return sessions.first
    }

    /// Find an existing session by `(source_plugin_id, external_session_key)`,
    /// optionally constrained to `agentId`. Returns the most-recently-updated
    /// match (turns NOT loaded — call `loadSession(id:)` to hydrate).
    public func findSession(
        pluginId: String,
        externalKey: String,
        agentId: UUID?
    ) -> ChatSessionData? {
        var sessions: [ChatSessionData] = []
        let sql: String
        let bindAgent = agentId != nil
        if bindAgent {
            sql =
                Self.baseSessionSelectSQL + """
                     WHERE source_plugin_id = ?1 AND external_session_key = ?2 AND agent_id = ?3
                     ORDER BY updated_at DESC LIMIT 1
                    """
        } else {
            sql =
                Self.baseSessionSelectSQL + """
                     WHERE source_plugin_id = ?1 AND external_session_key = ?2 AND agent_id IS NULL
                     ORDER BY updated_at DESC LIMIT 1
                    """
        }
        do {
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: pluginId)
                    Self.bindText(stmt, index: 2, value: externalKey)
                    if let agentId { Self.bindText(stmt, index: 3, value: agentId.uuidString) }
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        sessions.append(Self.readSession(stmt, turns: []))
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] findSession failed: \(error)")
            return nil
        }
        return sessions.first
    }

    public func deleteSession(id: UUID) throws {
        // GC: collect blob refs from this session's turns *before*
        // deleting the rows, then drop any blob no other session
        // references. Conservative: only deletes when zero remaining
        // turns reference the hash.
        var ownedRefs: Set<String> = []
        try prepareAndExecute(
            "SELECT attachments FROM turns WHERE session_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id.uuidString) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cText = sqlite3_column_text(stmt, 0) else { continue }
                    let json = String(cString: cText)
                    let parsed: [Attachment]? = Self.decodeJSON(json)
                    for a in parsed ?? [] {
                        switch a.kind {
                        case .imageRef(let h, _), .documentRef(_, let h, _):
                            ownedRefs.insert(h)
                        default: continue
                        }
                    }
                }
            }
        )

        _ = try executeUpdate("DELETE FROM sessions WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        }

        // Best-effort GC. We re-check each hash against the surviving
        // rows; anything still referenced stays.
        for hash in ownedRefs {
            if !isBlobReferenced(hash) {
                AttachmentBlobStore.delete(hash)
            }
        }
    }

    /// Returns true when at least one turn (in any session) still
    /// carries a JSON attachment ref to `hash`. Uses a `LIKE` probe
    /// because attachments live as JSON inside the TEXT column. The
    /// hash is hex-32 so collisions in `LIKE` are not a concern.
    private func isBlobReferenced(_ hash: String) -> Bool {
        var found = false
        do {
            try prepareAndExecute(
                "SELECT 1 FROM turns WHERE attachments LIKE ?1 LIMIT 1",
                bind: { stmt in
                    let pattern = "%\"hash\":\"\(hash)\"%"
                    Self.bindText(stmt, index: 1, value: pattern)
                },
                process: { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW { found = true }
                }
            )
        } catch {
            return true  // be conservative: never delete on error
        }
        return found
    }

    // MARK: - Internals: rows + turns

    private func upsertSessionRow(_ session: ChatSessionData) throws {
        try transactionalStep(Self.upsertSessionSQL) { stmt in
            Self.bindText(stmt, index: 1, value: session.id.uuidString)
            Self.bindText(stmt, index: 2, value: session.title)
            sqlite3_bind_double(stmt, 3, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
            Self.bindText(stmt, index: 5, value: session.selectedModel)
            Self.bindText(stmt, index: 6, value: session.agentId?.uuidString)
            Self.bindText(stmt, index: 7, value: session.source.rawValue)
            Self.bindText(stmt, index: 8, value: session.sourcePluginId)
            Self.bindText(stmt, index: 9, value: session.externalSessionKey)
            Self.bindText(stmt, index: 10, value: session.dispatchTaskId?.uuidString)
        }
    }

    /// Diff-based turn upsert. Reads the existing
    /// `(turn_id, content_hash, seq)` set for the session, then
    /// issues only the row-level mutations that actually changed:
    ///
    /// - new turn id          → INSERT OR REPLACE
    /// - existing id, changed → INSERT OR REPLACE (with new seq)
    /// - existing id, same    → no write (just verify seq matches)
    /// - id no longer present → DELETE
    ///
    /// `content_hash` is computed over the canonical wire form of the
    /// turn so attachment spillover and tool-result mutations both
    /// invalidate it correctly.
    fileprivate func upsertTurnsIncrementally(sessionId: UUID, turns: [ChatTurnData]) throws {
        // Existing rows for this session.
        var existing: [String: (hash: String, seq: Int)] = [:]
        try transactionalQuery(
            "SELECT id, content_hash, seq FROM turns WHERE session_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: sessionId.uuidString) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let hash =
                        sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let seq = Int(sqlite3_column_int(stmt, 2))
                    existing[id] = (hash, seq)
                }
            }
        )

        let seenIds = Set(turns.map { $0.id.uuidString })

        // Delete removed turns FIRST so their (session_id, seq) slots
        // are free before we insert the new ordering. Otherwise a
        // re-save that shrinks or reshuffles the conversation hits
        // the UNIQUE(session_id, seq) constraint when the new turn
        // tries to reuse a still-occupied seq.
        let removedIds = Set(existing.keys).subtracting(seenIds)
        for id in removedIds {
            try transactionalStep("DELETE FROM turns WHERE id = ?1 AND session_id = ?2") { stmt in
                Self.bindText(stmt, index: 1, value: id)
                Self.bindText(stmt, index: 2, value: sessionId.uuidString)
            }
        }

        // Pre-pass: any kept turn whose new seq differs from its
        // current seq gets parked at a temporary negative seq. This
        // dodges the (session_id, seq) UNIQUE constraint when two
        // kept turns swap positions (final seq of A == old seq of B).
        // Negative seqs are never produced by the normal write path.
        var parked: [String: Int] = [:]  // id → original seq
        for (idx, turn) in turns.enumerated() {
            let id = turn.id.uuidString
            if let prior = existing[id], prior.seq != idx {
                let parkSeq = -((parked.count) + 1)
                try transactionalStep(
                    "UPDATE turns SET seq = ?1 WHERE id = ?2 AND session_id = ?3"
                ) { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(parkSeq))
                    Self.bindText(stmt, index: 2, value: id)
                    Self.bindText(stmt, index: 3, value: sessionId.uuidString)
                }
                parked[id] = prior.seq
            }
        }

        for (idx, turn) in turns.enumerated() {
            let id = turn.id.uuidString
            let newHash = Self.contentHash(for: turn)
            // Skip rewriting unchanged turns (same id, same hash, same seq).
            if let prior = existing[id], prior.hash == newHash, prior.seq == idx, parked[id] == nil {
                continue
            }
            try transactionalStep(Self.insertTurnSQL) { stmt in
                Self.bindTurn(
                    stmt,
                    sessionId: sessionId,
                    seq: idx,
                    turn: turn,
                    contentHash: newHash
                )
            }
        }
    }

    /// Canonical SHA-256 over the persisted shape of a turn — used by
    /// `upsertTurnsIncrementally` to skip writes when nothing changed.
    /// Hashes role + content + thinking + JSON-encoded attachments,
    /// tool calls, tool call id, and tool results, in a stable order
    /// that matches the column binding order.
    static func contentHash(for turn: ChatTurnData) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: Data(turn.role.rawValue.utf8))
        hasher.update(data: Data(turn.content.utf8))
        hasher.update(data: Data(turn.thinking.utf8))
        if let attachments = try? encoder.encode(turn.attachments) {
            hasher.update(data: attachments)
        }
        if let calls = turn.toolCalls.flatMap({ try? encoder.encode($0) }) {
            hasher.update(data: calls)
        }
        if let cid = turn.toolCallId {
            hasher.update(data: Data(cid.utf8))
        }
        if let results = try? encoder.encode(turn.toolResults) {
            hasher.update(data: results)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadTurns(sessionId: UUID) throws -> [ChatTurnData] {
        var turns: [ChatTurnData] = []
        try prepareAndExecute(
            Self.selectTurnsSQL,
            bind: { stmt in Self.bindText(stmt, index: 1, value: sessionId.uuidString) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let turn = Self.readTurn(stmt) {
                        turns.append(turn)
                    }
                }
            }
        )
        return turns
    }

    private func loadMetadataInternal(
        filter: (agentId: UUID?, source: SessionSource?)?
    ) -> [ChatSessionData] {
        var sessions: [ChatSessionData] = []
        var sql = Self.baseSessionSelectSQL
        var clauses: [String] = []
        var bindings: [(Int32, String)] = []  // 1-indexed bind
        var nextIdx: Int32 = 1
        if let agentId = filter?.agentId {
            clauses.append("agent_id = ?\(nextIdx)")
            bindings.append((nextIdx, agentId.uuidString))
            nextIdx += 1
        }
        if let source = filter?.source {
            clauses.append("source = ?\(nextIdx)")
            bindings.append((nextIdx, source.rawValue))
            nextIdx += 1
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY updated_at DESC"

        do {
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    for (idx, value) in bindings {
                        Self.bindText(stmt, index: Int(idx), value: value)
                    }
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        sessions.append(Self.readSession(stmt, turns: []))
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] loadMetadata failed: \(error)")
        }
        return sessions
    }

    // MARK: - SQL constants

    private static let baseSessionSelectSQL = """
        SELECT id, title, created_at, updated_at, selected_model, agent_id,
               source, source_plugin_id, external_session_key, dispatch_task_id
        FROM sessions
        """

    private static let selectSessionSQL = baseSessionSelectSQL + " WHERE id = ?1"

    private static let upsertSessionSQL = """
        INSERT INTO sessions
            (id, title, created_at, updated_at, selected_model, agent_id,
             source, source_plugin_id, external_session_key, dispatch_task_id)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(id) DO UPDATE SET
            title                = excluded.title,
            updated_at           = excluded.updated_at,
            selected_model       = excluded.selected_model,
            agent_id             = excluded.agent_id,
            source               = excluded.source,
            source_plugin_id     = excluded.source_plugin_id,
            external_session_key = excluded.external_session_key,
            dispatch_task_id     = excluded.dispatch_task_id
        """

    private static let insertTurnSQL = """
        INSERT INTO turns
            (id, session_id, seq, role, content, attachments,
             tool_calls, tool_call_id, tool_results, thinking, content_hash)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        ON CONFLICT(id) DO UPDATE SET
            session_id   = excluded.session_id,
            seq          = excluded.seq,
            role         = excluded.role,
            content      = excluded.content,
            attachments  = excluded.attachments,
            tool_calls   = excluded.tool_calls,
            tool_call_id = excluded.tool_call_id,
            tool_results = excluded.tool_results,
            thinking     = excluded.thinking,
            content_hash = excluded.content_hash
        """

    private static let selectTurnsSQL = """
        SELECT id, role, content, attachments, tool_calls, tool_call_id, tool_results, thinking
        FROM turns
        WHERE session_id = ?1
        ORDER BY seq ASC
        """

    // MARK: - Row decoding

    private static func readSession(_ stmt: OpaquePointer, turns: [ChatTurnData]) -> ChatSessionData {
        let idStr = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let agentId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }.flatMap { UUID(uuidString: $0) }
        let sourceRaw = String(cString: sqlite3_column_text(stmt, 6))
        let source = SessionSource(rawValue: sourceRaw) ?? .chat
        let pluginId = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let externalKey = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let dispatchId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }.flatMap { UUID(uuidString: $0) }
        return ChatSessionData(
            id: UUID(uuidString: idStr) ?? UUID(),
            title: title,
            createdAt: created,
            updatedAt: updated,
            selectedModel: model,
            turns: turns,
            agentId: agentId,
            source: source,
            sourcePluginId: pluginId,
            externalSessionKey: externalKey,
            dispatchTaskId: dispatchId
        )
    }

    private static func readTurn(_ stmt: OpaquePointer) -> ChatTurnData? {
        let idStr = String(cString: sqlite3_column_text(stmt, 0))
        let roleStr = String(cString: sqlite3_column_text(stmt, 1))
        guard let role = MessageRole(rawValue: roleStr) else { return nil }
        let content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let attachments: [Attachment] =
            sqlite3_column_text(stmt, 3)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? []
        let toolCalls: [ToolCall]? = sqlite3_column_text(stmt, 4)
            .map { String(cString: $0) }
            .flatMap(decodeJSON)
        let toolCallId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let toolResults: [String: String] =
            sqlite3_column_text(stmt, 6)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? [:]
        let thinking = String(cString: sqlite3_column_text(stmt, 7))
        return ChatTurnData(
            id: UUID(uuidString: idStr) ?? UUID(),
            role: role,
            content: content,
            attachments: attachments,
            toolCalls: toolCalls,
            toolCallId: toolCallId,
            toolResults: toolResults,
            thinking: thinking
        )
    }

    private static func bindTurn(
        _ stmt: OpaquePointer,
        sessionId: UUID,
        seq: Int,
        turn: ChatTurnData,
        contentHash: String? = nil
    ) {
        bindText(stmt, index: 1, value: turn.id.uuidString)
        bindText(stmt, index: 2, value: sessionId.uuidString)
        sqlite3_bind_int(stmt, 3, Int32(seq))
        bindText(stmt, index: 4, value: turn.role.rawValue)
        bindText(stmt, index: 5, value: turn.content)
        bindText(stmt, index: 6, value: encodeJSON(turn.attachments))
        bindText(stmt, index: 7, value: turn.toolCalls.flatMap(encodeJSON))
        bindText(stmt, index: 8, value: turn.toolCallId)
        bindText(stmt, index: 9, value: encodeJSON(turn.toolResults))
        bindText(stmt, index: 10, value: turn.thinking)
        bindText(stmt, index: 11, value: contentHash ?? Self.contentHash(for: turn))
    }

    // MARK: - JSON helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private static func decodeJSON<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - SQLite helpers (mirrors MemoryDatabase)

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, Int32(index), value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw ChatHistoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        try handler(s)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(s) }
            bind(s)
            try process(s)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        var success = false
        try prepareAndExecute(sql, bind: bind) { stmt in
            success = sqlite3_step(stmt) == SQLITE_DONE
        }
        return success
    }

    private func inTransaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
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

    /// Prepare/bind/step/finalize inside an already-open transaction.
    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw ChatHistoryDatabaseError.failedToExecute("step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Prepare/bind/process/finalize inside an already-open transaction (queries).
    private func transactionalQuery(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        try process(s)
    }

    // MARK: - Test hooks

    #if DEBUG
        /// Test-only: run `body` on the database's serial queue with
        /// the connection handle. Used by storage tests to inspect
        /// internal columns (e.g. `content_hash`) without exposing
        /// every read path through a public API.
        func queueRunForTest(_ body: (OpaquePointer) throws -> Void) throws {
            try queue.sync {
                guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
                try body(connection)
            }
        }
    #endif
}
