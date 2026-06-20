//
//  PluginDatabase.swift
//  osaurus
//
//  Sandboxed per-plugin SQLite database.
//  Each plugin gets its own isolated database for structured data storage.
//

import Foundation
import OsaurusSQLCipher

public enum PluginDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open plugin database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare: \(msg)"
        case .notOpen: return "Plugin database is not open"
        }
    }
}

/// Sandboxed SQLite database for a single plugin.
/// Provides `exec` (writes) and `query` (reads) with JSON parameter binding.
final class PluginDatabase: @unchecked Sendable {
    let pluginId: String
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.plugin.db")
    private let maxBytes: Int64

    /// SQLite SQLITE_TRANSIENT destructor: tells SQLite to make its own copy of bound data.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Default per-plugin DB size cap. Plugins use SQLite for state
    /// that should fit comfortably alongside a few hundred installed
    /// plugins; large blobs belong in shared artifacts. SQLite enforces
    /// the limit via `PRAGMA max_page_count` — INSERTs past the cap
    /// fail with `database or disk is full`, the plugin sees a normal
    /// SQL error (no host crash), and the user's disk is protected
    /// from a runaway plugin filling up `~/.osaurus/Tools/<id>/data/`.
    /// Documented under `db_exec` in `osaurus_plugin.h`.
    public static let defaultMaxBytes: Int64 = 100 * 1024 * 1024  // 100 MiB

    init(pluginId: String, maxBytes: Int64 = PluginDatabase.defaultMaxBytes) {
        self.pluginId = pluginId
        self.maxBytes = maxBytes
    }

    deinit {
        close()
    }

    // MARK: - Open-connection registry (quiesce support)
    //
    // Plugin DBs are intentionally not `OsaurusDatabaseHandle`s (see `open()`),
    // so convergence/rotation can't find them to close before they swap or
    // rekey the on-disk file — and an open fd over a swapped/rekeyed file
    // corrupts the store. This weak registry lets those paths close every live
    // plugin connection; each reopens lazily on its next `dbExec`/`dbQuery`.
    //
    // Lock ordering: register/deregister run OUTSIDE the per-DB `queue`, and
    // `closeAllOpen()` drops `registryLock` before touching any DB queue, so no
    // thread holds both locks at once (no inversion to deadlock on).
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static let openInstances = NSHashTable<PluginDatabase>.weakObjects()

    private func registerOpen() {
        Self.registryLock.lock()
        Self.openInstances.add(self)
        Self.registryLock.unlock()
    }

    private func deregisterOpen() {
        Self.registryLock.lock()
        Self.openInstances.remove(self)
        Self.registryLock.unlock()
    }

    /// Close every currently-open plugin database. Called by storage
    /// convergence and key rotation while the mutation gate is held so the
    /// on-disk file can be swapped/rekeyed with no live fd attached. Each
    /// plugin reopens lazily on its next SQL call.
    static func closeAllOpen() {
        registryLock.lock()
        let snapshot = openInstances.allObjects
        registryLock.unlock()
        for db in snapshot { db.close() }
    }

    // MARK: - Lifecycle

    /// Opens an in-memory SQLite database (for tests). **Plaintext** —
    /// production plugin DBs are SQLCipher-encrypted using the
    /// shared storage key, transparently to plugin SQL. Honors the
    /// `maxBytes` cap so size-limit tests can exercise the same
    /// `applyMaxPageCount` path as production.
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try configurePragmas()
        }
    }

    func open() throws {
        // Plugin SQL can fire very early in launch (a plugin's
        // `loadAll()` registration may exec startup queries before
        // the AppDelegate's gate has fully cleared on slower
        // machines). Sync-gate here too so SQLCipher never opens a
        // still-plaintext file with a key. No-op fast path once the
        // migrator's done.
        //
        // NOTE: unlike the four "core" databases (chat-history,
        // memory, methods, tool-index), we do NOT register plugin
        // DBs with `OsaurusDatabaseHandle.register(...)`. Users may
        // have hundreds of installed plugins; running PRAGMA
        // optimize / wal_checkpoint / VACUUM across all of them on
        // every maintenance tick would be a startup-storm
        // anti-pattern. Plugin DBs already run `PRAGMA optimize` in
        // their own `close()`, which is sufficient. Key rotation
        // still works against plugin DBs because
        // `StorageExportService.rotateStorageKey` enumerates
        // `StorageDatabaseCatalog.databaseTargets()`, which
        // independently walks `~/.osaurus/Tools/<plugin>/data/data.db`
        // from disk.
        StorageMutationGate.blockingAwaitNotMutating()

        try queue.sync {
            guard db == nil else { return }

            OsaurusPaths.ensureExistsSilent(OsaurusPaths.pluginDataDirectory(for: pluginId))
            let path = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
            do {
                db = try OsaurusStorageOpener.open(path: path)
            } catch let error as EncryptedSQLiteError {
                throw PluginDatabaseError.failedToOpen(error.localizedDescription)
            }
            try configurePragmas()
        }
        // Registered outside the `queue.sync` above so we never hold the DB
        // queue and `registryLock` together (see the registry note). Idempotent
        // when the connection was already open.
        registerOpen()
    }

    func close() {
        // Deregister before taking the DB queue to preserve the registry lock
        // ordering. Safe to call when never registered (a no-op remove).
        deregisterOpen()
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Public API

    /// Execute a write statement (INSERT, UPDATE, DELETE, DDL).
    /// Returns JSON: `{"changes": N, "last_insert_rowid": N}` on success,
    /// or `{"error": "..."}` on failure.
    func exec(sql: String, paramsJSON: String?) -> String {
        queue.sync {
            guard let connection = db else {
                return #"{"error":"Database not open"}"#
            }
            return performExec(connection: connection, sql: sql, paramsJSON: paramsJSON)
        }
    }

    /// Execute a read query (SELECT).
    /// Returns JSON: `{"columns": [...], "rows": [[...], ...]}` on success,
    /// or `{"error": "..."}` on failure.
    func query(sql: String, paramsJSON: String?) -> String {
        queue.sync {
            guard let connection = db else {
                return #"{"error":"Database not open"}"#
            }
            return performQuery(connection: connection, sql: sql, paramsJSON: paramsJSON)
        }
    }

    // MARK: - Private

    private func configurePragmas() throws {
        guard let connection = db else { return }
        // `journal_mode = WAL`, `synchronous = NORMAL`,
        // `foreign_keys = ON`, `temp_store = MEMORY`, and the
        // SQLCipher PRAGMAs are already applied by
        // `EncryptedSQLiteOpener.open(...)`. Only the
        // plugin-specific `busy_timeout` lives here so a slow
        // plugin SQL call doesn't bail with SQLITE_BUSY when the
        // host is doing background maintenance.
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(connection, "PRAGMA busy_timeout=5000", nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw PluginDatabaseError.failedToExecute("PRAGMA failed: \(msg)")
        }

        try applyMaxPageCount(connection: connection)
    }

    /// Caps total DB size at `maxBytes` via `PRAGMA max_page_count`.
    /// Reads the live `page_size` (SQLCipher defaults to 4096 but the
    /// opener may override) and divides — `max_page_count` is rounded
    /// down so the *actual* disk ceiling is always ≤ `maxBytes`.
    /// SQLite returns `SQLITE_FULL` (`database or disk is full`) when
    /// an INSERT/UPDATE would push past the cap; the plugin sees a
    /// normal SQL error in the JSON envelope, no host-side crash.
    private func applyMaxPageCount(connection: OpaquePointer) throws {
        guard maxBytes > 0 else { return }

        // Read the actual page_size SQLCipher selected for this DB.
        var pageStmt: OpaquePointer?
        var pageSize: Int64 = 4096  // safe fallback
        if sqlite3_prepare_v2(connection, "PRAGMA page_size", -1, &pageStmt, nil) == SQLITE_OK,
            sqlite3_step(pageStmt) == SQLITE_ROW
        {
            pageSize = sqlite3_column_int64(pageStmt, 0)
        }
        sqlite3_finalize(pageStmt)
        guard pageSize > 0 else { return }

        let maxPages = max(1, maxBytes / pageSize)
        let pragma = "PRAGMA max_page_count=\(maxPages)"
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(connection, pragma, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw PluginDatabaseError.failedToExecute("PRAGMA max_page_count failed: \(msg)")
        }
    }

    private func performExec(connection: OpaquePointer, sql: String, paramsJSON: String?) -> String {
        if isForbiddenStatement(sql) {
            return #"{"error":"Forbidden SQL statement"}"#
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(connection))
            return #"{"error":"\#(escapeJSON(msg))"}"#
        }
        defer { sqlite3_finalize(stmt) }

        if let paramsJSON, !paramsJSON.isEmpty {
            bindParams(stmt: stmt!, paramsJSON: paramsJSON)
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(connection))
            return #"{"error":"\#(escapeJSON(msg))"}"#
        }

        let changes = sqlite3_changes(connection)
        let lastId = sqlite3_last_insert_rowid(connection)
        return #"{"changes":\#(changes),"last_insert_rowid":\#(lastId)}"#
    }

    private func performQuery(connection: OpaquePointer, sql: String, paramsJSON: String?) -> String {
        if isForbiddenStatement(sql) {
            return #"{"error":"Forbidden SQL statement"}"#
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(connection))
            return #"{"error":"\#(escapeJSON(msg))"}"#
        }
        defer { sqlite3_finalize(stmt) }

        if let paramsJSON, !paramsJSON.isEmpty {
            bindParams(stmt: stmt!, paramsJSON: paramsJSON)
        }

        let colCount = sqlite3_column_count(stmt)
        var columns: [String] = []
        for i in 0 ..< colCount {
            let name = sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col\(i)"
            columns.append(name)
        }

        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for i in 0 ..< colCount {
                let colType = sqlite3_column_type(stmt, i)
                let value: String
                switch colType {
                case SQLITE_NULL:
                    value = "null"
                case SQLITE_INTEGER:
                    value = "\(sqlite3_column_int64(stmt, i))"
                case SQLITE_FLOAT:
                    value = "\(sqlite3_column_double(stmt, i))"
                case SQLITE_TEXT:
                    let text = String(cString: sqlite3_column_text(stmt, i))
                    value = "\"\(escapeJSON(text))\""
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, i)
                    if let blob = sqlite3_column_blob(stmt, i) {
                        let data = Data(bytes: blob, count: Int(bytes))
                        value = "\"\(data.base64EncodedString())\""
                    } else {
                        value = "null"
                    }
                default:
                    value = "null"
                }
                row.append(value)
            }
            rows.append(row)
        }

        let colJSON = "[" + columns.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",") + "]"
        let rowsJSON =
            "["
            + rows.map { row in
                "[" + row.joined(separator: ",") + "]"
            }.joined(separator: ",") + "]"

        return #"{"columns":\#(colJSON),"rows":\#(rowsJSON)}"#
    }

    private func bindParams(stmt: OpaquePointer, paramsJSON: String) {
        guard let data = paramsJSON.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return }

        for (i, param) in arr.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            case let intVal as Int:
                sqlite3_bind_int64(stmt, idx, Int64(intVal))
            case let dblVal as Double:
                sqlite3_bind_double(stmt, idx, dblVal)
            case let strVal as String:
                sqlite3_bind_text(stmt, idx, (strVal as NSString).utf8String, -1, Self.sqliteTransient)
            case let boolVal as Bool:
                sqlite3_bind_int(stmt, idx, boolVal ? 1 : 0)
            default:
                if let jsonData = try? JSONSerialization.data(withJSONObject: param, options: .osaurusCanonical),
                    let jsonStr = String(data: jsonData, encoding: .utf8)
                {
                    sqlite3_bind_text(stmt, idx, (jsonStr as NSString).utf8String, -1, Self.sqliteTransient)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            }
        }
    }

    /// Blocks ATTACH DATABASE and other potentially dangerous statements
    private func isForbiddenStatement(_ sql: String) -> Bool {
        let upper = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.hasPrefix("ATTACH") { return true }
        if upper.hasPrefix("DETACH") { return true }
        if upper.contains("LOAD_EXTENSION") { return true }
        return false
    }

    private func escapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
