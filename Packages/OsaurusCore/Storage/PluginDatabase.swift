//
//  PluginDatabase.swift
//  osaurus
//
//  Sandboxed per-plugin SQLite database.
//  Each plugin gets its own isolated database for structured data storage.
//

import Foundation
import SQLite3

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

    /// SQLite SQLITE_TRANSIENT destructor: tells SQLite to make its own copy of bound data.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(pluginId: String) {
        self.pluginId = pluginId
    }

    deinit {
        close()
    }

    // MARK: - Lifecycle

    /// Opens an in-memory SQLite database (for tests).
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            var dbPointer: OpaquePointer?
            let result = sqlite3_open(":memory:", &dbPointer)
            guard result == SQLITE_OK, let connection = dbPointer else {
                let message = String(cString: sqlite3_errmsg(dbPointer))
                sqlite3_close(dbPointer)
                throw PluginDatabaseError.failedToOpen(message)
            }
            db = connection
            try configurePragmas()
        }
    }

    func open() throws {
        try queue.sync {
            guard db == nil else { return }

            OsaurusPaths.ensureExistsSilent(OsaurusPaths.pluginDataDirectory(for: pluginId))

            let path = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
            var dbPointer: OpaquePointer?
            let result = sqlite3_open(path, &dbPointer)
            guard result == SQLITE_OK, let connection = dbPointer else {
                let message = String(cString: sqlite3_errmsg(dbPointer))
                sqlite3_close(dbPointer)
                throw PluginDatabaseError.failedToOpen(message)
            }
            db = connection

            try configurePragmas()
        }
    }

    func close() {
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

        let pragmas = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA foreign_keys=ON",
            "PRAGMA busy_timeout=5000",
        ]

        for pragma in pragmas {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(connection, pragma, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errMsg)
                throw PluginDatabaseError.failedToExecute("PRAGMA failed: \(msg)")
            }
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
                if let jsonData = try? JSONSerialization.data(withJSONObject: param),
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
