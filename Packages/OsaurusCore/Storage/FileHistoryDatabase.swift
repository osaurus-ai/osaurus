//
//  FileHistoryDatabase.swift
//  osaurus
//
//  Encrypted SQLite store for file history (`~/.osaurus/file-history/history.sqlite`):
//  one `file_change_sets` row per mutating tool call (or revert) and one
//  `file_change_entries` row per touched path, with exact before/after
//  signatures. The bytes live in `FileObjectStore`, next to this file.
//
//  These tables used to live in the chat-history database. `FileChangeJournal`
//  copies them over once (`legacyImportDone`).
//

import Foundation
import OsaurusSQLCipher

public enum FileHistoryDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open file history database: \(m)"
        case .failedToExecute(let m): return "Failed to execute file history query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare file history statement: \(m)"
        case .migrationFailed(let m): return "File history migration failed: \(m)"
        case .notOpen: return "File history database is not open"
        }
    }
}

public final class FileHistoryDatabase: @unchecked Sendable {
    public static let shared = FileHistoryDatabase()

    private static let latestSchemaVersion = 1
    private static let legacyImportKey = "legacy_import_done"

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.fileHistory.database")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.fileHistory())
            do {
                db = try OsaurusStorageOpener.open(path: OsaurusPaths.fileHistoryDatabaseFile().path, cacheTier: .cold)
            } catch let error as EncryptedSQLiteError {
                throw FileHistoryDatabaseError.failedToOpen(error.localizedDescription)
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
        name: "file-history",
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
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(path: ":memory:", key: nil, applyPerfPragmas: false)
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "file-history")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
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
        if version >= Self.latestSchemaVersion { return }
        try executeRaw("BEGIN TRANSACTION")
        do {
            try executeRaw(
                """
                CREATE TABLE IF NOT EXISTS file_change_sets (
                    id              TEXT PRIMARY KEY,
                    session_id      TEXT NOT NULL,
                    tool_name       TEXT NOT NULL DEFAULT '',
                    tool_call_id    TEXT,
                    turn_id         TEXT,
                    origin          TEXT NOT NULL,
                    status          TEXT NOT NULL,
                    reverts_set_id  TEXT,
                    note            TEXT,
                    created_at      REAL NOT NULL
                )
                """
            )
            try executeRaw(
                """
                CREATE TABLE IF NOT EXISTS file_change_entries (
                    id           TEXT PRIMARY KEY,
                    set_id       TEXT NOT NULL,
                    session_id   TEXT NOT NULL,
                    ordinal      INTEGER NOT NULL DEFAULT 0,
                    root_kind    TEXT NOT NULL,
                    root_id      TEXT NOT NULL,
                    path         TEXT NOT NULL,
                    from_path    TEXT,
                    kind         TEXT NOT NULL,
                    state        TEXT NOT NULL,
                    before_type  TEXT,
                    before_sig   TEXT,
                    before_mode  INTEGER,
                    before_size  INTEGER,
                    after_type   TEXT,
                    after_sig    TEXT,
                    after_mode   INTEGER,
                    after_size   INTEGER
                )
                """
            )
            try executeRaw(
                "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
            )
            for index in [
                "idx_file_change_sets_session ON file_change_sets (session_id, created_at)",
                "idx_file_change_sets_tool_call ON file_change_sets (tool_call_id)",
                "idx_file_change_sets_turn ON file_change_sets (turn_id)",
                "idx_file_change_entries_set ON file_change_entries (set_id)",
                "idx_file_change_entries_session ON file_change_entries (session_id, state)",
            ] {
                try executeRaw("CREATE INDEX IF NOT EXISTS \(index)")
            }
            try executeRaw("PRAGMA user_version = \(Self.latestSchemaVersion)")
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw FileHistoryDatabaseError.migrationFailed("v1: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy import marker

    /// Whether the rows from the chat-history database have been copied.
    var legacyImportDone: Bool {
        var done = false
        try? prepareAndExecute(
            "SELECT 1 FROM meta WHERE key = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: Self.legacyImportKey) },
            process: { stmt in done = sqlite3_step(stmt) == SQLITE_ROW }
        )
        return done
    }

    func markLegacyImportDone() throws {
        try inTransaction {
            try self.transactionalStep("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, '1')") { stmt in
                Self.bindText(stmt, index: 1, value: Self.legacyImportKey)
            }
        }
    }

    // MARK: - Change sets

    /// Insert or fully replace one change set and its entries. The set is
    /// the unit of durability: entries never exist without their set.
    public func upsertFileChangeSet(_ set: FileChangeSet) throws {
        try inTransaction {
            try self.transactionalStep("DELETE FROM file_change_entries WHERE set_id = ?1") { stmt in
                Self.bindText(stmt, index: 1, value: set.id.uuidString)
            }
            try self.transactionalStep("DELETE FROM file_change_sets WHERE id = ?1") { stmt in
                Self.bindText(stmt, index: 1, value: set.id.uuidString)
            }
            try self.transactionalStep(
                """
                INSERT INTO file_change_sets
                    (id, session_id, tool_name, tool_call_id, turn_id, origin, status,
                     reverts_set_id, note, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: set.id.uuidString)
                Self.bindText(stmt, index: 2, value: set.sessionId)
                Self.bindText(stmt, index: 3, value: set.toolName)
                Self.bindText(stmt, index: 4, value: set.toolCallId)
                Self.bindText(stmt, index: 5, value: set.turnId?.uuidString)
                Self.bindText(stmt, index: 6, value: set.origin.rawValue)
                Self.bindText(stmt, index: 7, value: set.status.rawValue)
                Self.bindText(stmt, index: 8, value: set.revertsSetId?.uuidString)
                Self.bindText(stmt, index: 9, value: set.note)
                sqlite3_bind_double(stmt, 10, set.createdAt.timeIntervalSince1970)
            }
            for entry in set.entries {
                try self.transactionalStep(
                    """
                    INSERT INTO file_change_entries
                        (id, set_id, session_id, ordinal, root_kind, root_id, path, from_path,
                         kind, state, before_type, before_sig, before_mode, before_size,
                         after_type, after_sig, after_mode, after_size)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                            ?15, ?16, ?17, ?18)
                    """
                ) { stmt in
                    Self.bindText(stmt, index: 1, value: entry.id.uuidString)
                    Self.bindText(stmt, index: 2, value: set.id.uuidString)
                    Self.bindText(stmt, index: 3, value: set.sessionId)
                    sqlite3_bind_int64(stmt, 4, Int64(entry.ordinal))
                    Self.bindText(stmt, index: 5, value: entry.rootKind.rawValue)
                    Self.bindText(stmt, index: 6, value: entry.rootId)
                    Self.bindText(stmt, index: 7, value: entry.path)
                    Self.bindText(stmt, index: 8, value: entry.fromPath)
                    Self.bindText(stmt, index: 9, value: entry.kind.rawValue)
                    Self.bindText(stmt, index: 10, value: entry.state.rawValue)
                    Self.bindPathState(stmt, startIndex: 11, state: entry.before)
                    Self.bindPathState(stmt, startIndex: 15, state: entry.after)
                }
            }
        }
    }

    /// Every change set of a session (oldest first) with its entries.
    public func loadFileChangeSets(sessionId: String) -> [FileChangeSet] {
        do {
            return try Self.readSets(sessionId: sessionId, query: prepareAndExecute)
        } catch {
            print("[FileHistoryDatabase] loadFileChangeSets failed: \(error)")
            return []
        }
    }

    public func deleteFileChangeSets(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try inTransaction {
            for id in ids {
                try self.transactionalStep("DELETE FROM file_change_entries WHERE set_id = ?1") { stmt in
                    Self.bindText(stmt, index: 1, value: id.uuidString)
                }
                try self.transactionalStep("DELETE FROM file_change_sets WHERE id = ?1") { stmt in
                    Self.bindText(stmt, index: 1, value: id.uuidString)
                }
            }
        }
    }

    public func deleteFileChanges(sessionId: String) throws {
        try inTransaction {
            try self.transactionalStep("DELETE FROM file_change_entries WHERE session_id = ?1") { stmt in
                Self.bindText(stmt, index: 1, value: sessionId)
            }
            try self.transactionalStep("DELETE FROM file_change_sets WHERE session_id = ?1") { stmt in
                Self.bindText(stmt, index: 1, value: sessionId)
            }
        }
    }

    public func fileChangeSessionId(forSetId id: String) -> String? {
        fileChangeSessionId(where: "id", equals: id)
    }

    public func fileChangeSessionId(forToolCallId toolCallId: String) -> String? {
        fileChangeSessionId(where: "tool_call_id", equals: toolCallId)
    }

    public func fileChangeSessionId(forTurnId turnId: String) -> String? {
        fileChangeSessionId(where: "turn_id", equals: turnId)
    }

    private func fileChangeSessionId(where column: String, equals value: String) -> String? {
        var found: String?
        try? prepareAndExecute(
            "SELECT session_id FROM file_change_sets WHERE \(column) = ?1 LIMIT 1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: value) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    found = String(cString: sqlite3_column_text(stmt, 0))
                }
            }
        )
        return found
    }

    /// Per-session summary for the sidebar: count of paths whose latest
    /// recorded state differs from their state before the session first
    /// touched them, plus the number of sets. One pass over the minimal
    /// columns, ordered so first/last per path fall out of a linear scan.
    public func fileChangeSessionSummaries() -> [String: FileChangeSessionSummary] {
        struct PathNet { var first: String?; var last: String? }
        var perSession: [String: [String: PathNet]] = [:]
        var setCounts: [String: Int] = [:]
        try? prepareAndExecute(
            """
            SELECT e.session_id, e.root_kind, e.root_id, e.path, e.before_sig, e.after_sig
            FROM file_change_entries e JOIN file_change_sets s ON s.id = e.set_id
            ORDER BY s.created_at ASC, e.ordinal ASC
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let session = String(cString: sqlite3_column_text(stmt, 0))
                    let key =
                        String(cString: sqlite3_column_text(stmt, 1)) + "|"
                        + String(cString: sqlite3_column_text(stmt, 2)) + "|"
                        + String(cString: sqlite3_column_text(stmt, 3))
                    let before = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let after = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    if var net = perSession[session]?[key] {
                        net.last = after
                        perSession[session]?[key] = net
                    } else {
                        perSession[session, default: [:]][key] = PathNet(first: before, last: after)
                    }
                }
            }
        )
        try? prepareAndExecute(
            "SELECT session_id, COUNT(*) FROM file_change_sets GROUP BY session_id",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    setCounts[String(cString: sqlite3_column_text(stmt, 0))] = Int(
                        sqlite3_column_int64(stmt, 1))
                }
            }
        )
        var result: [String: FileChangeSessionSummary] = [:]
        for (session, count) in setCounts {
            let outstanding = perSession[session]?.values.filter { $0.first != $0.last }.count ?? 0
            result[session] = FileChangeSessionSummary(outstandingFiles: outstanding, setCount: count)
        }
        return result
    }

    /// Every signature any entry references (object-store GC roots), with
    /// the entry count so a caller can tell "no history" from a query that
    /// returned nothing. Throws instead of returning a partial set: GC
    /// treats the result as the complete root set, so an error here must
    /// never look like an empty history.
    public func fileChangeReferencedSignatures() throws -> (signatures: Set<String>, entryCount: Int) {
        var sigs: Set<String> = []
        var count = 0
        try prepareAndExecute(
            "SELECT before_sig, after_sig FROM file_change_entries",
            bind: { _ in },
            process: { stmt in
                var rc = sqlite3_step(stmt)
                while rc == SQLITE_ROW {
                    count += 1
                    if let b = sqlite3_column_text(stmt, 0) { sigs.insert(String(cString: b)) }
                    if let a = sqlite3_column_text(stmt, 1) { sigs.insert(String(cString: a)) }
                    rc = sqlite3_step(stmt)
                }
                if rc != SQLITE_DONE {
                    throw FileHistoryDatabaseError.failedToExecute(
                        "file_change_entries scan stopped early (sqlite \(rc))")
                }
            }
        )
        return (sigs, count)
    }

    /// Distinct roots any remaining entry lives under (shadow pruning).
    public func fileChangeReferencedRoots() throws -> [(kind: SandboxWorkspaceRootKind, rootId: String)] {
        var roots: [(SandboxWorkspaceRootKind, String)] = []
        try prepareAndExecute(
            "SELECT DISTINCT root_kind, root_id FROM file_change_entries",
            bind: { _ in },
            process: { stmt in
                var rc = sqlite3_step(stmt)
                while rc == SQLITE_ROW {
                    if let kind = SandboxWorkspaceRootKind(rawValue: String(cString: sqlite3_column_text(stmt, 0))) {
                        roots.append((kind, String(cString: sqlite3_column_text(stmt, 1))))
                    }
                    rc = sqlite3_step(stmt)
                }
                if rc != SQLITE_DONE {
                    throw FileHistoryDatabaseError.failedToExecute(
                        "file_change_entries root scan stopped early (sqlite \(rc))")
                }
            }
        )
        return roots.map { (kind: $0.0, rootId: $0.1) }
    }

    /// All sets, oldest first (retention). Minimal columns.
    public func fileChangeSetIndex() -> [(id: UUID, sessionId: String, createdAt: Date)] {
        var rows: [(UUID, String, Date)] = []
        try? prepareAndExecute(
            "SELECT id, session_id, created_at FROM file_change_sets ORDER BY created_at ASC",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))
                    else { continue }
                    rows.append(
                        (
                            id, String(cString: sqlite3_column_text(stmt, 1)),
                            Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                        ))
                }
            }
        )
        return rows.map { (id: $0.0, sessionId: $0.1, createdAt: $0.2) }
    }

    // MARK: - Row codec

    typealias Query = (
        _ sql: String, _ bind: (OpaquePointer) -> Void, _ process: (OpaquePointer) throws -> Void
    ) throws -> Void

    /// Reads a session's sets and entries through `query`. Shared with the
    /// chat-history database, which reads the same tables for the one-time copy.
    static func readSets(sessionId: String, query: Query) throws -> [FileChangeSet] {
        var sets: [FileChangeSet] = []
        var index: [UUID: Int] = [:]
        try query(
            """
            SELECT id, session_id, tool_name, tool_call_id, turn_id, origin, status,
                   reverts_set_id, note, created_at
            FROM file_change_sets WHERE session_id = ?1 ORDER BY created_at ASC
            """,
            { stmt in bindText(stmt, index: 1, value: sessionId) },
            { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard
                        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
                        let origin = FileChangeOrigin(rawValue: String(cString: sqlite3_column_text(stmt, 5))),
                        let status = FileChangeSetStatus(rawValue: String(cString: sqlite3_column_text(stmt, 6)))
                    else { continue }
                    index[id] = sets.count
                    sets.append(
                        FileChangeSet(
                            id: id,
                            sessionId: String(cString: sqlite3_column_text(stmt, 1)),
                            toolName: String(cString: sqlite3_column_text(stmt, 2)),
                            toolCallId: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                            turnId: sqlite3_column_text(stmt, 4).flatMap { UUID(uuidString: String(cString: $0)) },
                            origin: origin,
                            status: status,
                            revertsSetId: sqlite3_column_text(stmt, 7).flatMap {
                                UUID(uuidString: String(cString: $0))
                            },
                            note: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                        )
                    )
                }
            }
        )
        try query(
            """
            SELECT id, set_id, session_id, ordinal, root_kind, root_id, path, from_path,
                   kind, state, before_type, before_sig, before_mode, before_size,
                   after_type, after_sig, after_mode, after_size
            FROM file_change_entries WHERE session_id = ?1 ORDER BY ordinal ASC
            """,
            { stmt in bindText(stmt, index: 1, value: sessionId) },
            { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard
                        let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
                        let setId = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1))),
                        let setIndex = index[setId],
                        let rootKind = SandboxWorkspaceRootKind(rawValue: String(cString: sqlite3_column_text(stmt, 4))),
                        let kind = FileChangeEntryKind(rawValue: String(cString: sqlite3_column_text(stmt, 8))),
                        let state = FileChangeEntryState(rawValue: String(cString: sqlite3_column_text(stmt, 9)))
                    else { continue }
                    sets[setIndex].entries.append(
                        FileChangeEntry(
                            id: id,
                            setId: setId,
                            sessionId: String(cString: sqlite3_column_text(stmt, 2)),
                            rootKind: rootKind,
                            rootId: String(cString: sqlite3_column_text(stmt, 5)),
                            path: String(cString: sqlite3_column_text(stmt, 6)),
                            fromPath: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                            kind: kind,
                            before: readPathState(stmt, startIndex: 10),
                            after: readPathState(stmt, startIndex: 14),
                            state: state,
                            ordinal: Int(sqlite3_column_int64(stmt, 3))
                        )
                    )
                }
            }
        )
        return sets
    }

    private static func bindPathState(_ stmt: OpaquePointer, startIndex: Int, state: FilePathState?) {
        bindText(stmt, index: startIndex, value: state?.type.rawValue)
        bindText(stmt, index: startIndex + 1, value: state?.signature)
        if let mode = state?.mode {
            sqlite3_bind_int64(stmt, Int32(startIndex + 2), Int64(mode))
        } else {
            sqlite3_bind_null(stmt, Int32(startIndex + 2))
        }
        if let size = state?.size {
            sqlite3_bind_int64(stmt, Int32(startIndex + 3), size)
        } else {
            sqlite3_bind_null(stmt, Int32(startIndex + 3))
        }
    }

    private static func readPathState(_ stmt: OpaquePointer, startIndex: Int32) -> FilePathState? {
        guard let typeText = sqlite3_column_text(stmt, startIndex),
            let type = SandboxChangeEntryType(rawValue: String(cString: typeText)),
            let sigText = sqlite3_column_text(stmt, startIndex + 1)
        else { return nil }
        let mode: Int? =
            sqlite3_column_type(stmt, startIndex + 2) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(stmt, startIndex + 2))
        return FilePathState(
            type: type,
            signature: String(cString: sigText),
            mode: mode,
            size: sqlite3_column_int64(stmt, startIndex + 3)
        )
    }

    // MARK: - SQLite helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, Int32(index), value, Int32(value.utf8.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    #if DEBUG
        func executeForTesting(_ sql: String) throws {
            try queue.sync { try executeRaw(sql) }
        }
    #endif

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw FileHistoryDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw FileHistoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw FileHistoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw FileHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
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
            guard let connection = db else { throw FileHistoryDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw FileHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(s) }
            bind(s)
            try process(s)
        }
    }

    private func inTransaction(_ operation: () throws -> Void) throws {
        try queue.sync {
            guard db != nil else { throw FileHistoryDatabaseError.notOpen }
            try executeRaw("BEGIN TRANSACTION")
            do {
                try operation()
                try executeRaw("COMMIT")
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
            throw FileHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw FileHistoryDatabaseError.failedToExecute("step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
