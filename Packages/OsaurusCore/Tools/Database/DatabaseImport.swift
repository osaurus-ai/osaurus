//
//  DatabaseImport.swift
//  osaurus
//
//  Host-side parser for `db_import` (spec: Agent DB "superpowers"). Reads a
//  CSV / TSV / JSON / JSONL payload off disk into typed rows the bulk-write
//  engine (`AgentDatabase.importRows`) can ingest in chunked transactions —
//  so a large data load costs zero model tokens per row and never touches
//  the `file_read` character cap or the tool-call budget.
//
//  This file is parsing only. Path resolution lives in `DBImportTool`
//  (the agent tool) and the Data tab UI; schema resolution, table creation,
//  and the bulk write are shared in `AgentImportRunner`.
//

import Foundation

enum DatabaseImport {
    /// Largest file we'll read into memory for an import. Imports are meant
    /// to be big, but we still bound RAM — past this the agent should split
    /// the file or stream it through `db_execute`.
    static let maxBytes = 64 * 1024 * 1024

    /// Per-column sample size used to infer SQLite type affinity for a
    /// freshly created table. Inference only needs a representative prefix.
    static let typeSampleLimit = 500

    enum Format: String, Sendable {
        case csv
        case tsv
        case json
        case jsonl
    }

    enum ImportError: LocalizedError {
        case undecodableText
        case noRows
        case badJSON(String)
        case headerlessNeedsColumns
        case tooLarge(bytes: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .undecodableText:
                return "File is not valid UTF-8 text; cannot parse as CSV/TSV/JSON."
            case .noRows:
                return "No data rows were found in the file."
            case .badJSON(let m):
                return "Could not parse JSON: \(m)"
            case .headerlessNeedsColumns:
                return
                    "has_header is false but no `columns` were provided — supply the "
                    + "ordered column names so the rows can be mapped."
            case .tooLarge(let bytes, let limit):
                return
                    "File is \(bytes) bytes, over the \(limit)-byte import limit. "
                    + "Split it or load it in parts."
            }
        }
    }

    /// The outcome of parsing a file: typed rows plus enough metadata for the
    /// tool to build its result summary and (optionally) infer a schema.
    struct Parsed: Sendable {
        var columns: [String]
        var rows: [[String: AgentSQLValue]]
        /// Column → inferred SQLite affinity (`TEXT` / `INTEGER` / `REAL`).
        var inferredTypes: [String: String]
        var rowsSkipped: Int
        var truncated: Bool
        var errors: [String]
    }

    // MARK: - Format detection

    /// Resolve a format from (in priority order) an explicit hint, the file
    /// extension, then a content sniff. `txt` and unknown extensions fall
    /// through to the sniff.
    static func detectFormat(explicit: String?, path: String, sample: String) -> Format {
        if let hint = explicit?.lowercased(), !hint.isEmpty {
            switch hint {
            case "csv": return .csv
            case "tsv": return .tsv
            case "json": return .json
            case "jsonl", "ndjson": return .jsonl
            default: break  // e.g. "txt" → sniff
            }
        }
        switch (path as NSString).pathExtension.lowercased() {
        case "csv": return .csv
        case "tsv": return .tsv
        case "json": return .json
        case "jsonl", "ndjson": return .jsonl
        default: break
        }

        let trimmed = sample.drop(while: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        if let first = trimmed.first {
            if first == "[" { return .json }
            if first == "{" {
                let objectLines = sample.split(whereSeparator: \.isNewline)
                    .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
                return objectLines.count > 1 ? .jsonl : .json
            }
        }
        let firstLine = sample.split(whereSeparator: \.isNewline).first.map(String.init) ?? sample
        let tabs = firstLine.filter { $0 == "\t" }.count
        let commas = firstLine.filter { $0 == "," }.count
        return tabs > commas ? .tsv : .csv
    }

    // MARK: - Top-level parse

    static func parse(
        data: Data,
        format: Format,
        hasHeader: Bool,
        explicitColumns: [String]?,
        maxRows: Int?
    ) throws -> Parsed {
        guard data.count <= maxBytes else {
            throw ImportError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        switch format {
        case .csv, .tsv:
            let delimiter: Character = (format == .tsv) ? "\t" : ","
            guard let text = String(data: data, encoding: .utf8) else {
                throw ImportError.undecodableText
            }
            return try parseDelimited(
                text: text,
                delimiter: delimiter,
                hasHeader: hasHeader,
                explicitColumns: explicitColumns,
                maxRows: maxRows
            )
        case .json:
            return try parseJSON(data: data, maxRows: maxRows)
        case .jsonl:
            guard let text = String(data: data, encoding: .utf8) else {
                throw ImportError.undecodableText
            }
            return try parseJSONLines(text: text, maxRows: maxRows)
        }
    }

    // MARK: - Delimited (CSV / TSV)

    /// RFC-4180-ish delimited parser: handles quoted fields, embedded
    /// delimiters / newlines, and `""` escapes. CRLF and bare CR are
    /// normalized to record breaks.
    static func parseDelimited(
        text: String,
        delimiter: Character,
        hasHeader: Bool,
        explicitColumns: [String]?,
        maxRows: Int?
    ) throws -> Parsed {
        var records = scanDelimited(text, delimiter: delimiter)
        // Drop a trailing empty record produced by a final newline.
        if let last = records.last, last.count == 1, last[0].isEmpty {
            records.removeLast()
        }
        guard !records.isEmpty else { throw ImportError.noRows }

        let columns: [String]
        var dataRecords: ArraySlice<[String]>
        if let explicit = explicitColumns, !explicit.isEmpty {
            columns = explicit
            dataRecords = hasHeader ? records.dropFirst() : records[...]
        } else if hasHeader {
            columns = records[0].map { sanitizeHeader($0) }
            dataRecords = records.dropFirst()
        } else {
            throw ImportError.headerlessNeedsColumns
        }
        guard !columns.isEmpty else { throw ImportError.noRows }

        var rows: [[String: AgentSQLValue]] = []
        rows.reserveCapacity(dataRecords.count)
        var sampler = TypeSampler(columns: columns)
        var skipped = 0
        var truncated = false

        for record in dataRecords {
            if record.count == 1 && record[0].isEmpty {
                skipped += 1
                continue  // blank line
            }
            if let cap = maxRows, rows.count >= cap {
                truncated = true
                break
            }
            var row: [String: AgentSQLValue] = [:]
            for (i, column) in columns.enumerated() where i < record.count {
                let raw = record[i]
                let value = typedValue(raw)
                if case .null = value { continue }  // let column default apply
                row[column] = value
                sampler.observe(column: column, value: value)
            }
            if row.isEmpty {
                skipped += 1
                continue
            }
            rows.append(row)
        }
        if rows.isEmpty { throw ImportError.noRows }

        // The delimited parser is lenient (blank/short records are skipped,
        // not errored), so it surfaces no per-row error strings.
        return Parsed(
            columns: columns,
            rows: rows,
            inferredTypes: sampler.affinities(),
            rowsSkipped: skipped,
            truncated: truncated,
            errors: []
        )
    }

    /// Split delimited text into records of fields. State machine so quotes
    /// can contain the delimiter and newlines.
    private static func scanDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let following = nextChar() {
                        if following == "\"" {
                            field.append("\"")  // escaped quote
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
                continue
            }

            switch ch {
            case "\"":
                inQuotes = true
            case delimiter:
                record.append(field)
                field = ""
            case "\n":
                record.append(field)
                records.append(record)
                field = ""
                record = []
            case "\r":
                // Treat CR / CRLF as a single record break.
                record.append(field)
                records.append(record)
                field = ""
                record = []
                if let following = nextChar() {
                    if following != "\n" { pending = following }
                }
            default:
                field.append(ch)
            }
        }
        // Flush the final field / record (no trailing newline).
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// Strip a UTF-8 BOM and surrounding whitespace from a header cell.
    private static func sanitizeHeader(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("\u{feff}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - JSON

    private static func parseJSON(data: Data, maxRows: Int?) throws -> Parsed {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportError.badJSON(error.localizedDescription)
        }

        let elements: [Any]
        if let array = object as? [Any] {
            elements = array
        } else if let dict = object as? [String: Any] {
            // Accept a single wrapper object `{ "data": [ ... ] }` as well as
            // a single bare record.
            if dict.count == 1, let only = dict.values.first as? [Any] {
                elements = only
            } else {
                elements = [dict]
            }
        } else {
            throw ImportError.badJSON("top-level JSON must be an array or object")
        }
        return try buildRowsFromObjects(elements, maxRows: maxRows)
    }

    private static func parseJSONLines(text: String, maxRows: Int?) throws -> Parsed {
        var elements: [Any] = []
        var skipped = 0
        var errors: [String] = []
        for (lineNumber, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
            else {
                skipped += 1
                if errors.count < 10 { errors.append("line \(lineNumber + 1): not valid JSON") }
                continue
            }
            elements.append(obj)
        }
        var parsed = try buildRowsFromObjects(elements, maxRows: maxRows)
        parsed.rowsSkipped += skipped
        parsed.errors.append(contentsOf: errors)
        if parsed.errors.count > 10 { parsed.errors = Array(parsed.errors.prefix(10)) }
        return parsed
    }

    /// Shared row builder for JSON / JSONL: union the object keys (first-seen
    /// order) into the column list, type each value, and infer affinity.
    private static func buildRowsFromObjects(_ elements: [Any], maxRows: Int?) throws -> Parsed {
        var columns: [String] = []
        var seen = Set<String>()
        var rows: [[String: AgentSQLValue]] = []
        var sampler = TypeSampler(columns: [])
        var skipped = 0
        var truncated = false
        var errors: [String] = []

        for element in elements {
            guard let dict = element as? [String: Any] else {
                skipped += 1
                if errors.count < 10 { errors.append("skipped a non-object element") }
                continue
            }
            if let cap = maxRows, rows.count >= cap {
                truncated = true
                break
            }
            var row: [String: AgentSQLValue] = [:]
            for (key, rawValue) in dict {
                if !seen.contains(key) {
                    seen.insert(key)
                    columns.append(key)
                }
                let value = sqlValue(fromJSON: rawValue)
                if case .null = value { continue }
                row[key] = value
                sampler.observe(column: key, value: value)
            }
            if row.isEmpty {
                skipped += 1
                continue
            }
            rows.append(row)
        }
        if rows.isEmpty { throw ImportError.noRows }

        // Stable column order: union order matches first-seen iteration above.
        return Parsed(
            columns: columns,
            rows: rows,
            inferredTypes: sampler.affinities(forColumns: columns),
            rowsSkipped: skipped,
            truncated: truncated,
            errors: errors
        )
    }

    // MARK: - Value typing

    /// Coerce a delimited string cell into a typed value. Empty → null;
    /// integral / floating strings → numbers; everything else → text. Bools
    /// stay text (CSV "true"/"false" is too ambiguous to coerce safely).
    static func typedValue(_ raw: String) -> AgentSQLValue {
        if raw.isEmpty { return .null }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .text(raw) }
        if isIntegerLiteral(trimmed), let i = Int64(trimmed) { return .integer(i) }
        if isDecimalLiteral(trimmed), let d = Double(trimmed) { return .double(d) }
        return .text(raw)
    }

    /// Map a JSON value (from `JSONSerialization`) to an `AgentSQLValue`.
    /// Nested arrays / objects are re-encoded as compact JSON text.
    static func sqlValue(fromJSON value: Any) -> AgentSQLValue {
        if value is NSNull { return .null }
        if let n = value as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" { return .bool(n.boolValue) }
            if Double(n.int64Value) == n.doubleValue { return .integer(n.int64Value) }
            return .double(n.doubleValue)
        }
        if let s = value as? String { return .text(s) }
        if JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let text = String(data: data, encoding: .utf8)
        {
            return .text(text)
        }
        return .text(String(describing: value))
    }

    private static func isIntegerLiteral(_ s: String) -> Bool {
        var chars = Substring(s)
        if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
        guard !chars.isEmpty else { return false }
        return chars.allSatisfy { $0.isNumber && $0.isASCII }
    }

    private static func isDecimalLiteral(_ s: String) -> Bool {
        var seenDigit = false
        var seenDot = false
        var seenExp = false
        var index = s.startIndex
        if s.first == "+" || s.first == "-" { index = s.index(after: index) }
        while index < s.endIndex {
            let ch = s[index]
            if ch.isNumber && ch.isASCII {
                seenDigit = true
            } else if ch == "." && !seenDot && !seenExp {
                seenDot = true
            } else if (ch == "e" || ch == "E") && seenDigit && !seenExp {
                seenExp = true
                let next = s.index(after: index)
                if next < s.endIndex, s[next] == "+" || s[next] == "-" {
                    index = next
                }
            } else {
                return false
            }
            index = s.index(after: index)
        }
        return seenDigit && (seenDot || seenExp)
    }

    // MARK: - Type sampler

    /// Accumulates the value kinds seen per column so we can pick an
    /// affinity (`INTEGER` if all-integer, `REAL` if all-numeric, else
    /// `TEXT`) when creating a fresh table.
    private struct TypeSampler {
        private struct ColumnStats {
            var samples = 0
            var allInteger = true
            var allNumeric = true
        }
        private var stats: [String: ColumnStats]

        init(columns: [String]) {
            stats = [:]
            for column in columns { stats[column] = ColumnStats() }
        }

        mutating func observe(column: String, value: AgentSQLValue) {
            var entry = stats[column] ?? ColumnStats()
            guard entry.samples < DatabaseImport.typeSampleLimit else { return }
            entry.samples += 1
            switch value {
            case .integer, .bool:
                break  // integer-compatible
            case .double:
                entry.allInteger = false
            case .text, .blob, .null:
                entry.allInteger = false
                entry.allNumeric = false
            }
            stats[column] = entry
        }

        func affinities() -> [String: String] {
            var out: [String: String] = [:]
            for (column, entry) in stats {
                out[column] = affinity(for: entry)
            }
            return out
        }

        func affinities(forColumns columns: [String]) -> [String: String] {
            var out: [String: String] = [:]
            for column in columns {
                out[column] = affinity(for: stats[column] ?? ColumnStats())
            }
            return out
        }

        private func affinity(for entry: ColumnStats) -> String {
            guard entry.samples > 0 else { return "TEXT" }
            if entry.allInteger { return "INTEGER" }
            if entry.allNumeric { return "REAL" }
            return "TEXT"
        }
    }
}
