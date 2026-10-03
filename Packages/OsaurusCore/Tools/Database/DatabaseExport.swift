//
//  DatabaseExport.swift
//  osaurus
//
//  Host-side writer for `db_export`. Streams query rows to CSV / JSON /
//  JSONL on disk so large result sets never pass through model tokens.
//

import Foundation

enum DatabaseExport {
    enum Format: String, Sendable {
        case csv
        case json
        case jsonl
        case xlsx

        static func detect(path: String, explicit: String?) -> Format? {
            if let explicit {
                let lower = explicit.lowercased()
                switch lower {
                case "csv": return .csv
                case "json": return .json
                case "jsonl", "ndjson": return .jsonl
                case "xlsx": return .xlsx
                default: return nil
                }
            }
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "csv": return .csv
            case "json": return .json
            case "jsonl", "ndjson": return .jsonl
            case "xlsx": return .xlsx
            default: return nil
            }
        }
    }

    /// Row cap for an `.xlsx` export: the workbook is assembled in memory
    /// (one sheet, header + rows) before the package is written.
    static let maxXLSXRows = FileWriteDocumentRouting.maxRowsPerSheet

    struct Result: Sendable {
        var rowsExported: Int
        var bytesWritten: Int
        var truncated: Bool
        var columns: [String]
    }

    enum ExportError: LocalizedError {
        case unsupportedFormat(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f):
                return "Unsupported export format `\(f)`. Use csv, json, jsonl, or xlsx."
            case .writeFailed(let m):
                return m
            }
        }
    }

    /// Stream rows from `rowSource` to `url`, stopping when `maxBytes` is
    /// reached. `headerColumns` is written even when zero rows are emitted
    /// (CSV/JSON array open). Return false from `emit` to stop early.
    static func streamWrite(
        url: URL,
        format: Format,
        maxBytes: Int,
        headerColumns: [String] = [],
        rowSource: (_ emit: (_ columns: [String], _ row: [AgentSQLValue]) throws -> Bool) throws -> Void
    ) throws -> Result {
        switch format {
        case .csv:
            return try streamCSV(
                url: url,
                maxBytes: maxBytes,
                headerColumns: headerColumns,
                rowSource: rowSource
            )
        case .json:
            return try streamJSON(
                url: url,
                maxBytes: maxBytes,
                headerColumns: headerColumns,
                rowSource: rowSource
            )
        case .jsonl:
            return try streamJSONL(url: url, maxBytes: maxBytes, rowSource: rowSource)
        case .xlsx:
            return try writeXLSX(
                url: url,
                maxBytes: maxBytes,
                headerColumns: headerColumns,
                rowSource: rowSource
            )
        }
    }

    /// `.xlsx` export: rows are collected (bounded by `maxXLSXRows` and an
    /// estimated `maxBytes` of cell text) into one typed sheet and written
    /// as a real workbook package via `XLSXEmitter`, readable by
    /// `file_read`'s workbook preview and re-importable by `db_import`.
    private static func writeXLSX(
        url: URL,
        maxBytes: Int,
        headerColumns: [String],
        rowSource: (_ emit: (_ columns: [String], _ row: [AgentSQLValue]) throws -> Bool) throws -> Void
    ) throws -> Result {
        var columns = headerColumns
        var rows: [[Any]] = []
        var estimatedBytes = 0
        var truncated = false

        try rowSource { cols, row in
            if columns.isEmpty { columns = cols }
            // Header + this row must fit the sheet row cap.
            if rows.count + 1 >= maxXLSXRows {
                truncated = true
                return false
            }
            let cells: [Any] = row.map { sqlValueToCell($0) }
            let rowBytes = cells.reduce(0) { $0 + String(describing: $1).utf8.count + 1 }
            if estimatedBytes + rowBytes > maxBytes {
                truncated = true
                return false
            }
            estimatedBytes += rowBytes
            rows.append(cells)
            return true
        }

        let sheetName = url.deletingPathExtension().lastPathComponent
        let allRows: [[Any]] = [columns.map { $0 as Any }] + rows
        let workbook: Workbook
        do {
            workbook = try FileWriteDocumentRouting.workbook(
                sheets: [(sheetName.isEmpty ? "Export" : sheetName, allRows)])
        } catch {
            throw ExportError.writeFailed("Could not build the workbook: \(error.localizedDescription)")
        }
        let data: Data
        do {
            data = try XLSXEmitter.packageBytes(for: workbook)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed("Could not write the .xlsx package: \(error.localizedDescription)")
        }
        return Result(
            rowsExported: rows.count,
            bytesWritten: data.count,
            truncated: truncated,
            columns: columns
        )
    }

    /// Typed cell for a workbook: numbers and booleans keep their type,
    /// text stays text, NULL becomes an empty cell, blobs are base64.
    private static func sqlValueToCell(_ value: AgentSQLValue) -> Any {
        switch value {
        case .null: return ""
        case .integer(let n): return n
        case .double(let d): return d
        case .text(let s): return s
        case .bool(let b): return b
        case .blob(let data): return data.base64EncodedString()
        }
    }

    private static func streamCSV(
        url: URL,
        maxBytes: Int,
        headerColumns: [String],
        rowSource: (_ emit: (_ columns: [String], _ row: [AgentSQLValue]) throws -> Bool) throws -> Void
    ) throws -> Result {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var columns = headerColumns
        var exported = 0
        var bytesWritten = 0
        var truncated = false
        var headerWritten = false

        func writeHeaderIfNeeded(_ cols: [String]) throws -> Bool {
            guard !headerWritten, !cols.isEmpty else { return true }
            columns = cols
            let header = csvLine(columns) + "\n"
            let headerData = Data(header.utf8)
            if headerData.count > maxBytes {
                truncated = true
                return false
            }
            try handle.write(contentsOf: headerData)
            bytesWritten += headerData.count
            headerWritten = true
            return true
        }

        if !headerColumns.isEmpty {
            guard try writeHeaderIfNeeded(headerColumns) else {
                return Result(rowsExported: 0, bytesWritten: bytesWritten, truncated: true, columns: columns)
            }
        }

        try rowSource { cols, row in
            guard try writeHeaderIfNeeded(cols) else { return false }
            let line = csvLine(row.map { sqlValueToExportString($0) }) + "\n"
            let lineData = Data(line.utf8)
            if bytesWritten + lineData.count > maxBytes {
                truncated = true
                return false
            }
            try handle.write(contentsOf: lineData)
            bytesWritten += lineData.count
            exported += 1
            return true
        }

        return Result(
            rowsExported: exported,
            bytesWritten: bytesWritten,
            truncated: truncated,
            columns: columns
        )
    }

    private static func streamJSON(
        url: URL,
        maxBytes: Int,
        headerColumns: [String],
        rowSource: (_ emit: (_ columns: [String], _ row: [AgentSQLValue]) throws -> Bool) throws -> Void
    ) throws -> Result {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var columns: [String] = headerColumns
        var exported = 0
        var bytesWritten = 0
        var truncated = false
        var started = false

        try handle.write(contentsOf: Data("[".utf8))
        bytesWritten += 1

        try rowSource { cols, row in
            columns = cols
            var object: [String: Any] = [:]
            for (index, column) in columns.enumerated() {
                let value = index < row.count ? row[index] : .null
                object[column] = sqlValueToJSON(value)
            }
            let prefix = started ? Data(",".utf8) : Data()
            let rowData = (try JSONSerialization.data(withJSONObject: object))
            let chunk = prefix + rowData
            if bytesWritten + chunk.count + 1 > maxBytes {
                truncated = true
                return false
            }
            try handle.write(contentsOf: chunk)
            bytesWritten += chunk.count
            started = true
            exported += 1
            return true
        }

        let suffix = Data("]".utf8)
        if bytesWritten + suffix.count <= maxBytes {
            try handle.write(contentsOf: suffix)
            bytesWritten += suffix.count
        } else {
            truncated = true
        }

        return Result(
            rowsExported: exported,
            bytesWritten: bytesWritten,
            truncated: truncated,
            columns: columns
        )
    }

    private static func streamJSONL(
        url: URL,
        maxBytes: Int,
        rowSource: (_ emit: (_ columns: [String], _ row: [AgentSQLValue]) throws -> Bool) throws -> Void
    ) throws -> Result {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var columns: [String] = []
        var exported = 0
        var bytesWritten = 0
        var truncated = false

        try rowSource { cols, row in
            columns = cols
            var object: [String: Any] = [:]
            for (index, column) in columns.enumerated() {
                let value = index < row.count ? row[index] : .null
                object[column] = sqlValueToJSON(value)
            }
            let rowData = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            if bytesWritten + rowData.count > maxBytes {
                truncated = true
                return false
            }
            try handle.write(contentsOf: rowData)
            bytesWritten += rowData.count
            exported += 1
            return true
        }

        return Result(
            rowsExported: exported,
            bytesWritten: bytesWritten,
            truncated: truncated,
            columns: columns
        )
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map(csvEscape).joined(separator: ",")
    }

    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func sqlValueToExportString(_ value: AgentSQLValue) -> String {
        switch value {
        case .null: return ""
        case .integer(let n): return String(n)
        case .double(let d): return String(d)
        case .text(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .blob(let data): return data.base64EncodedString()
        }
    }

    private static func sqlValueToJSON(_ value: AgentSQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let n): return NSNumber(value: n)
        case .double(let d): return NSNumber(value: d)
        case .text(let s): return s
        case .bool(let b): return NSNumber(value: b)
        case .blob(let data): return data.base64EncodedString()
        }
    }
}
