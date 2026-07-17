//
//  PalaceDatabase.swift
//  osaurus
//
//  SQLite database for the Palace verbatim-memory subsystem.
//  WAL mode, serial queue, versioned migrations — same discipline as
//  MemoryDatabase / RouterBillingDatabase.
//
//  Schema v1:
//    palace_wings       — taxonomy: top-level scopes (project/person/agent/system)
//    palace_rooms       — taxonomy: (wing, name)-unique subdivisions
//    palace_drawers     — verbatim text chunks; content stored exactly as given
//    palace_embeddings  — one vector per drawer (Float32 LE blob), upserted
//    fts_palace_drawers — FTS5 external-content mirror of drawer content
//
//  KG tables arrive in Phase 1 (v2); tunnels in Phase 2 (v3). See
//  docs/plans/palace-implementation-plan.md.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

/// SQLITE_TRANSIENT: tells SQLite to make its own copy of bound data.
private let palaceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum PalaceDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case databaseFromNewerVersion(found: Int, expected: Int)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open palace database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Palace migration failed: \(msg)"
        case .databaseFromNewerVersion(let found, let expected):
            return
                "Palace database is schema v\(found) but this build supports up to v\(expected). "
                + "Refusing to open to avoid forward-version corruption."
        case .notOpen: return "Palace database is not open"
        }
    }
}

public final class PalaceDatabase: @unchecked Sendable {
    public static let shared = PalaceDatabase()

    /// Highest schema version this build knows how to produce. Opening a DB
    /// stamped newer than this is refused (forward-version fail-fast).
    private static let latestSchemaVersion = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.palace.database")

    /// Path this instance was last opened at (guarded by `queue`). The
    /// maintenance reopener reuses it so a database opened at an explicit
    /// path (tests) is never silently reopened at the production path.
    private var openedPath: String?

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        try open(atPath: OsaurusPaths.palaceDatabaseFile().path)
    }

    /// Open at an explicit path. Production callers use `open()`; tests use
    /// a temp path to exercise the on-disk open flow.
    func open(atPath path: String) throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale — every
        // `*Database.open()` parks while a key rotation is in flight so we
        // can't open a half-rekeyed file.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(
                URL(fileURLWithPath: path).deletingLastPathComponent()
            )
            do {
                db = try OsaurusStorageOpener.open(path: path)
            } catch let error as EncryptedSQLiteError {
                throw PalaceDatabaseError.failedToOpen(error.localizedDescription)
            }
            do {
                try runMigrations()
            } catch {
                // Close the half-opened connection before rethrowing —
                // leaving `db` set turns every retry of `open()` into an
                // instant no-op success against the unmigrated schema
                // (the MemoryDatabase.open() lesson).
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                throw error
            }
            openedPath = path
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "palace",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in
            guard let self else { return }
            let path = self.queue.sync { self.openedPath }
            try? self.open(atPath: path ?? OsaurusPaths.palaceDatabaseFile().path)
        }
    )

    /// Open an in-memory database for testing. **Plaintext.**
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
        OsaurusDatabaseHandle.deregister(name: "palace")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        guard currentVersion <= Self.latestSchemaVersion else {
            throw PalaceDatabaseError.databaseFromNewerVersion(
                found: currentVersion,
                expected: Self.latestSchemaVersion
            )
        }
        if currentVersion < 1 {
            try runMigrationStep(1, migrateToV1)
        }
    }

    /// Run one migration body atomically. Called only from `runMigrations`,
    /// which already holds the database queue, so it uses raw
    /// `BEGIN/COMMIT/ROLLBACK` (no nested `queue.sync`).
    private func runMigrationStep(_ version: Int, _ body: () throws -> Void) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            try body()
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw PalaceDatabaseError.migrationFailed("v\(version): \(error.localizedDescription)")
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

    /// Test hook: stamp an arbitrary schema version so forward-version
    /// refusal can be exercised.
    func debugSetSchemaVersion(_ version: Int) throws {
        try queue.sync { try setSchemaVersion(version) }
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_wings (
                    id            TEXT PRIMARY KEY,
                    name          TEXT NOT NULL UNIQUE,
                    display_name  TEXT,
                    kind          TEXT NOT NULL DEFAULT 'project',
                    agent_id      TEXT,
                    created_at    TEXT NOT NULL,
                    updated_at    TEXT NOT NULL
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_rooms (
                    id       TEXT PRIMARY KEY,
                    wing_id  TEXT NOT NULL REFERENCES palace_wings(id),
                    name     TEXT NOT NULL,
                    UNIQUE(wing_id, name)
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_drawers (
                    id                 TEXT PRIMARY KEY,
                    wing_id            TEXT NOT NULL,
                    room_id            TEXT NOT NULL,
                    content            TEXT NOT NULL,
                    blob_ref           TEXT,
                    source_file        TEXT,
                    source_line_start  INTEGER,
                    source_line_end    INTEGER,
                    added_by           TEXT NOT NULL DEFAULT 'system',
                    content_hash       TEXT NOT NULL,
                    char_offset        INTEGER,
                    created_at         TEXT NOT NULL,
                    metadata_json      TEXT,
                    -- Dedup invariant is DB-enforced, not just app-level: the
                    -- verbatim-drawer contract is "one row per exact content
                    -- within a (wing, room)". Matches the UNIQUE on wings/rooms
                    -- so the write path can't double-insert under a future
                    -- refactor that adds a suspension point between the
                    -- app-level check and the insert.
                    UNIQUE(wing_id, room_id, content_hash)
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_palace_drawers_wing_room ON palace_drawers(wing_id, room_id)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_palace_drawers_hash ON palace_drawers(content_hash)"
        )

        // One vector per drawer. Float32 little-endian blob; `dims` is
        // denormalized so a model change is detectable per row.
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS palace_embeddings (
                    drawer_id  TEXT PRIMARY KEY,
                    dims       INTEGER NOT NULL,
                    model      TEXT NOT NULL,
                    vector     BLOB NOT NULL
                )
            """
        )

        // FTS5 external-content mirror + sync triggers — same pattern as
        // MemoryDatabase.migrateToV6 (fts_pinned). SQLCipher transparently
        // encrypts the FTS5 shadow tables when the DB is encrypted.
        try executeRaw(
            """
                CREATE VIRTUAL TABLE IF NOT EXISTS fts_palace_drawers USING fts5(
                    content,
                    content='palace_drawers',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_ai AFTER INSERT ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(rowid, content) VALUES (new.rowid, new.content);
                END
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_ad AFTER DELETE ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(fts_palace_drawers, rowid, content)
                    VALUES('delete', old.rowid, old.content);
                END
            """
        )
        try executeRaw(
            """
                CREATE TRIGGER IF NOT EXISTS palace_drawers_au AFTER UPDATE ON palace_drawers BEGIN
                    INSERT INTO fts_palace_drawers(fts_palace_drawers, rowid, content)
                    VALUES('delete', old.rowid, old.content);
                    INSERT INTO fts_palace_drawers(rowid, content) VALUES (new.rowid, new.content);
                END
            """
        )

        try setSchemaVersion(1)
    }

    // MARK: - Hashing

    /// SHA256 hex of the exact content string (UTF-8). Dedup key.
    public static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wings

    @discardableResult
    public func ensureWing(name: String, kind: String = "project", agentId: String? = nil) throws
        -> PalaceWing
    {
        if let existing = try getWing(name: name) { return existing }
        let now = Self.iso8601Now()
        let wing = PalaceWing(
            name: name,
            kind: kind,
            agentId: agentId,
            createdAt: now,
            updatedAt: now
        )
        try executeUpdate(
            """
            INSERT INTO palace_wings (id, name, display_name, kind, agent_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(name) DO NOTHING
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: wing.id)
            Self.bindText(stmt, index: 2, value: wing.name)
            Self.bindText(stmt, index: 3, value: wing.displayName)
            Self.bindText(stmt, index: 4, value: wing.kind)
            Self.bindText(stmt, index: 5, value: wing.agentId)
            Self.bindText(stmt, index: 6, value: wing.createdAt)
            Self.bindText(stmt, index: 7, value: wing.updatedAt)
        }
        // Re-read: the ON CONFLICT path means another writer may own the row.
        guard let row = try getWing(name: name) else {
            throw PalaceDatabaseError.failedToExecute("ensureWing(\(name)) inserted no row")
        }
        return row
    }

    public func getWing(name: String) throws -> PalaceWing? {
        var wing: PalaceWing?
        try prepareAndExecute(
            "SELECT id, name, display_name, kind, agent_id, created_at, updated_at FROM palace_wings WHERE name = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: name) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    wing = Self.wingFromRow(stmt)
                }
            }
        )
        return wing
    }

    public func listWings() throws -> [PalaceWing] {
        var wings: [PalaceWing] = []
        try prepareAndExecute(
            "SELECT id, name, display_name, kind, agent_id, created_at, updated_at FROM palace_wings ORDER BY name",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    wings.append(Self.wingFromRow(stmt))
                }
            }
        )
        return wings
    }

    private static func wingFromRow(_ stmt: OpaquePointer) -> PalaceWing {
        PalaceWing(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            displayName: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            kind: String(cString: sqlite3_column_text(stmt, 3)),
            agentId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            createdAt: String(cString: sqlite3_column_text(stmt, 5)),
            updatedAt: String(cString: sqlite3_column_text(stmt, 6))
        )
    }

    // MARK: - Rooms

    @discardableResult
    public func ensureRoom(wingId: String, name: String) throws -> PalaceRoom {
        if let existing = try getRoom(wingId: wingId, name: name) { return existing }
        let room = PalaceRoom(wingId: wingId, name: name)
        try executeUpdate(
            """
            INSERT INTO palace_rooms (id, wing_id, name) VALUES (?1, ?2, ?3)
            ON CONFLICT(wing_id, name) DO NOTHING
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: room.id)
            Self.bindText(stmt, index: 2, value: room.wingId)
            Self.bindText(stmt, index: 3, value: room.name)
        }
        guard let row = try getRoom(wingId: wingId, name: name) else {
            throw PalaceDatabaseError.failedToExecute("ensureRoom(\(name)) inserted no row")
        }
        return row
    }

    public func getRoom(wingId: String, name: String) throws -> PalaceRoom? {
        var room: PalaceRoom?
        try prepareAndExecute(
            "SELECT id, wing_id, name FROM palace_rooms WHERE wing_id = ?1 AND name = ?2",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: wingId)
                Self.bindText(stmt, index: 2, value: name)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    room = Self.roomFromRow(stmt)
                }
            }
        )
        return room
    }

    public func listRooms(wingId: String) throws -> [PalaceRoom] {
        var rooms: [PalaceRoom] = []
        try prepareAndExecute(
            "SELECT id, wing_id, name FROM palace_rooms WHERE wing_id = ?1 ORDER BY name",
            bind: { stmt in Self.bindText(stmt, index: 1, value: wingId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rooms.append(Self.roomFromRow(stmt))
                }
            }
        )
        return rooms
    }

    private static func roomFromRow(_ stmt: OpaquePointer) -> PalaceRoom {
        PalaceRoom(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            wingId: String(cString: sqlite3_column_text(stmt, 1)),
            name: String(cString: sqlite3_column_text(stmt, 2))
        )
    }

    // MARK: - Drawers

    private static let drawerColumns =
        "id, wing_id, room_id, content, blob_ref, source_file, source_line_start, "
        + "source_line_end, added_by, content_hash, char_offset, created_at, metadata_json"

    /// Same column list qualified with the `d.` alias for FTS joins —
    /// FTS5 joins require table-qualified columns.
    private static let drawerColumnsQualified =
        drawerColumns
        .split(separator: ",")
        .map { "d.\($0.trimmingCharacters(in: .whitespaces))" }
        .joined(separator: ", ")

    /// Insert a drawer. Returns `true` when a row was written, `false` when
    /// it collided with the `UNIQUE(wing_id, room_id, content_hash)`
    /// invariant (an identical drawer already exists — `ON CONFLICT DO
    /// NOTHING` no-ops, and the FTS trigger only fires on a real insert, so
    /// the mirror stays consistent). Callers that pre-checked with
    /// `findDrawer` treat a `false` here as "lost a race, re-fetch the
    /// winner".
    @discardableResult
    public func insertDrawer(_ drawer: PalaceDrawer) throws -> Bool {
        let changes = try executeUpdateCountingChanges(
            """
            INSERT INTO palace_drawers
                (id, wing_id, room_id, content, blob_ref, source_file,
                 source_line_start, source_line_end, added_by, content_hash,
                 char_offset, created_at, metadata_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(wing_id, room_id, content_hash) DO NOTHING
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: drawer.id)
            Self.bindText(stmt, index: 2, value: drawer.wingId)
            Self.bindText(stmt, index: 3, value: drawer.roomId)
            Self.bindText(stmt, index: 4, value: drawer.content)
            Self.bindText(stmt, index: 5, value: drawer.blobRef)
            Self.bindText(stmt, index: 6, value: drawer.sourceFile)
            Self.bindInt(stmt, index: 7, value: drawer.sourceLineStart)
            Self.bindInt(stmt, index: 8, value: drawer.sourceLineEnd)
            Self.bindText(stmt, index: 9, value: drawer.addedBy)
            Self.bindText(stmt, index: 10, value: drawer.contentHash)
            Self.bindInt(stmt, index: 11, value: drawer.charOffset)
            Self.bindText(stmt, index: 12, value: drawer.createdAt)
            Self.bindText(stmt, index: 13, value: drawer.metadataJSON)
        }
        return changes > 0
    }

    public func getDrawer(id: String) throws -> PalaceDrawer? {
        var drawer: PalaceDrawer?
        try prepareAndExecute(
            "SELECT \(Self.drawerColumns) FROM palace_drawers WHERE id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    drawer = Self.drawerFromRow(stmt)
                }
            }
        )
        return drawer
    }

    public func findDrawer(wingId: String, roomId: String, contentHash: String) throws
        -> PalaceDrawer?
    {
        var drawer: PalaceDrawer?
        try prepareAndExecute(
            "SELECT \(Self.drawerColumns) FROM palace_drawers "
                + "WHERE wing_id = ?1 AND room_id = ?2 AND content_hash = ?3 LIMIT 1",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: wingId)
                Self.bindText(stmt, index: 2, value: roomId)
                Self.bindText(stmt, index: 3, value: contentHash)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    drawer = Self.drawerFromRow(stmt)
                }
            }
        )
        return drawer
    }

    public func listDrawers(wingId: String?, roomId: String?, limit: Int, offset: Int) throws
        -> [PalaceDrawer]
    {
        var sql = "SELECT \(Self.drawerColumns) FROM palace_drawers"
        var conditions: [String] = []
        if wingId != nil { conditions.append("wing_id = ?1") }
        if roomId != nil { conditions.append("room_id = ?2") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC, rowid DESC LIMIT ?3 OFFSET ?4"

        var drawers: [PalaceDrawer] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let wingId { Self.bindText(stmt, index: 1, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 2, value: roomId) }
                sqlite3_bind_int(stmt, 3, Int32(max(1, min(limit, 500))))
                // int64: `Int32(_: Int)` TRAPS on values > Int32.max, and
                // offset is model-controlled (a hallucinated pagination
                // value must not crash the app).
                sqlite3_bind_int64(stmt, 4, Int64(max(0, offset)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    drawers.append(Self.drawerFromRow(stmt))
                }
            }
        )
        return drawers
    }

    /// Replace a drawer's content (and hash). Returns false when no row
    /// matched. The FTS mirror follows via the `au` trigger.
    @discardableResult
    public func updateDrawerContent(id: String, content: String) throws -> Bool {
        let changes = try executeUpdateCountingChanges(
            "UPDATE palace_drawers SET content = ?1, content_hash = ?2 WHERE id = ?3"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: content)
            Self.bindText(stmt, index: 2, value: Self.contentHash(content))
            Self.bindText(stmt, index: 3, value: id)
        }
        return changes > 0
    }

    /// Delete a drawer and its embedding row atomically. Returns false when
    /// no drawer matched. The FTS mirror follows via the `ad` trigger.
    @discardableResult
    public func deleteDrawer(id: String) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            guard let connection = db else { throw PalaceDatabaseError.notOpen }
            try Self.exec(connection, "BEGIN TRANSACTION")
            do {
                try Self.step(
                    connection,
                    "DELETE FROM palace_drawers WHERE id = ?1"
                ) { stmt in
                    Self.bindText(stmt, index: 1, value: id)
                }
                let changed = sqlite3_changes(connection) > 0
                try Self.step(
                    connection,
                    "DELETE FROM palace_embeddings WHERE drawer_id = ?1"
                ) { stmt in
                    Self.bindText(stmt, index: 1, value: id)
                }
                try Self.exec(connection, "COMMIT")
                return changed
            } catch {
                try? Self.exec(connection, "ROLLBACK")
                throw error
            }
        }
    }

    private static func drawerFromRow(_ stmt: OpaquePointer) -> PalaceDrawer {
        PalaceDrawer(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            wingId: String(cString: sqlite3_column_text(stmt, 1)),
            roomId: String(cString: sqlite3_column_text(stmt, 2)),
            content: String(cString: sqlite3_column_text(stmt, 3)),
            blobRef: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            sourceFile: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            sourceLineStart: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 6)),
            sourceLineEnd: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 7)),
            addedBy: String(cString: sqlite3_column_text(stmt, 8)),
            contentHash: String(cString: sqlite3_column_text(stmt, 9)),
            charOffset: sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 10)),
            createdAt: String(cString: sqlite3_column_text(stmt, 11)),
            metadataJSON: sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        )
    }

    // MARK: - FTS search

    public struct FTSHit: Sendable {
        public let drawer: PalaceDrawer
        /// bm25() rank — LOWER is better (SQLite convention). Callers
        /// convert to a "higher is better" score.
        public let rank: Double
    }

    /// FTS5 MATCH over drawer content, optionally scoped. The raw query is
    /// sanitized to a quoted-token AND query so user input can never be
    /// parsed as FTS5 syntax.
    public func ftsSearch(query: String, wingId: String?, roomId: String?, limit: Int) throws
        -> [FTSHit]
    {
        let match = Self.ftsQuote(query)
        guard !match.isEmpty else { return [] }

        var sql = """
            SELECT \(Self.drawerColumnsQualified), bm25(fts_palace_drawers) AS rank
            FROM fts_palace_drawers f
            JOIN palace_drawers d ON d.rowid = f.rowid
            WHERE fts_palace_drawers MATCH ?1
            """
        if wingId != nil { sql += " AND d.wing_id = ?2" }
        if roomId != nil { sql += " AND d.room_id = ?3" }
        sql += " ORDER BY rank LIMIT ?4"

        var hits: [FTSHit] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: match)
                if let wingId { Self.bindText(stmt, index: 2, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 3, value: roomId) }
                sqlite3_bind_int(stmt, 4, Int32(max(1, min(limit, 100))))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    hits.append(
                        FTSHit(
                            drawer: Self.drawerFromRow(stmt),
                            rank: sqlite3_column_double(stmt, 13)
                        )
                    )
                }
            }
        )
        return hits
    }

    /// Convert free text to a safe FTS5 query — the exact
    /// `MemoryDatabase.ftsMatchQuery` sanitization: scrub to
    /// alphanumerics/whitespace/-/_, then double-quote every token
    /// (implicit AND). Prevents user input from being parsed as FTS5
    /// operators. Empty result → caller returns no hits.
    static func ftsQuote(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(query.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return
            scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }

    // MARK: - Embeddings

    public struct EmbeddingRow: Sendable {
        public let drawerId: String
        public let model: String
        public let vector: [Float]

        public init(drawerId: String, model: String, vector: [Float]) {
            self.drawerId = drawerId
            self.model = model
            self.vector = vector
        }
    }

    public func storeEmbedding(drawerId: String, vector: [Float], model: String) throws {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try executeUpdate(
            """
            INSERT INTO palace_embeddings (drawer_id, dims, model, vector)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(drawer_id) DO UPDATE SET
                dims = excluded.dims, model = excluded.model, vector = excluded.vector
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: drawerId)
            sqlite3_bind_int(stmt, 2, Int32(vector.count))
            Self.bindText(stmt, index: 3, value: model)
            blob.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(
                    stmt,
                    4,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    palaceSQLiteTransient
                )
            }
        }
    }

    /// Remove a drawer's vector. Used when content changes and re-embedding
    /// fails — a stale vector of the OLD content must not keep answering
    /// semantic queries for meaning the drawer no longer has.
    public func deleteEmbedding(drawerId: String) throws {
        try executeUpdate("DELETE FROM palace_embeddings WHERE drawer_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: drawerId)
        }
    }

    /// Load embeddings, optionally scoped to a wing/room via a join on
    /// palace_drawers. Vector blobs decode as Float32 little-endian; rows
    /// whose blob length disagrees with `dims` are skipped.
    public func loadEmbeddings(wingId: String?, roomId: String?) throws -> [EmbeddingRow] {
        var sql = """
            SELECT e.drawer_id, e.model, e.vector, e.dims
            FROM palace_embeddings e
            JOIN palace_drawers d ON d.id = e.drawer_id
            """
        var conditions: [String] = []
        if wingId != nil { conditions.append("d.wing_id = ?1") }
        if roomId != nil { conditions.append("d.room_id = ?2") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }

        var rows: [EmbeddingRow] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let wingId { Self.bindText(stmt, index: 1, value: wingId) }
                if let roomId { Self.bindText(stmt, index: 2, value: roomId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let drawerId = String(cString: sqlite3_column_text(stmt, 0))
                    let model = String(cString: sqlite3_column_text(stmt, 1))
                    let dims = Int(sqlite3_column_int(stmt, 3))
                    guard let blobPtr = sqlite3_column_blob(stmt, 2) else { continue }
                    let blobLen = Int(sqlite3_column_bytes(stmt, 2))
                    guard blobLen == dims * MemoryLayout<Float>.size else { continue }
                    let vector = Data(bytes: blobPtr, count: blobLen).withUnsafeBytes {
                        Array($0.bindMemory(to: Float.self))
                    }
                    rows.append(EmbeddingRow(drawerId: drawerId, model: model, vector: vector))
                }
            }
        )
        return rows
    }

    // MARK: - Counts

    public func countWings() throws -> Int { try count("SELECT COUNT(*) FROM palace_wings") }
    public func countRooms() throws -> Int { try count("SELECT COUNT(*) FROM palace_rooms") }
    public func countDrawers() throws -> Int { try count("SELECT COUNT(*) FROM palace_drawers") }
    public func countEmbeddedDrawers() throws -> Int {
        try count("SELECT COUNT(*) FROM palace_embeddings")
    }

    private func count(_ sql: String) throws -> Int {
        var n = 0
        try prepareAndExecute(
            sql,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    n = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return n
    }

    // MARK: - Query plumbing (mirrors MemoryDatabase)

    /// Must be called on `queue`.
    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw PalaceDatabaseError.notOpen }
        try Self.exec(connection, sql)
    }

    /// Must be called on `queue`.
    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw PalaceDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt
        else {
            throw PalaceDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    /// Locking prepare/bind/process. MUST NOT be called from a closure that
    /// already holds `queue` — the dispatchPrecondition surfaces the
    /// re-entrant-sync deadlock at the call site.
    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw PalaceDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK,
                let statement = stmt
            else {
                throw PalaceDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    /// Locking write helper. Throws on any step result other than
    /// SQLITE_DONE (extended error code + SQL prefix in the message so
    /// constraint failures are attributable).
    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepareAndExecute(
            sql,
            bind: bind,
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    let connection = sqlite3_db_handle(stmt)
                    let extended = connection.map { sqlite3_extended_errcode($0) } ?? 0
                    let msg = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
                    throw PalaceDatabaseError.failedToExecute(
                        "step=\(step) extended=\(extended) msg=\(msg) sql=\(sql.prefix(120))"
                    )
                }
            }
        )
    }

    /// Like `executeUpdate`, but returns `sqlite3_changes` from the same
    /// queue-held connection so the count can't race a concurrent write.
    private func executeUpdateCountingChanges(_ sql: String, bind: (OpaquePointer) -> Void) throws
        -> Int
    {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            guard let connection = db else { throw PalaceDatabaseError.notOpen }
            try Self.step(connection, sql, bind: bind)
            return Int(sqlite3_changes(connection))
        }
    }

    // MARK: - Static single-statement helpers (caller holds `queue`)

    private static func exec(_ connection: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw PalaceDatabaseError.failedToExecute(message)
        }
    }

    private static func step(
        _ connection: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt
        else {
            throw PalaceDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
            throw PalaceDatabaseError.failedToExecute(
                "step=\(step) msg=\(String(cString: sqlite3_errmsg(connection))) sql=\(sql.prefix(120))"
            )
        }
    }

    // MARK: - Binding helpers

    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, palaceSQLiteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bindInt(_ stmt: OpaquePointer, index: Int32, value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }
}
