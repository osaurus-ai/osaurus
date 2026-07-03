//
//  AgentDatabase.swift
//  osaurus
//
//  Per-agent SQLite database for the Agent DB feature (spec §3, §5).
//  One connection per agent, one file at
//  `~/.osaurus/agents/<id>/db.sqlite`. Encrypted via the same SQLCipher
//  + `StorageKeyManager` setup the rest of the storage layer uses.
//
//  Reserved system tables created on first open (spec §5):
//    - `_tables_meta`  — set of tables the agent has created + purpose
//    - `_changelog`    — append-only audit log of every mutation
//    - `_views`        — saved views authored by the agent
//
//  User-table conventions enforced by `createTable` (spec §5):
//    - Every user-created table gets `id INTEGER PRIMARY KEY` if the
//      agent doesn't specify one.
//    - Every table gets `_created_at`, `_updated_at`, `_deleted_at`.
//    - Soft delete is the default; `softDelete` writes `_deleted_at`.
//    - Triggers auto-update `_updated_at` on UPDATE.
//    - All `query()` calls auto-filter `_deleted_at IS NULL` unless the
//      caller passes `includeDeleted = true`.
//
//  Concurrency: one serial queue per `AgentDatabase`. The
//  `LocalAgentBridge` further serializes all mutations across this
//  agent's run + user-edit paths.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum AgentDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case notOpen
    case invalidArgument(String)
    case forbidden(String)
    case tableExists(String)
    case tableNotFound(String)
    /// Storage quota exceeded (spec §11.3). Carries the current file
    /// size and the configured limit so error messages can be specific.
    case storageQuotaExceeded(usedBytes: Int, limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open agent database: \(m)"
        case .failedToExecute(let m): return "Failed to execute agent query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare agent statement: \(m)"
        case .notOpen: return "Agent database is not open"
        case .invalidArgument(let m): return "Invalid argument: \(m)"
        case .forbidden(let m): return "Forbidden: \(m)"
        case .tableExists(let m): return "Table already exists: \(m)"
        case .tableNotFound(let m): return "Table not found: \(m)"
        case .storageQuotaExceeded(let used, let limit):
            return
                "Storage quota exceeded: \(used) bytes used of \(limit) byte limit. "
                + "Delete rows, drop unused tables, or raise the limit in Agent settings."
        }
    }
}

// MARK: - Domain types

/// Who performed the mutation. Stamped on every `_changelog` row.
public enum AgentDatabaseActor: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case migration
    case system
}

/// Operation kind, written to `_changelog.op`.
public enum AgentDatabaseOp: String, Codable, Sendable, CaseIterable {
    case insert
    case update
    case softDelete = "soft_delete"
    case restore
    case schema
    case raw
    /// A host-mediated bulk load (`db_import`). One `_changelog` row is
    /// written per committed chunk so the Activity surface can tell a
    /// bulk ingest apart from organic per-row agent writes.
    case bulkImport = "import"
}

/// Column declaration used by `createTable` and `alterTable`. SQLite is
/// dynamically typed; `type` is type affinity (TEXT, INTEGER, REAL, BLOB,
/// NUMERIC). We normalize to upper case.
public struct AgentColumnSpec: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var primaryKey: Bool

    public init(
        name: String,
        type: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        primaryKey: Bool = false
    ) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.primaryKey = primaryKey
    }
}

public struct AgentIndexSpec: Codable, Sendable, Equatable {
    public var name: String
    public var columns: [String]
    public var unique: Bool

    public init(name: String, columns: [String], unique: Bool = false) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }
}

public struct AgentColumnInfo: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var primaryKey: Bool

    public init(
        name: String,
        type: String,
        nullable: Bool,
        defaultValue: String?,
        primaryKey: Bool
    ) {
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.primaryKey = primaryKey
    }
}

public struct AgentIndexInfo: Codable, Sendable, Equatable {
    public var name: String
    public var columns: [String]
    public var unique: Bool

    public init(name: String, columns: [String], unique: Bool) {
        self.name = name
        self.columns = columns
        self.unique = unique
    }
}

public struct AgentTableSchema: Codable, Sendable, Equatable {
    public var name: String
    public var purpose: String
    public var columns: [AgentColumnInfo]
    public var indexes: [AgentIndexInfo]
    public var rowCount: Int
    public var lastWriteAt: Date?

    public init(
        name: String,
        purpose: String,
        columns: [AgentColumnInfo],
        indexes: [AgentIndexInfo],
        rowCount: Int,
        lastWriteAt: Date?
    ) {
        self.name = name
        self.purpose = purpose
        self.columns = columns
        self.indexes = indexes
        self.rowCount = rowCount
        self.lastWriteAt = lastWriteAt
    }
}

public struct AgentSavedView: Codable, Sendable, Equatable {
    public var name: String
    public var sql: String
    public var renderHint: String
    public var refresh: String
    public var description: String?
    /// Whether the user has pinned this view on the agent's Home tab
    /// (spec §5.7 / phase 2). Defaults to false so view-as-tool
    /// authoring doesn't auto-clutter the home dashboard.
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        sql: String,
        renderHint: String,
        refresh: String,
        description: String? = nil,
        pinned: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.name = name
        self.sql = sql
        self.renderHint = renderHint
        self.refresh = refresh
        self.description = description
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentDatabaseSchema: Codable, Sendable, Equatable {
    public var tables: [AgentTableSchema]
    public var views: [AgentSavedView]

    public init(tables: [AgentTableSchema], views: [AgentSavedView]) {
        self.tables = tables
        self.views = views
    }
}

/// A single value bound to a SQL parameter or returned from a query.
/// We pick this stricter alternative to `Any` so the JSON tool-bridge
/// can serialize results without surprises (an arbitrary `Any` could be
/// a SwiftUI view by accident).
public enum AgentSQLValue: Codable, Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case bool(Bool)

    /// Cheap conversion used when callers pass typed values from Swift.
    /// `nil` maps to `.null`.
    public init(_ value: Any?) {
        switch value {
        case nil: self = .null
        case let v as AgentSQLValue: self = v
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .integer(Int64(v))
        case let v as Int32: self = .integer(Int64(v))
        case let v as Int64: self = .integer(v)
        case let v as Double: self = .double(v)
        case let v as Float: self = .double(Double(v))
        case let v as String: self = .text(v)
        case let v as Data: self = .blob(v)
        default: self = .text(String(describing: value!))
        }
    }
}

public struct AgentQueryResult: Codable, Sendable, Equatable {
    public var columns: [String]
    public var rows: [[AgentSQLValue]]
    public var truncated: Bool

    public init(columns: [String], rows: [[AgentSQLValue]], truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }
}

public struct AgentExecuteResult: Codable, Sendable, Equatable {
    public var rowsAffected: Int
    public var warning: String?

    public init(rowsAffected: Int, warning: String? = nil) {
        self.rowsAffected = rowsAffected
        self.warning = warning
    }
}

// MARK: - AgentDatabase

public final class AgentDatabase: @unchecked Sendable {
    public let agentId: UUID

    private static let schemaVersion = 1
    /// Soft cap on rows returned by `query()`. The agent surface always
    /// surfaces `truncated: true` so callers can ask for more if needed.
    public static let queryRowCap = 1000

    /// Hard ceiling for a single `query` call when the caller asks for more
    /// than the default `queryRowCap` via an explicit `limit`. Paging past
    /// this is the caller's job (`limit`/`offset`); it bounds host memory
    /// and the eventual encoded tool-result size.
    public static let queryRowHardMax = 5000

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let stmtCache = PreparedStatementCache(capacity: 32)

    /// Path on disk. Stored eagerly so tests with `OsaurusPaths.overrideRoot`
    /// keep working even after the override is cleared.
    public let path: String

    /// Storage quota in bytes. `0` disables the check. Set by
    /// `AgentDatabaseStore` when it opens the DB; defaults to the value
    /// burned in at `AgentLimitsSettings.defaults.storageBytesLimit`
    /// so the check is on by default even before the store wires the
    /// agent's specific limit through. Mutations call
    /// `enforceStorageQuotaUnlocked` after the SQL commits.
    ///
    /// These three fields are read on the serial `queue` (inside
    /// `enforceStorageQuotaUnlocked`, which only runs from `inTransaction`)
    /// but were previously written directly from `AgentDatabaseStore`
    /// (off-queue, on the caller's thread) — a data race on plain
    /// `Int`/`Bool`. They are now `private` and confined to `queue`:
    /// mutate via `setStorageBytesLimit` / `setStorageWarnPercent` and
    /// read via `currentStorageBytesLimit()`.
    private var _storageBytesLimit: Int = AgentLimitsSettings.defaults.storageBytesLimit
    /// Soft-warn threshold as a percentage of `storageBytesLimit`.
    /// 0 disables the soft warning entirely. When the on-disk size
    /// crosses this threshold a one-shot edge-trigger fires the
    /// `.agentStorageWarn` notification (spec §11.2 / line 324).
    private var _storageWarnPercent: Int = AgentLimitsSettings.defaults.storageWarnPercent
    /// One-shot guard so we only emit the warning notification on
    /// the *transition* from below-threshold to at-or-above. Reset
    /// to `false` when usage drops back below the threshold (e.g.
    /// after the agent drops rows or the user wipes data).
    private var storageWarningActive: Bool = false

    /// Update the byte quota on the serial queue so the post-commit
    /// reader in `enforceStorageQuotaUnlocked` never observes a torn
    /// write. Async (fire-and-forget): the new value applies to the
    /// next mutation, matching the old "default applies until pushed"
    /// contract.
    public func setStorageBytesLimit(_ value: Int) {
        queue.async { self._storageBytesLimit = value }
    }

    /// Update the soft-warn percent on the serial queue. Same
    /// lifecycle as `setStorageBytesLimit`.
    public func setStorageWarnPercent(_ value: Int) {
        queue.async { self._storageWarnPercent = value }
    }

    /// Read the current byte quota, serialized on the queue so it
    /// can't tear against an in-flight `setStorageBytesLimit`.
    public func currentStorageBytesLimit() -> Int {
        queue.sync { _storageBytesLimit }
    }

    public init(agentId: UUID, path: String? = nil) {
        self.agentId = agentId
        self.path = path ?? OsaurusPaths.agentDatabaseFile(for: agentId).path
        // Label distinguishes per-agent queues in profiler traces.
        self.queue = DispatchQueue(label: "ai.osaurus.agentdb.\(agentId.uuidString)")
    }

    // MARK: - Storage quota

    /// Current size of the DB file on disk plus its WAL sidecar, if any.
    /// `0` for in-memory databases (path = `:memory:`). Read after each
    /// mutation to decide whether to refuse the next one.
    public func storageUsedBytes() -> Int {
        guard path != ":memory:" else { return 0 }
        let fm = FileManager.default
        let main = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        let walPath = path + "-wal"
        let wal = (try? fm.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.intValue ?? 0
        return main + wal
    }

    /// Throws `storageQuotaExceeded` if `storageBytesLimit > 0` and the
    /// current file size is past it. Cheap (one `stat()` per call) so
    /// every mutation calls it after the commit. Crucially we check
    /// AFTER the write, not before: a single oversize transaction can
    /// still land, but the *next* one will fail-loud and give the user
    /// (or the agent) a chance to free space.
    ///
    /// Also fires a one-shot `.agentStorageWarn` notification when the
    /// on-disk size crosses `storageWarnPercent` of the limit (spec
    /// §11.2 / line 324). The notification is rate-limited by the
    /// listener (`AgentManager`); this method only handles edge
    /// detection.
    fileprivate func enforceStorageQuotaUnlocked() throws {
        // Reads the queue-confined quota fields directly: this method only
        // runs from `inTransaction` (inside `queue.sync`), so the values
        // can't tear against `setStorageBytesLimit`/`setStorageWarnPercent`.
        let limit = _storageBytesLimit
        guard limit > 0 else { return }
        let used = storageUsedBytes()
        // Soft warn — edge-trigger: only fire when we *transition*
        // from below the threshold to at-or-above. Sliding back
        // below resets the latch so a later spike re-warns.
        let warnPercent = _storageWarnPercent
        if warnPercent > 0 {
            let softLimit = (limit / 100) * warnPercent
            let isAbove = used >= softLimit
            if isAbove && !storageWarningActive {
                storageWarningActive = true
                let pct = used * 100 / max(1, limit)
                NotificationCenter.default.post(
                    name: .agentStorageWarn,
                    object: nil,
                    userInfo: [
                        "agentId": agentId,
                        "usedBytes": used,
                        "limitBytes": limit,
                        "percent": pct,
                    ]
                )
            } else if !isAbove && storageWarningActive {
                storageWarningActive = false
            }
        }
        if used > limit {
            throw AgentDatabaseError.storageQuotaExceeded(
                usedBytes: used,
                limitBytes: limit
            )
        }
    }

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentDirectory(for: agentId))
            try openConnection()
            try runMigrations()
        }
    }

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
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    private func openConnection() throws {
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw AgentDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - System tables / migrations

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        if current < 1 { try migrateToV1() }
    }

    private func getSchemaVersion() throws -> Int {
        var v = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                v = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return v
    }

    private func setSchemaVersion(_ v: Int) throws {
        try executeRaw("PRAGMA user_version = \(v)")
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS _tables_meta (
                    table_name      TEXT PRIMARY KEY,
                    purpose         TEXT NOT NULL,
                    created_at      INTEGER NOT NULL,
                    created_in_run  TEXT
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS _changelog (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts            INTEGER NOT NULL,
                    run_id        TEXT,
                    actor         TEXT NOT NULL,
                    op            TEXT NOT NULL,
                    table_name    TEXT,
                    row_pk        TEXT,
                    before_json   TEXT,
                    after_json    TEXT,
                    sql           TEXT
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_changelog_ts ON _changelog(ts DESC)")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_changelog_run ON _changelog(run_id)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS _views (
                    name          TEXT PRIMARY KEY,
                    sql           TEXT NOT NULL,
                    render_hint   TEXT NOT NULL,
                    refresh       TEXT NOT NULL,
                    description   TEXT,
                    pinned        INTEGER NOT NULL DEFAULT 0,
                    created_at    INTEGER NOT NULL,
                    updated_at    INTEGER NOT NULL
                )
            """
        )

        try setSchemaVersion(1)
    }

    // MARK: - Public: schema

    /// Returns the structured schema for every user-owned table and view.
    /// System tables (`_tables_meta`, `_changelog`, `_views`) are excluded
    /// — they are an implementation detail of the agent's DB layer.
    public func schema() throws -> AgentDatabaseSchema {
        try queue.sync {
            guard db != nil else { throw AgentDatabaseError.notOpen }

            let tableNames = try listUserTablesUnlocked()
            var tables: [AgentTableSchema] = []
            for name in tableNames {
                let table = try schemaForTableUnlocked(name)
                tables.append(table)
            }

            let views = try listViewsUnlocked()
            return AgentDatabaseSchema(tables: tables, views: views)
        }
    }

    /// Convenience: schema for a single user table.
    public func schemaForTable(_ name: String) throws -> AgentTableSchema? {
        try queue.sync {
            guard db != nil else { throw AgentDatabaseError.notOpen }
            guard try existsUserTableUnlocked(name) else { return nil }
            return try schemaForTableUnlocked(name)
        }
    }

    // MARK: - Public: tables

    /// Create a new user table.
    ///
    /// Adds host-managed columns automatically:
    /// - `id INTEGER PRIMARY KEY AUTOINCREMENT` if no PK declared.
    /// - `_created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`.
    /// - `_updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`.
    /// - `_deleted_at INTEGER` (nullable, soft-delete marker).
    ///
    /// Also attaches an `AFTER UPDATE` trigger that refreshes `_updated_at`.
    @discardableResult
    public func createTable(
        name: String,
        purpose: String,
        columns: [AgentColumnSpec],
        indexes: [AgentIndexSpec] = [],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> String {
        try Self.validateIdentifier(name)
        try Self.requireNotReservedTable(name)
        guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDatabaseError.invalidArgument("createTable: purpose is required")
        }

        return try inTransaction { _ in
            if try self.existsUserTableUnlocked(name) {
                throw AgentDatabaseError.tableExists(name)
            }
            // Naming collision = hard error (spec §16). A user table
            // can't shadow a saved view name — the agent has to drop
            // the view first or pick a different table name.
            if try self.listViewsUnlocked().contains(where: { $0.name == name }) {
                throw AgentDatabaseError.tableExists(
                    "\(name) (saved view of the same name exists; drop it first or rename)"
                )
            }

            // A user-declared `id` column becomes the primary-key slot when
            // no explicit PK was marked. The host otherwise auto-adds
            // `id INTEGER PRIMARY KEY AUTOINCREMENT`, and blindly adding it
            // next to a declared `id TEXT` produced SQLite's raw
            // "duplicate column name: id" (observed live: a model declaring
            // string order-ids retried the identical failing call until the
            // budget ran out). Honoring the declared column preserves the
            // model's intent; SQLite still enforces single-PK rules.
            var columns = columns
            let hasPK = columns.contains(where: { $0.primaryKey })
            if !hasPK,
                let idIndex = columns.firstIndex(where: { $0.name.lowercased() == "id" })
            {
                let declared = columns[idIndex]
                columns[idIndex] = AgentColumnSpec(
                    name: declared.name,
                    type: declared.type,
                    nullable: declared.nullable,
                    defaultValue: declared.defaultValue,
                    primaryKey: true
                )
            }
            let hasExplicitOrPromotedPK = columns.contains(where: { $0.primaryKey })
            var defs: [String] = []

            if !hasExplicitOrPromotedPK {
                defs.append("id INTEGER PRIMARY KEY AUTOINCREMENT")
            }

            for col in columns {
                try Self.validateIdentifier(col.name)
                try Self.requireNotReservedColumn(col.name)
                var def = "\(col.name) \(Self.normalizeType(col.type))"
                if col.primaryKey {
                    def += " PRIMARY KEY"
                    if col.type.uppercased() == "INTEGER" {
                        // sqlite-only AUTOINCREMENT shorthand on integer PK.
                        def += " AUTOINCREMENT"
                    }
                }
                if !col.nullable && !col.primaryKey {
                    def += " NOT NULL"
                }
                if let dv = col.defaultValue {
                    def += " DEFAULT \(dv)"
                }
                defs.append(def)
            }

            // Host-managed timestamp columns. Always present even if the
            // agent forgot to ask for them.
            defs.append("_created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))")
            defs.append("_updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))")
            defs.append("_deleted_at INTEGER")

            let createSQL = "CREATE TABLE \(name) (\n    \(defs.joined(separator: ",\n    "))\n)"
            try self.executeRaw(createSQL)

            // Trigger to keep `_updated_at` fresh.
            let triggerSQL = """
                    CREATE TRIGGER \(name)__updated_at AFTER UPDATE ON \(name)
                    FOR EACH ROW
                    WHEN OLD._updated_at = NEW._updated_at
                    BEGIN
                        UPDATE \(name) SET _updated_at = strftime('%s','now')
                        WHERE rowid = NEW.rowid;
                    END
                """
            try self.executeRaw(triggerSQL)

            for idx in indexes {
                try Self.validateIdentifier(idx.name)
                for col in idx.columns { try Self.validateIdentifier(col) }
                let unique = idx.unique ? "UNIQUE " : ""
                let cols = idx.columns.joined(separator: ", ")
                try self.executeRaw(
                    "CREATE \(unique)INDEX \(idx.name) ON \(name) (\(cols))"
                )
            }

            // Record in `_tables_meta`.
            try self.transactionalStep(
                """
                INSERT INTO _tables_meta (table_name, purpose, created_at, created_in_run)
                VALUES (?1, ?2, strftime('%s','now'), ?3)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: name)
                Self.bindText(stmt, index: 2, value: purpose)
                Self.bindText(stmt, index: 3, value: runId?.uuidString)
            }

            // Audit.
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .schema,
                tableName: name,
                rowPK: nil,
                beforeJSON: nil,
                afterJSON: nil,
                sql: createSQL
            )

            return createSQL
        }
    }

    /// Add columns to a user table. Today we only expose `add` because
    /// SQLite's other ALTER variants need careful rebuild-with-temp-table
    /// dances (column rename / drop landed in 3.25/3.35 but interact
    /// awkwardly with triggers + indexes); the typed surface stays
    /// narrow and the `runMigration(...)` escape hatch covers the rest.
    /// Returns the applied SQL so the caller can persist a migration pair.
    @discardableResult
    public func alterTableAddColumns(
        name: String,
        additions: [AgentColumnSpec],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> [String] {
        try Self.validateIdentifier(name)
        try Self.requireNotReservedTable(name)
        guard !additions.isEmpty else {
            throw AgentDatabaseError.invalidArgument("alterTableAddColumns: no additions provided")
        }
        for col in additions {
            try Self.validateIdentifier(col.name)
            try Self.requireNotReservedColumn(col.name)
        }

        return try inTransaction { _ in
            guard try self.existsUserTableUnlocked(name) else {
                throw AgentDatabaseError.tableNotFound(name)
            }
            var applied: [String] = []
            for col in additions {
                var def = "\(col.name) \(Self.normalizeType(col.type))"
                if !col.nullable {
                    // SQLite rejects NOT NULL ADD COLUMN without a DEFAULT
                    // on a non-empty table (spec §16 Q5). If the caller
                    // didn't supply one, fall back to a type-appropriate
                    // value so the migration always applies cleanly.
                    if col.defaultValue == nil {
                        def += " NOT NULL DEFAULT \(Self.derivedDefault(forType: col.type))"
                    } else {
                        def += " NOT NULL"
                    }
                }
                if let dv = col.defaultValue {
                    def += " DEFAULT \(dv)"
                }
                let sql = "ALTER TABLE \(name) ADD COLUMN \(def)"
                try self.executeRaw(sql)
                applied.append(sql)

                try self.appendChangelogUnlocked(
                    runId: runId,
                    actor: actor,
                    op: .schema,
                    tableName: name,
                    rowPK: nil,
                    beforeJSON: nil,
                    afterJSON: nil,
                    sql: sql
                )
            }
            return applied
        }
    }

    /// Run a raw SQL migration inside a transaction. Used by the
    /// `db.migrate` escape hatch (spec §6.1). The caller provides the
    /// "down" SQL too so the host can persist a reversible pair (the
    /// down SQL is not executed here; it only goes into the migration
    /// file). Failure rolls back atomically — no partial state.
    public func runMigration(
        upSQL: String,
        downSQL: String,
        description: String,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws {
        guard !upSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDatabaseError.invalidArgument("runMigration: upSQL is empty")
        }
        guard !downSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDatabaseError.invalidArgument(
                "runMigration: downSQL is empty (use `--` if there's nothing to undo)"
            )
        }
        if let reason = Self.forbiddenReason(in: upSQL) {
            throw AgentDatabaseError.forbidden(reason)
        }
        try inTransaction { _ in
            try self.executeRaw(upSQL)
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .schema,
                tableName: nil,
                rowPK: nil,
                beforeJSON: nil,
                afterJSON: nil,
                sql: upSQL
            )
        }
        _ = description
    }

    /// Upsert one row keyed by `keyColumns`. SQLite's ON CONFLICT
    /// requires the key column set to map to a UNIQUE or PRIMARY KEY
    /// constraint; callers responsible for that.
    @discardableResult
    public func upsert(
        table: String,
        keyColumns: [String],
        row: [String: AgentSQLValue],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int64 {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        guard !keyColumns.isEmpty else {
            throw AgentDatabaseError.invalidArgument("upsert: keyColumns must not be empty")
        }
        guard !row.isEmpty else {
            throw AgentDatabaseError.invalidArgument("upsert: row must not be empty")
        }
        for key in row.keys {
            try Self.validateIdentifier(key)
            try Self.requireNotReservedColumn(key)
        }
        for key in keyColumns { try Self.validateIdentifier(key) }

        return try inTransaction { _ in
            let cols = Array(row.keys)
            let placeholders = (1 ... cols.count).map { "?\($0)" }.joined(separator: ", ")
            let setSQL =
                cols.filter { !keyColumns.contains($0) }
                .map { "\($0) = excluded.\($0)" }
                .joined(separator: ", ")
            let conflict = keyColumns.joined(separator: ", ")
            let sql: String
            if setSQL.isEmpty {
                sql = """
                        INSERT INTO \(table) (\(cols.joined(separator: ", ")))
                        VALUES (\(placeholders))
                        ON CONFLICT(\(conflict)) DO NOTHING
                    """
            } else {
                sql = """
                        INSERT INTO \(table) (\(cols.joined(separator: ", ")))
                        VALUES (\(placeholders))
                        ON CONFLICT(\(conflict)) DO UPDATE SET \(setSQL)
                    """
            }
            try self.transactionalStep(sql) { stmt in
                for (i, c) in cols.enumerated() {
                    Self.bind(stmt, index: i + 1, value: row[c] ?? .null)
                }
            }
            let rowid = sqlite3_last_insert_rowid(self.db)
            let afterJSON = Self.jsonEncode(row)
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .insert,
                tableName: table,
                rowPK: String(rowid),
                beforeJSON: nil,
                afterJSON: afterJSON,
                sql: nil
            )
            return rowid
        }
    }

    /// Drop a user table. The high-level `db.*` tool surface does NOT
    /// expose this (spec §6.1: "DROP TABLE is not exposed"); this exists
    /// for the migration runner / down-migration path which needs it.
    public func dropTableForMigration(
        name: String,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws {
        try Self.validateIdentifier(name)
        try Self.requireNotReservedTable(name)
        try inTransaction { _ in
            guard try self.existsUserTableUnlocked(name) else {
                throw AgentDatabaseError.tableNotFound(name)
            }
            try self.executeRaw("DROP TABLE \(name)")
            try self.transactionalStep(
                "DELETE FROM _tables_meta WHERE table_name = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: name)
            }
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .schema,
                tableName: name,
                rowPK: nil,
                beforeJSON: nil,
                afterJSON: nil,
                sql: "DROP TABLE \(name)"
            )
        }
    }

    // MARK: - Public: CRUD

    /// Insert one row into `table`. Host-managed columns
    /// (`_created_at`, `_updated_at`, `_deleted_at`, `id`) are not
    /// expected in `row` — SQLite fills in their defaults.
    @discardableResult
    public func insert(
        table: String,
        row: [String: AgentSQLValue],
        returningPK: String = "id",
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int64 {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        guard !row.isEmpty else {
            throw AgentDatabaseError.invalidArgument("insert: row must not be empty")
        }
        for key in row.keys {
            try Self.validateIdentifier(key)
            try Self.requireNotReservedColumn(key)
        }

        return try inTransaction { _ in
            let columns = Array(row.keys)
            let placeholders = (1 ... columns.count).map { "?\($0)" }.joined(separator: ", ")
            let cols = columns.joined(separator: ", ")
            let sql = "INSERT INTO \(table) (\(cols)) VALUES (\(placeholders))"
            try self.transactionalStep(sql) { stmt in
                for (i, c) in columns.enumerated() {
                    Self.bind(stmt, index: i + 1, value: row[c] ?? .null)
                }
            }
            let rowid = sqlite3_last_insert_rowid(self.db)

            let afterJSON = Self.jsonEncode(row)
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .insert,
                tableName: table,
                rowPK: String(rowid),
                beforeJSON: nil,
                afterJSON: afterJSON,
                sql: nil
            )
            return rowid
        }
    }

    /// Update rows matched by `where`. Returns the number of rows
    /// affected (after filtering soft-deleted ones unless
    /// `includeDeleted=true`).
    @discardableResult
    public func update(
        table: String,
        set: [String: AgentSQLValue],
        whereClause: [String: AgentSQLValue],
        includeDeleted: Bool = false,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        guard !set.isEmpty else {
            throw AgentDatabaseError.invalidArgument("update: `set` must not be empty")
        }
        for key in set.keys {
            try Self.validateIdentifier(key)
            try Self.requireNotReservedColumn(key)
        }
        for key in whereClause.keys { try Self.validateIdentifier(key) }

        return try inTransaction { _ in
            // Capture before-image for changelog.
            let beforeRows = try self.selectMatchingRowsUnlocked(
                table: table,
                whereClause: whereClause,
                includeDeleted: includeDeleted
            )

            let setCols = Array(set.keys)
            let whereCols = Array(whereClause.keys)
            let setSQL = setCols.enumerated().map { i, c in "\(c) = ?\(i + 1)" }.joined(separator: ", ")
            let whereSQL = whereCols.enumerated().map { i, c in
                "\(c) = ?\(setCols.count + i + 1)"
            }.joined(separator: " AND ")
            // Soft-delete filtering only applies to tables that actually
            // carry the column (raw-SQL-created tables don't).
            let hasSoftDelete = try self.tableHasColumnUnlocked(table, column: "_deleted_at")
            let softDeleteSQL = (includeDeleted || !hasSoftDelete) ? "" : " AND _deleted_at IS NULL"
            let sql = "UPDATE \(table) SET \(setSQL) WHERE \(whereSQL)\(softDeleteSQL)"

            try self.transactionalStep(sql) { stmt in
                for (i, c) in setCols.enumerated() {
                    Self.bind(stmt, index: i + 1, value: set[c] ?? .null)
                }
                for (i, c) in whereCols.enumerated() {
                    Self.bind(stmt, index: setCols.count + i + 1, value: whereClause[c] ?? .null)
                }
            }
            let affected = Int(sqlite3_changes(self.db))

            for row in beforeRows {
                var after = row
                for (k, v) in set { after[k] = v }
                let pk = Self.stringifyPK(row["id"] ?? row.first?.value)
                try self.appendChangelogUnlocked(
                    runId: runId,
                    actor: actor,
                    op: .update,
                    tableName: table,
                    rowPK: pk,
                    beforeJSON: Self.jsonEncode(row),
                    afterJSON: Self.jsonEncode(after),
                    sql: nil
                )
            }
            return affected
        }
    }

    /// Soft-delete: sets `_deleted_at`, doesn't actually remove the row.
    /// `restore` clears the column.
    @discardableResult
    public func softDelete(
        table: String,
        whereClause: [String: AgentSQLValue],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        for key in whereClause.keys { try Self.validateIdentifier(key) }

        return try inTransaction { _ in
            // Soft delete REQUIRES the marker column. A raw-SQL-created table
            // has no `_deleted_at`; the old code let SQLite fail the prepare
            // with a bare "no such column" — precise but unactionable. Tell
            // the model what the real situation is and which path works.
            guard try self.tableHasColumnUnlocked(table, column: "_deleted_at") else {
                throw AgentDatabaseError.invalidArgument(
                    "table '\(table)' has no `_deleted_at` column (it was created "
                        + "with raw SQL, not db_create_table), so soft delete isn't "
                        + "available. Use `db_execute` with a DELETE statement to "
                        + "remove rows from this table."
                )
            }
            let beforeRows = try self.selectMatchingRowsUnlocked(
                table: table,
                whereClause: whereClause,
                includeDeleted: false
            )

            let cols = Array(whereClause.keys)
            let whereSQL = cols.enumerated().map { i, c in "\(c) = ?\(i + 1)" }
                .joined(separator: " AND ")
            let sql = """
                    UPDATE \(table) SET _deleted_at = strftime('%s','now')
                    WHERE \(whereSQL) AND _deleted_at IS NULL
                """
            try self.transactionalStep(sql) { stmt in
                for (i, c) in cols.enumerated() {
                    Self.bind(stmt, index: i + 1, value: whereClause[c] ?? .null)
                }
            }
            let affected = Int(sqlite3_changes(self.db))

            for row in beforeRows {
                let pk = Self.stringifyPK(row["id"] ?? row.first?.value)
                try self.appendChangelogUnlocked(
                    runId: runId,
                    actor: actor,
                    op: .softDelete,
                    tableName: table,
                    rowPK: pk,
                    beforeJSON: Self.jsonEncode(row),
                    afterJSON: nil,
                    sql: nil
                )
            }
            return affected
        }
    }

    @discardableResult
    public func restore(
        table: String,
        whereClause: [String: AgentSQLValue],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        for key in whereClause.keys { try Self.validateIdentifier(key) }

        return try inTransaction { _ in
            // Same schema requirement as softDelete: no marker column means
            // there is nothing to restore from.
            guard try self.tableHasColumnUnlocked(table, column: "_deleted_at") else {
                throw AgentDatabaseError.invalidArgument(
                    "table '\(table)' has no `_deleted_at` column (it was created "
                        + "with raw SQL, not db_create_table), so it has no "
                        + "soft-deleted rows to restore."
                )
            }
            let beforeRows = try self.selectMatchingRowsUnlocked(
                table: table,
                whereClause: whereClause,
                includeDeleted: true
            )

            let cols = Array(whereClause.keys)
            let whereSQL = cols.enumerated().map { i, c in "\(c) = ?\(i + 1)" }
                .joined(separator: " AND ")
            let sql = """
                    UPDATE \(table) SET _deleted_at = NULL
                    WHERE \(whereSQL) AND _deleted_at IS NOT NULL
                """
            try self.transactionalStep(sql) { stmt in
                for (i, c) in cols.enumerated() {
                    Self.bind(stmt, index: i + 1, value: whereClause[c] ?? .null)
                }
            }
            let affected = Int(sqlite3_changes(self.db))

            for row in beforeRows where row["_deleted_at"] != .null {
                let pk = Self.stringifyPK(row["id"] ?? row.first?.value)
                try self.appendChangelogUnlocked(
                    runId: runId,
                    actor: actor,
                    op: .restore,
                    tableName: table,
                    rowPK: pk,
                    beforeJSON: Self.jsonEncode(row),
                    afterJSON: nil,
                    sql: nil
                )
            }
            return affected
        }
    }

    // MARK: - Public: bulk writes / import

    /// How a bulk write resolves row conflicts.
    public enum BulkWriteMode: Sendable, Equatable {
        /// Plain `INSERT` for every row.
        case insert
        /// `INSERT … ON CONFLICT(keyColumns) DO UPDATE` — upsert keyed by
        /// the given UNIQUE / PRIMARY KEY columns.
        case upsert(keyColumns: [String])
    }

    /// Insert many rows in chunked transactions. Returns the rowids of the
    /// inserted rows in input order.
    ///
    /// Each row is bound only for the columns it actually contains, so an
    /// omitted column still picks up its SQLite default (host-managed
    /// `id`/`_created_at`/… included). We reuse one prepared statement per
    /// distinct column signature within a chunk, so the common case (every
    /// row has the same shape) compiles the SQL exactly once per chunk.
    @discardableResult
    public func insertMany(
        table: String,
        rows: [[String: AgentSQLValue]],
        chunkSize: Int = 1000,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> [Int64] {
        try bulkWrite(
            table: table,
            rows: rows,
            mode: .insert,
            chunkSize: chunkSize,
            loggingOp: .insert,
            captureRowIDs: true,
            actor: actor,
            runId: runId
        ).rowIDs
    }

    /// Upsert many rows keyed by `keyColumns`. Returns the number of rows
    /// processed.
    @discardableResult
    public func upsertMany(
        table: String,
        keyColumns: [String],
        rows: [[String: AgentSQLValue]],
        chunkSize: Int = 1000,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int {
        try bulkWrite(
            table: table,
            rows: rows,
            mode: .upsert(keyColumns: keyColumns),
            chunkSize: chunkSize,
            loggingOp: .insert,
            captureRowIDs: false,
            actor: actor,
            runId: runId
        ).count
    }

    /// Host-mediated bulk import. Same write engine as `insertMany` /
    /// `upsertMany`, but the audit op is `.bulkImport` so the load reads as
    /// an import rather than N organic inserts. `keyColumns` empty ⇒ plain
    /// insert; non-empty ⇒ upsert keyed by those columns. Returns the
    /// number of rows imported.
    @discardableResult
    public func importRows(
        table: String,
        rows: [[String: AgentSQLValue]],
        keyColumns: [String] = [],
        chunkSize: Int = 1000,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Int {
        let mode: BulkWriteMode =
            keyColumns.isEmpty ? .insert : .upsert(keyColumns: keyColumns)
        return try bulkWrite(
            table: table,
            rows: rows,
            mode: mode,
            chunkSize: chunkSize,
            loggingOp: .bulkImport,
            captureRowIDs: false,
            actor: actor,
            runId: runId
        ).count
    }

    /// Shared core for every bulk write. Validates once, then writes in
    /// `chunkSize` batches. Each batch is its own `BEGIN IMMEDIATE`
    /// transaction so a large load doesn't hold a single giant write lock
    /// and the storage quota is re-checked between chunks (post-commit,
    /// like every other write path). One `_changelog` entry is written per
    /// committed chunk.
    private func bulkWrite(
        table: String,
        rows: [[String: AgentSQLValue]],
        mode: BulkWriteMode,
        chunkSize: Int,
        loggingOp: AgentDatabaseOp,
        captureRowIDs: Bool,
        actor: AgentDatabaseActor,
        runId: UUID?
    ) throws -> (rowIDs: [Int64], count: Int) {
        try Self.validateIdentifier(table)
        try Self.requireNotReservedTable(table)
        guard !rows.isEmpty else {
            throw AgentDatabaseError.invalidArgument("bulk write: rows must not be empty")
        }

        // Validate every distinct column referenced across all rows once.
        var seenColumns = Set<String>()
        for row in rows {
            guard !row.isEmpty else {
                throw AgentDatabaseError.invalidArgument("bulk write: a row had no columns")
            }
            for key in row.keys where seenColumns.insert(key).inserted {
                try Self.validateIdentifier(key)
                try Self.requireNotReservedColumn(key)
            }
        }

        var keyColumns: [String] = []
        if case .upsert(let keys) = mode {
            guard !keys.isEmpty else {
                throw AgentDatabaseError.invalidArgument("upsert: keyColumns must not be empty")
            }
            for key in keys { try Self.validateIdentifier(key) }
            // ON CONFLICT needs every key present on each row, otherwise
            // the conflict target can't be evaluated.
            for row in rows {
                for key in keys where row[key] == nil {
                    throw AgentDatabaseError.invalidArgument(
                        "upsert: every row must include key column '\(key)'"
                    )
                }
            }
            keyColumns = keys
        }

        let safeChunk = max(1, chunkSize)
        var allRowIDs: [Int64] = []
        var total = 0
        var index = 0
        while index < rows.count {
            let upper = min(index + safeChunk, rows.count)
            let chunk = Array(rows[index ..< upper])
            index = upper
            let chunkResult = try inTransaction { connection in
                let written = try self.writeChunkPrepared(
                    connection: connection,
                    chunk: chunk,
                    table: table,
                    mode: mode,
                    keyColumns: keyColumns,
                    captureRowIDs: captureRowIDs
                )
                try self.appendChangelogUnlocked(
                    runId: runId,
                    actor: actor,
                    op: loggingOp,
                    tableName: table,
                    rowPK: nil,
                    beforeJSON: nil,
                    afterJSON: "{\"rows\":\(written.count)}",
                    sql: nil
                )
                return written
            }
            allRowIDs.append(contentsOf: chunkResult.rowIDs)
            total += chunkResult.count
        }
        return (allRowIDs, total)
    }

    /// Write one chunk's rows on `connection` (already inside a
    /// transaction). Prepares one statement per distinct column signature
    /// and reuses it across rows that share that shape.
    private func writeChunkPrepared(
        connection: OpaquePointer,
        chunk: [[String: AgentSQLValue]],
        table: String,
        mode: BulkWriteMode,
        keyColumns: [String],
        captureRowIDs: Bool
    ) throws -> (rowIDs: [Int64], count: Int) {
        var prepared: [String: OpaquePointer] = [:]
        defer { for stmt in prepared.values { sqlite3_finalize(stmt) } }

        var rowIDs: [Int64] = []
        var count = 0
        for row in chunk {
            let cols = row.keys.sorted()
            let signature = cols.joined(separator: "\u{1f}")
            let stmt: OpaquePointer
            if let existing = prepared[signature] {
                stmt = existing
            } else {
                let sql = Self.bulkRowSQL(
                    table: table,
                    columns: cols,
                    mode: mode,
                    keyColumns: keyColumns
                )
                var raw: OpaquePointer?
                guard sqlite3_prepare_v2(connection, sql, -1, &raw, nil) == SQLITE_OK,
                    let compiled = raw
                else {
                    throw AgentDatabaseError.failedToPrepare(
                        String(cString: sqlite3_errmsg(connection))
                    )
                }
                prepared[signature] = compiled
                stmt = compiled
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, col) in cols.enumerated() {
                Self.bind(stmt, index: i + 1, value: row[col] ?? .null)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw AgentDatabaseError.failedToExecute(
                    "bulk write: \(String(cString: sqlite3_errmsg(connection)))"
                )
            }
            if captureRowIDs {
                rowIDs.append(sqlite3_last_insert_rowid(connection))
            }
            count += 1
        }
        return (rowIDs, count)
    }

    /// Build the per-signature INSERT (or upsert) SQL for a bulk write.
    private static func bulkRowSQL(
        table: String,
        columns: [String],
        mode: BulkWriteMode,
        keyColumns: [String]
    ) -> String {
        let placeholders = (1 ... columns.count).map { "?\($0)" }.joined(separator: ", ")
        let colList = columns.joined(separator: ", ")
        switch mode {
        case .insert:
            return "INSERT INTO \(table) (\(colList)) VALUES (\(placeholders))"
        case .upsert:
            let setSQL =
                columns.filter { !keyColumns.contains($0) }
                .map { "\($0) = excluded.\($0)" }
                .joined(separator: ", ")
            let conflict = keyColumns.joined(separator: ", ")
            if setSQL.isEmpty {
                return
                    "INSERT INTO \(table) (\(colList)) VALUES (\(placeholders)) "
                    + "ON CONFLICT(\(conflict)) DO NOTHING"
            }
            return
                "INSERT INTO \(table) (\(colList)) VALUES (\(placeholders)) "
                + "ON CONFLICT(\(conflict)) DO UPDATE SET \(setSQL)"
        }
    }

    // MARK: - Public: query / execute

    /// Read-only query. Wraps in `BEGIN DEFERRED` so it doesn't lock
    /// out concurrent writers. `limit` caps the returned rows for this call
    /// (default `queryRowCap`, hard-capped at `queryRowHardMax`); `offset`
    /// skips rows so the caller can page. `truncated` is true when more rows
    /// existed past the returned window.
    public func query(
        sql: String,
        params: [AgentSQLValue] = [],
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> AgentQueryResult {
        guard !sql.isEmpty else {
            throw AgentDatabaseError.invalidArgument("query: sql must not be empty")
        }
        let rowCap: Int = {
            if let limit, limit > 0 { return min(limit, Self.queryRowHardMax) }
            return Self.queryRowCap
        }()
        let skip = max(0, offset ?? 0)
        return try queue.sync {
            guard let connection = db else { throw AgentDatabaseError.notOpen }
            try Self.executeRawOn(connection: connection, sql: "BEGIN DEFERRED")
            defer { try? Self.executeRawOn(connection: connection, sql: "ROLLBACK") }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK,
                let prepared = stmt
            else {
                throw AgentDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(prepared) }

            for (i, value) in params.enumerated() {
                Self.bind(prepared, index: i + 1, value: value)
            }

            let colCount = Int(sqlite3_column_count(prepared))
            var columns: [String] = []
            columns.reserveCapacity(colCount)
            for c in 0 ..< colCount {
                let name = sqlite3_column_name(prepared, Int32(c)).map { String(cString: $0) } ?? ""
                columns.append(name)
            }

            var rows: [[AgentSQLValue]] = []
            var truncated = false
            var skipped = 0
            while sqlite3_step(prepared) == SQLITE_ROW {
                if skipped < skip {
                    skipped += 1
                    continue
                }
                if rows.count >= rowCap {
                    truncated = true
                    break
                }
                var row: [AgentSQLValue] = []
                row.reserveCapacity(colCount)
                for c in 0 ..< colCount {
                    row.append(Self.readColumn(prepared, index: c))
                }
                rows.append(row)
            }

            return AgentQueryResult(columns: columns, rows: rows, truncated: truncated)
        }
    }

    /// Raw SQL escape hatch (spec §6.2). Rejects the absolute-disaster
    /// statements (`DROP TABLE`, `TRUNCATE`, `DELETE` with no WHERE on
    /// any user table) and logs everything else to `_changelog` with
    /// `op = 'raw'` so the Activity surface can flag it.
    @discardableResult
    public func execute(
        sql: String,
        params: [AgentSQLValue] = [],
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> AgentExecuteResult {
        guard !sql.isEmpty else {
            throw AgentDatabaseError.invalidArgument("execute: sql must not be empty")
        }
        if let reason = Self.forbiddenReason(in: sql) {
            throw AgentDatabaseError.forbidden(reason)
        }

        var warning: String? = nil
        if Self.isDangerousButAllowed(in: sql) {
            warning = "Statement is destructive (DELETE/UPDATE without LIMIT). Logged in _changelog with op='raw'."
        }

        return try inTransaction { connection in
            // Multi-statement support: `sqlite3_prepare_v2` compiles only the
            // first statement and hands back the unconsumed tail. Loop over
            // the tail so a transform / migration script (`CREATE TEMP …;
            // INSERT … SELECT …; DROP …`) runs in full inside this one
            // transaction instead of silently dropping everything after the
            // first `;`. Row counts are taken from `sqlite3_total_changes`
            // deltas so non-DML statements (CREATE/PRAGMA) don't inflate the
            // total.
            let before = Int(sqlite3_total_changes(connection))
            try sql.withCString { (base: UnsafePointer<CChar>) in
                var cursor: UnsafePointer<CChar>? = base
                while let current = cursor, current.pointee != 0 {
                    var stmt: OpaquePointer?
                    var tail: UnsafePointer<CChar>?
                    guard sqlite3_prepare_v2(connection, current, -1, &stmt, &tail) == SQLITE_OK
                    else {
                        throw AgentDatabaseError.failedToPrepare(
                            String(cString: sqlite3_errmsg(connection))
                        )
                    }
                    cursor = tail
                    guard let prepared = stmt else {
                        // Trailing whitespace / a bare `;` compiles to no
                        // statement — skip and keep walking the tail.
                        continue
                    }
                    defer { sqlite3_finalize(prepared) }

                    let bindCount = Int(sqlite3_bind_parameter_count(prepared))
                    if bindCount > 0 {
                        for i in 0 ..< min(params.count, bindCount) {
                            Self.bind(prepared, index: i + 1, value: params[i])
                        }
                    }

                    let step = sqlite3_step(prepared)
                    // `SELECT` via execute returns SQLITE_ROW — we don't
                    // surface the rows (`query` exists for that); drain to
                    // DONE so the transaction can commit cleanly.
                    if step == SQLITE_ROW {
                        while sqlite3_step(prepared) == SQLITE_ROW { /* drain */  }
                    } else if step != SQLITE_DONE {
                        throw AgentDatabaseError.failedToExecute(
                            "execute: step returned \(step): "
                                + String(cString: sqlite3_errmsg(connection))
                        )
                    }
                }
            }
            let affected = Int(sqlite3_total_changes(connection)) - before

            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .raw,
                tableName: nil,
                rowPK: nil,
                beforeJSON: nil,
                afterJSON: nil,
                sql: sql
            )

            return AgentExecuteResult(rowsAffected: affected, warning: warning)
        }
    }

    // MARK: - Public: saved views

    /// Insert or update a saved view (spec §6.3). Saved views are
    /// just SELECT/CTE statements stored by name in `_views`; the
    /// agent reuses them via `runView` and the UI surfaces them on
    /// the Home / Views tabs. The SQL is validated against the same
    /// `forbiddenReason` lattice as `execute` so a SELECT-only view
    /// can never accidentally hide a destructive statement.
    public func defineView(
        name: String,
        sql: String,
        renderHint: String,
        refresh: String,
        description: String?,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> AgentSavedView {
        try Self.validateIdentifier(name)
        guard !sql.isEmpty else {
            throw AgentDatabaseError.invalidArgument("defineView: sql must not be empty")
        }
        if let reason = Self.forbiddenReason(in: sql) {
            throw AgentDatabaseError.forbidden(reason)
        }
        // Saved views must be SELECT-only — anything else turns the
        // tool into a thin wrapper around execute() and silently
        // accumulates destructive statements in the agent's
        // saved-view drawer.
        let head = Self.stripComments(sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard head.hasPrefix("SELECT") || head.hasPrefix("WITH") else {
            throw AgentDatabaseError.invalidArgument(
                "defineView: saved views must start with SELECT or WITH"
            )
        }

        let now = Date()
        let nowEpoch = Int64(now.timeIntervalSince1970)
        try inTransaction { _ in
            // Naming collision = hard error (spec §16). Views and user
            // tables share a global namespace from the agent's
            // perspective — a saved view that shadows a table name
            // would silently break `db_query` on that table.
            if try self.existsUserTableUnlocked(name) {
                throw AgentDatabaseError.invalidArgument(
                    "defineView: a user table named `\(name)` already exists; pick a different view name"
                )
            }
            // Use INSERT ... ON CONFLICT(name) DO UPDATE so we keep
            // `created_at` stable across re-definitions and only
            // bump `updated_at`. Pinned state survives a redefine.
            try self.transactionalStep(
                """
                    INSERT INTO _views
                        (name, sql, render_hint, refresh, description, created_at, updated_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
                    ON CONFLICT(name) DO UPDATE SET
                        sql = excluded.sql,
                        render_hint = excluded.render_hint,
                        refresh = excluded.refresh,
                        description = excluded.description,
                        updated_at = excluded.updated_at
                """
            ) { stmt in
                Self.bind(stmt, index: 1, value: .text(name))
                Self.bind(stmt, index: 2, value: .text(sql))
                Self.bind(stmt, index: 3, value: .text(renderHint))
                Self.bind(stmt, index: 4, value: .text(refresh))
                if let description {
                    Self.bind(stmt, index: 5, value: .text(description))
                } else {
                    Self.bind(stmt, index: 5, value: .null)
                }
                Self.bind(stmt, index: 6, value: .integer(nowEpoch))
            }

            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .raw,
                tableName: "_views",
                rowPK: name,
                beforeJSON: nil,
                afterJSON: Self.jsonEncode([
                    "name": .text(name),
                    "render_hint": .text(renderHint),
                    "refresh": .text(refresh),
                ]),
                sql: "DEFINE VIEW \(name)"
            )
        }

        return AgentSavedView(
            name: name,
            sql: sql,
            renderHint: renderHint,
            refresh: refresh,
            description: description,
            pinned: false,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Drop a saved view by name. Always logs to `_changelog` so the
    /// audit trail still records the deletion.
    @discardableResult
    public func dropView(
        name: String,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws -> Bool {
        try Self.validateIdentifier(name)
        var existed = false
        try inTransaction { _ in
            try self.transactionalStep("SELECT 1 FROM _views WHERE name = ?1") { stmt in
                Self.bind(stmt, index: 1, value: .text(name))
                if sqlite3_step(stmt) == SQLITE_ROW { existed = true }
            }
            if !existed { return }
            try self.transactionalStep("DELETE FROM _views WHERE name = ?1") { stmt in
                Self.bind(stmt, index: 1, value: .text(name))
            }
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .raw,
                tableName: "_views",
                rowPK: name,
                beforeJSON: nil,
                afterJSON: nil,
                sql: "DROP VIEW \(name)"
            )
        }
        return existed
    }

    /// Toggle the pinned bit on a saved view. Used by the Views tab
    /// to surface a subset of views on Home (spec §5.7). Logged
    /// because the change is visible in the agent's prompt — pinning
    /// affects which views the Home tab loads on cold-start.
    public func setViewPinned(
        name: String,
        pinned: Bool,
        actor: AgentDatabaseActor,
        runId: UUID? = nil
    ) throws {
        try Self.validateIdentifier(name)
        try inTransaction { _ in
            try self.transactionalStep(
                "UPDATE _views SET pinned = ?1, updated_at = strftime('%s','now') WHERE name = ?2"
            ) { stmt in
                Self.bind(stmt, index: 1, value: .integer(pinned ? 1 : 0))
                Self.bind(stmt, index: 2, value: .text(name))
            }
            try self.appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: .update,
                tableName: "_views",
                rowPK: name,
                beforeJSON: nil,
                afterJSON: Self.jsonEncode(["pinned": .bool(pinned)]),
                sql: nil
            )
        }
    }

    /// Look up a single saved view by name.
    public func savedView(named name: String) throws -> AgentSavedView? {
        try queue.sync {
            guard db != nil else { throw AgentDatabaseError.notOpen }
            return try listViewsUnlocked().first { $0.name == name }
        }
    }

    /// All saved views, ordered by name.
    public func savedViews() throws -> [AgentSavedView] {
        try queue.sync {
            guard db != nil else { throw AgentDatabaseError.notOpen }
            return try listViewsUnlocked().sorted { $0.name < $1.name }
        }
    }

    /// Run a saved view's SELECT/CTE and return the rows. Errors if
    /// the view doesn't exist. The query is still subject to the
    /// same row cap as `query`.
    public func runView(name: String) throws -> AgentQueryResult {
        guard let view = try savedView(named: name) else {
            throw AgentDatabaseError.invalidArgument("runView: no saved view named '\(name)'")
        }
        return try query(sql: view.sql, params: [])
    }

    // MARK: - Public: changelog

    /// Append a row to `_changelog`. Public so callers writing through
    /// other code paths (migration runner, user UI edits, etc.) can
    /// stamp their actor + run id consistently.
    public func appendChangelog(
        runId: UUID?,
        actor: AgentDatabaseActor,
        op: AgentDatabaseOp,
        tableName: String?,
        rowPK: String?,
        beforeJSON: String?,
        afterJSON: String?,
        sql: String?
    ) throws {
        try queue.sync {
            guard db != nil else { throw AgentDatabaseError.notOpen }
            try appendChangelogUnlocked(
                runId: runId,
                actor: actor,
                op: op,
                tableName: tableName,
                rowPK: rowPK,
                beforeJSON: beforeJSON,
                afterJSON: afterJSON,
                sql: sql
            )
        }
    }

    // MARK: - Internals: schema readers (must hold `queue`)

    private func listUserTablesUnlocked() throws -> [String] {
        var names: [String] = []
        try executeRaw(
            """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE '\\_%' ESCAPE '\\'
                ORDER BY name
            """
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return names
    }

    private func schemaForTableUnlocked(_ name: String) throws -> AgentTableSchema {
        var purpose = ""
        try executeRaw(
            "SELECT purpose FROM _tables_meta WHERE table_name = '\(name)'"
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                purpose = String(cString: sqlite3_column_text(stmt, 0))
            }
        }

        var columns: [AgentColumnInfo] = []
        try executeRaw("PRAGMA table_info(\(name))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let colName = String(cString: sqlite3_column_text(stmt, 1))
                let type = String(cString: sqlite3_column_text(stmt, 2))
                let notNull = sqlite3_column_int(stmt, 3) != 0
                let dflt = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let pk = sqlite3_column_int(stmt, 5) != 0
                columns.append(
                    AgentColumnInfo(
                        name: colName,
                        type: type,
                        nullable: !notNull,
                        defaultValue: dflt,
                        primaryKey: pk
                    )
                )
            }
        }

        var indexes: [AgentIndexInfo] = []
        // List indexes for this table, excluding the auto sqlite ones.
        var indexNames: [(name: String, unique: Bool)] = []
        try executeRaw("PRAGMA index_list(\(name))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idxName = String(cString: sqlite3_column_text(stmt, 1))
                let unique = sqlite3_column_int(stmt, 2) != 0
                if !idxName.hasPrefix("sqlite_") {
                    indexNames.append((idxName, unique))
                }
            }
        }
        for entry in indexNames {
            var cols: [String] = []
            try executeRaw("PRAGMA index_info(\(entry.name))") { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    cols.append(String(cString: sqlite3_column_text(stmt, 2)))
                }
            }
            indexes.append(AgentIndexInfo(name: entry.name, columns: cols, unique: entry.unique))
        }

        var rowCount = 0
        try executeRaw("SELECT COUNT(*) FROM \(name)") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                rowCount = Int(sqlite3_column_int(stmt, 0))
            }
        }

        var lastWriteAt: Date?
        // Last touch is the max of (max(_updated_at), max(_created_at)).
        try executeRaw(
            "SELECT MAX(_updated_at) FROM \(name)"
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW,
                sqlite3_column_type(stmt, 0) != SQLITE_NULL
            {
                let ts = sqlite3_column_int64(stmt, 0)
                lastWriteAt = Date(timeIntervalSince1970: TimeInterval(ts))
            }
        }

        return AgentTableSchema(
            name: name,
            purpose: purpose,
            columns: columns,
            indexes: indexes,
            rowCount: rowCount,
            lastWriteAt: lastWriteAt
        )
    }

    private func listViewsUnlocked() throws -> [AgentSavedView] {
        var views: [AgentSavedView] = []
        try executeRaw(
            "SELECT name, sql, render_hint, refresh, description, pinned, created_at, updated_at FROM _views"
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let sql = String(cString: sqlite3_column_text(stmt, 1))
                let hint = String(cString: sqlite3_column_text(stmt, 2))
                let refresh = String(cString: sqlite3_column_text(stmt, 3))
                let desc = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let pinned = sqlite3_column_int(stmt, 5) != 0
                let created = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
                let updated = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                views.append(
                    AgentSavedView(
                        name: name,
                        sql: sql,
                        renderHint: hint,
                        refresh: refresh,
                        description: desc,
                        pinned: pinned,
                        createdAt: created,
                        updatedAt: updated
                    )
                )
            }
        }
        return views
    }

    private func existsUserTableUnlocked(_ name: String) throws -> Bool {
        var found = false
        try executeRaw(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { found = true }
        }
        return found
    }

    /// Whether `table` actually has a column named `column`.
    ///
    /// The typed mutation/read paths historically assumed every user table
    /// carries the host-managed `_deleted_at` column — true for tables made
    /// via `createTable`, false for tables created through raw SQL
    /// (`db_execute` CREATE TABLE, eval `seedSql`). Blindly appending the
    /// soft-delete predicate to those tables produced
    /// "no such column: _deleted_at" prepare failures on perfectly valid
    /// typed calls (observed live: `db_update`/`db_delete` on an
    /// execute-created table). Callers use this to apply soft-delete
    /// semantics only where the schema actually supports them.
    private func tableHasColumnUnlocked(_ table: String, column: String) throws -> Bool {
        // `table` is validated upstream (identifier charset), so direct
        // interpolation into PRAGMA is safe — PRAGMA cannot bind parameters.
        var found = false
        try executeRaw("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(stmt, 1),
                    String(cString: namePtr) == column
                {
                    found = true
                    break
                }
            }
        }
        return found
    }

    /// Reads matching rows into `[column: value]` dictionaries. Used by
    /// mutation methods to capture before/after JSON for the changelog.
    private func selectMatchingRowsUnlocked(
        table: String,
        whereClause: [String: AgentSQLValue],
        includeDeleted: Bool
    ) throws -> [[String: AgentSQLValue]] {
        let cols = Array(whereClause.keys)
        let whereSQL =
            cols.isEmpty
            ? "1 = 1"
            : cols.enumerated().map { i, c in "\(c) = ?\(i + 1)" }.joined(separator: " AND ")
        let hasSoftDelete = try tableHasColumnUnlocked(table, column: "_deleted_at")
        let softDeleteSQL = (includeDeleted || !hasSoftDelete) ? "" : " AND _deleted_at IS NULL"
        let sql = "SELECT * FROM \(table) WHERE \(whereSQL)\(softDeleteSQL)"

        var rows: [[String: AgentSQLValue]] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw AgentDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        for (i, c) in cols.enumerated() {
            Self.bind(s, index: i + 1, value: whereClause[c] ?? .null)
        }
        let colCount = Int(sqlite3_column_count(s))
        var colNames: [String] = []
        for c in 0 ..< colCount {
            colNames.append(sqlite3_column_name(s, Int32(c)).map { String(cString: $0) } ?? "")
        }
        while sqlite3_step(s) == SQLITE_ROW {
            var row: [String: AgentSQLValue] = [:]
            for c in 0 ..< colCount {
                row[colNames[c]] = Self.readColumn(s, index: c)
            }
            rows.append(row)
        }
        return rows
    }

    private func appendChangelogUnlocked(
        runId: UUID?,
        actor: AgentDatabaseActor,
        op: AgentDatabaseOp,
        tableName: String?,
        rowPK: String?,
        beforeJSON: String?,
        afterJSON: String?,
        sql: String?
    ) throws {
        try transactionalStep(
            """
            INSERT INTO _changelog
                (ts, run_id, actor, op, table_name, row_pk, before_json, after_json, sql)
            VALUES (strftime('%s','now'), ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: runId?.uuidString)
            Self.bindText(stmt, index: 2, value: actor.rawValue)
            Self.bindText(stmt, index: 3, value: op.rawValue)
            Self.bindText(stmt, index: 4, value: tableName)
            Self.bindText(stmt, index: 5, value: rowPK)
            Self.bindText(stmt, index: 6, value: beforeJSON)
            Self.bindText(stmt, index: 7, value: afterJSON)
            Self.bindText(stmt, index: 8, value: sql)
        }
    }

    // MARK: - Validation

    /// Reserved (host-managed) tables. `db.execute` may target them
    /// with a logged warning, but the typed surface refuses.
    private static let reservedTables: Set<String> = ["_tables_meta", "_changelog", "_views"]

    /// Reserved (host-managed) column names. Auto-added on every user
    /// table; the agent isn't allowed to redeclare them.
    private static let reservedColumns: Set<String> = [
        "_created_at", "_updated_at", "_deleted_at",
    ]

    /// Sniff dangerous statements before they hit SQLite. Returns the
    /// human-readable reason when the statement should be rejected.
    /// Heuristic-only — SQLite parses the actual SQL, but this catches
    /// the obvious foot-guns the spec calls out (§6.2).
    static func forbiddenReason(in rawSQL: String) -> String? {
        let s = collapseWhitespace(stripComments(rawSQL.uppercased()))
        if s.contains("DROP TABLE") {
            return "DROP TABLE is not allowed; rename + deprecate is the agent path."
        }
        if s.contains("TRUNCATE") {
            return "TRUNCATE is not allowed."
        }
        if s.contains("DROP DATABASE") {
            return "DROP DATABASE is not allowed."
        }
        if s.contains("DELETE FROM") && !s.contains(" WHERE ") {
            return "DELETE without WHERE is not allowed."
        }
        // ATTACH/DETACH would mount another database file into this agent's
        // connection — a sandbox escape. `load_extension` loads native code.
        // Neither is ever legitimate from the agent SQL surface.
        if s.contains("ATTACH ") || s.hasSuffix("ATTACH")
            || s.contains("DETACH ") || s.hasSuffix("DETACH")
        {
            return "ATTACH / DETACH is not allowed; the agent DB is a single private file."
        }
        if s.contains("LOAD_EXTENSION") {
            return "load_extension is not allowed."
        }
        // Per-statement checks: PRAGMA writes (which can flip journal mode,
        // foreign-key enforcement, etc.) and any write that targets a
        // reserved/system table (raw SQL would bypass the soft-delete +
        // audit contract — especially tampering with `_changelog`).
        for statement in s.components(separatedBy: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("PRAGMA "), trimmed.contains("=") {
                return "PRAGMA writes are not allowed; read-only PRAGMAs are fine."
            }
            if let table = reservedTableWriteTarget(in: trimmed) {
                return
                    "Writing to the reserved table `\(table.lowercased())` is not allowed — "
                    + "it would bypass the audit/soft-delete contract. Use the typed db_* tools."
            }
        }
        return nil
    }

    /// If `statement` (uppercased, comment-stripped, single-spaced) is a
    /// write (INSERT / UPDATE / DELETE / REPLACE) whose target is one of the
    /// reserved system tables, return that table name. Reads are allowed, so
    /// a `SELECT … FROM _changelog` returns nil.
    private static func reservedTableWriteTarget(in statement: String) -> String? {
        let writePrefixes = ["INSERT ", "INSERT OR ", "REPLACE ", "UPDATE ", "DELETE "]
        guard writePrefixes.contains(where: { statement.hasPrefix($0) }) else { return nil }
        for table in reservedTables {
            let upper = table.uppercased()
            if statement.contains(" \(upper) ")
                || statement.contains(" \(upper)(")
                || statement.hasSuffix(" \(upper)")
            {
                return table
            }
        }
        return nil
    }

    /// "Dangerous but allowed" — surfaced as a warning, not an error.
    /// E.g. wide UPDATEs/DELETEs against reserved or user tables.
    static func isDangerousButAllowed(in rawSQL: String) -> Bool {
        let s = collapseWhitespace(stripComments(rawSQL.uppercased()))
        // UPDATE without WHERE — rare but legitimate (e.g. "mark all
        // rows as processed"). Warn so the user sees it in Activity.
        if s.hasPrefix("UPDATE ") && !s.contains(" WHERE ") { return true }
        return false
    }

    private static func stripComments(_ s: String) -> String {
        // Coarse strip — sufficient for the heuristics above. The SQL
        // is later prepared by SQLite which does the real parsing.
        var out = s
        while let r = out.range(of: "--") {
            if let end = out.range(of: "\n", range: r.upperBound ..< out.endIndex) {
                out.removeSubrange(r.lowerBound ..< end.upperBound)
            } else {
                out.removeSubrange(r.lowerBound ..< out.endIndex)
            }
        }
        while let r = out.range(of: "/*") {
            if let end = out.range(of: "*/", range: r.upperBound ..< out.endIndex) {
                out.removeSubrange(r.lowerBound ..< end.upperBound)
            } else {
                out.removeSubrange(r.lowerBound ..< out.endIndex)
            }
        }
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func validateIdentifier(_ name: String) throws {
        // SQLite identifiers must be non-empty and contain only
        // ASCII letters, digits, or `_`. Strict so we never have to
        // worry about quoting in the generated SQL.
        guard !name.isEmpty, name.count <= 128 else {
            throw AgentDatabaseError.invalidArgument("identifier must be 1..128 chars: '\(name)'")
        }
        for (i, ch) in name.enumerated() {
            if i == 0 {
                guard ch.isLetter || ch == "_" else {
                    throw AgentDatabaseError.invalidArgument("identifier must start with letter or _: '\(name)'")
                }
            } else {
                guard ch.isLetter || ch.isNumber || ch == "_" else {
                    throw AgentDatabaseError.invalidArgument(
                        "identifier may contain only letters, digits, and _: '\(name)'"
                    )
                }
            }
        }
    }

    private static func requireNotReservedTable(_ name: String) throws {
        if reservedTables.contains(name.lowercased()) {
            throw AgentDatabaseError.forbidden("'\(name)' is a reserved system table")
        }
    }

    private static func requireNotReservedColumn(_ name: String) throws {
        if reservedColumns.contains(name.lowercased()) {
            throw AgentDatabaseError.forbidden(
                "'\(name)' is a reserved host-managed column (auto-added)"
            )
        }
    }

    private static func normalizeType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "TEXT" }
        return trimmed.uppercased()
    }

    /// Default value used to backfill a `NOT NULL ADD COLUMN` when the
    /// agent didn't supply one and the table has rows (spec §16 Q5).
    /// Picks a benign zero / empty value matching the column's affinity.
    static func derivedDefault(forType raw: String) -> String {
        switch normalizeType(raw) {
        case "INTEGER", "REAL", "NUMERIC": return "0"
        case "BLOB": return "X''"
        default: return "''"
        }
    }

    private static func stringifyPK(_ value: AgentSQLValue?) -> String? {
        switch value {
        case .none, .some(.null): return nil
        case .some(.integer(let n)): return String(n)
        case .some(.double(let d)): return String(d)
        case .some(.text(let s)): return s
        case .some(.bool(let b)): return b ? "1" : "0"
        case .some(.blob): return nil
        }
    }

    // MARK: - SQLite helpers

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

    static func bind(_ stmt: OpaquePointer, index: Int, value: AgentSQLValue) {
        switch value {
        case .null:
            sqlite3_bind_null(stmt, Int32(index))
        case .integer(let n):
            sqlite3_bind_int64(stmt, Int32(index), n)
        case .double(let d):
            sqlite3_bind_double(stmt, Int32(index), d)
        case .text(let s):
            sqlite3_bind_text(stmt, Int32(index), s, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            data.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, Int32(index), raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        case .bool(let b):
            sqlite3_bind_int(stmt, Int32(index), b ? 1 : 0)
        }
    }

    static func readColumn(_ stmt: OpaquePointer, index: Int) -> AgentSQLValue {
        let type = sqlite3_column_type(stmt, Int32(index))
        switch type {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, Int32(index)))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, Int32(index)))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(stmt, Int32(index))))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_bytes(stmt, Int32(index))
            guard bytes > 0,
                let ptr = sqlite3_column_blob(stmt, Int32(index))
            else { return .blob(Data()) }
            return .blob(Data(bytes: ptr, count: Int(bytes)))
        default: return .null
        }
    }

    private static func jsonEncode(_ row: [String: AgentSQLValue]) -> String? {
        guard let data = try? JSONEncoder().encode(row) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw AgentDatabaseError.notOpen }
        try Self.executeRawOn(connection: connection, sql: sql)
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw AgentDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw AgentDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        try handler(s)
    }

    private static func executeRawOn(connection: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw AgentDatabaseError.failedToExecute(message)
        }
    }

    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw AgentDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw AgentDatabaseError.failedToExecute(
                "transactionalStep: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private func inTransaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw AgentDatabaseError.notOpen }
            // BEGIN IMMEDIATE (spec §16 Q1): the agent's DB is single-
            // writer-multi-reader WAL, but BEGIN DEFERRED's lock-upgrade
            // on first write can race against a concurrent UI reader
            // and surface as `SQLITE_BUSY`. IMMEDIATE acquires the
            // write lock at BEGIN time so we either fail-fast or own
            // the writer slot for the whole transaction.
            try executeRaw("BEGIN IMMEDIATE")
            do {
                let result = try operation(connection)
                try executeRaw("COMMIT")
                // Quota check is post-commit (spec §11.3): a single
                // oversize transaction is allowed to land, but the next
                // mutation fails so the agent/user gets a clear signal
                // to free space. Pre-commit checks would force every
                // write through a `PRAGMA wal_checkpoint` to get an
                // accurate file size, which is too expensive on the
                // hot path.
                try self.enforceStorageQuotaUnlocked()
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }
}
