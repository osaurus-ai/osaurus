//
//  SQLiteReadOnlyRecordStreamer.swift
//  osaurus
//
//  Small bridge for first-party plugin packs that need to inspect user
//  SQLite files without linking a second SQLite implementation.
//

import Foundation
import OsaurusSQLCipher

/// SQLite read failures include only table names or row numbers so plugin
/// logs never leak user-selected paths.
public enum SQLiteReadOnlyRecordStreamerError: LocalizedError, Equatable, Sendable {
    case openFailed(String)
    case pragmaFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case noUserTables

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "SQLite read-only open failed: \(message)"
        case .pragmaFailed(let message):
            return "SQLite read-only PRAGMA failed: \(message)"
        case .prepareFailed(let message):
            return "SQLite read-only query prepare failed: \(message)"
        case .stepFailed(let message):
            return "SQLite read-only query step failed: \(message)"
        case .noUserTables:
            return "SQLite database does not contain user tables"
        }
    }
}

/// Streams plaintext SQLite rows as plugin `Record` values through the
/// existing vendored SQLCipher target. Keeping this helper in core avoids a
/// new system-library dependency while preserving a read-only boundary.
public enum SQLiteReadOnlyRecordStreamer {
    public static func streamRecords(
        from url: URL,
        documentReference: DocumentReference,
        rowLimitPerTable: Int = 1_000,
        into continuation: AsyncStream<Record>.Continuation
    ) async throws {
        precondition(rowLimitPerTable > 0, "rowLimitPerTable must be positive")

        let database = try openReadOnlyDatabase(path: url.path)
        defer { sqlite3_close(database) }

        try execute(database, sql: "PRAGMA query_only = ON", required: true)
        try execute(database, sql: "PRAGMA trusted_schema = OFF", required: false)

        let tables = try userTables(in: database)
        guard !tables.isEmpty else {
            throw SQLiteReadOnlyRecordStreamerError.noUserTables
        }

        var recordIndex = 0
        for table in tables {
            try Task.checkCancellation()
            recordIndex = try await streamTable(
                table,
                database: database,
                documentReference: documentReference,
                rowLimit: rowLimitPerTable,
                startingRecordIndex: recordIndex,
                into: continuation
            )
        }
    }

    private static func openReadOnlyDatabase(path: String) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(path, &connection, flags, nil)
        guard result == SQLITE_OK, let database = connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(connection)
            throw SQLiteReadOnlyRecordStreamerError.openFailed(message)
        }
        return database
    }

    private static func execute(_ database: OpaquePointer, sql: String, required: Bool) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            if required {
                throw SQLiteReadOnlyRecordStreamerError.pragmaFailed(message)
            }
        }
    }

    private static func userTables(in database: OpaquePointer) throws -> [String] {
        let sql = """
            SELECT name FROM sqlite_schema
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteReadOnlyRecordStreamerError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var tables: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteReadOnlyRecordStreamerError.stepFailed(String(cString: sqlite3_errmsg(database)))
            }
            if let text = sqlite3_column_text(statement, 0) {
                tables.append(String(cString: text))
            }
        }
        return tables
    }

    private static func streamTable(
        _ table: String,
        database: OpaquePointer,
        documentReference: DocumentReference,
        rowLimit: Int,
        startingRecordIndex: Int,
        into continuation: AsyncStream<Record>.Continuation
    ) async throws -> Int {
        let sql = "SELECT * FROM \(quotedIdentifier(table)) LIMIT \(rowLimit)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteReadOnlyRecordStreamerError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        let columns = (0 ..< columnCount).map { index in
            sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column_\(index)"
        }

        var tableRowIndex = 0
        var recordIndex = startingRecordIndex
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteReadOnlyRecordStreamerError.stepFailed(String(cString: sqlite3_errmsg(database)))
            }

            let fields = (0 ..< columnCount).map { value(statement: statement, column: $0) }
            continuation.yield(
                Record(
                    index: recordIndex,
                    fields: fields,
                    anchorIdentifier: "sqlite/\(table)/rows/\(tableRowIndex)",
                    metadata: [
                        "documentId": documentReference.id.uuidString,
                        "formatIdentifier": documentReference.formatIdentifier,
                        "table": table,
                        "rowIndex": "\(tableRowIndex)",
                        "columns": columns.joined(separator: "\t"),
                    ]
                )
            )
            tableRowIndex += 1
            recordIndex += 1
        }
        return recordIndex
    }

    private static func value(statement: OpaquePointer, column: Int32) -> String {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return ""
        case SQLITE_INTEGER:
            return "\(sqlite3_column_int64(statement, column))"
        case SQLITE_FLOAT:
            return "\(sqlite3_column_double(statement, column))"
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        case SQLITE_BLOB:
            return "<blob:\(sqlite3_column_bytes(statement, column)) bytes>"
        default:
            return ""
        }
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
