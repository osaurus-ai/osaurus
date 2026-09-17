//
//  FileWriteDocumentRouting.swift
//  osaurus
//
//  `file_write` document generation by extension: `.xlsx` from CSV/TSV
//  text or JSON rows, `.docx` / `.pdf` from Markdown or HTML. Builds the
//  `StructuredDocument`, runs it through the registered emitters, and
//  reports the shape the tool envelope needs (format, counts, bytes).
//  Sandbox containment, undo logging, and the envelope itself stay in
//  `FileWriteTool`.
//

import CoreGraphics
import Foundation

enum FileWriteDocumentRouting {
    enum Target: String, Sendable {
        case xlsx
        case docx
        case pdf

        var formatId: String { rawValue }

        var contentHint: String {
            switch self {
            case .xlsx:
                return
                    "CSV or TSV text (one sheet; delimiter sniffed) or JSON `{\"sheets\":[{\"name\":\"Q1\",\"rows\":[[\"Region\",\"Revenue\"],[\"West\",1200]]}]}`"
            case .docx, .pdf:
                return "Markdown (headings, lists, tables, code) or HTML"
            }
        }
    }

    enum RoutingError: LocalizedError {
        case emptyContent
        case invalidJSON(String)
        case noRows
        case tooManySheets(Int, max: Int)
        case tooManyRows(Int, max: Int)
        case tooManyColumns(Int, max: Int)
        case validation([WorkbookValidationIssue])
        case renderFailed(String)
        case missingEmitter(String)

        var errorDescription: String? {
            switch self {
            case .emptyContent:
                return "`content` is empty; provide the document body."
            case .invalidJSON(let reason):
                return "`content` looks like JSON but is not a valid workbook description (\(reason)). "
                    + "Expected {\"sheets\":[{\"name\":..., \"rows\":[[...]]}]} or a JSON array of rows."
            case .noRows:
                return "No rows were found in `content`; provide CSV/TSV text or JSON rows."
            case .tooManySheets(let count, let max):
                return "\(count) sheets exceed the \(max)-sheet limit."
            case .tooManyRows(let count, let max):
                return "\(count) rows exceed the \(max)-row limit for one sheet; split the data or write CSV instead."
            case .tooManyColumns(let count, let max):
                return "\(count) columns exceed the \(max)-column limit."
            case .validation(let issues):
                return "Workbook validation failed: " + issues.map(\.message).joined(separator: "; ")
            case .renderFailed(let reason):
                return reason
            case .missingEmitter(let format):
                return "No \(format) writer is registered."
            }
        }
    }

    static func target(forExtension ext: String) -> Target? {
        Target(rawValue: ext.lowercased())
    }

    // MARK: - Plan (shared by dry run and write)

    struct Plan {
        let target: Target
        let document: StructuredDocument
        /// Payload fields describing the document (`sheets`, `rows`,
        /// `estimated_pages`, `syntax`, ...).
        var summary: [String: Any]
    }

    static func plan(target: Target, content: String, filename: String) throws -> Plan {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RoutingError.emptyContent }
        switch target {
        case .xlsx:
            let workbook = try buildWorkbook(from: content)
            let sheetSummaries = workbook.sheets.map { sheet -> [String: Any] in
                [
                    "name": sheet.name,
                    "rows": sheet.rows.count,
                    "columns": sheet.rows.map { $0.cells.count }.max() ?? 0,
                ]
            }
            let document = StructuredDocument(
                formatId: "xlsx",
                filename: filename,
                fileSize: 0,
                representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
                security: .notInspected(formatId: "xlsx", fileExtension: "xlsx", sourceTrust: .generatedArtifact),
                textFallback: ""
            )
            let issues = WorkbookWorkflowService.validationIssues(for: workbook)
            let blocking = issues.filter { $0.severity == .error }
            if !blocking.isEmpty { throw RoutingError.validation(blocking) }
            return Plan(
                target: target,
                document: document,
                summary: [
                    "sheets": workbook.sheets.count,
                    "rows": workbook.sheets.reduce(0) { $0 + $1.rows.count },
                    "sheet_summaries": sheetSummaries,
                    "input": detectedWorkbookInput(content).rawValue,
                ]
            )
        case .docx, .pdf:
            let syntax = MarkdownRichTextRenderer.sniffSyntax(content)
            let source = RichTextSourceDocument(
                markup: content,
                syntax: syntax == .html ? .html : .markdown,
                title: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            )
            let document = StructuredDocument(
                formatId: target.formatId,
                filename: filename,
                fileSize: 0,
                representation: AnyStructuredRepresentation(formatId: target.formatId, underlying: source),
                security: .notInspected(
                    formatId: target.formatId,
                    fileExtension: target.rawValue,
                    sourceTrust: .generatedArtifact
                ),
                textFallback: content
            )
            var summary: [String: Any] = [
                "input": syntax.rawValue,
                "characters": content.count,
            ]
            if target == .pdf {
                summary["estimated_pages"] = max(1, Int((Double(content.count) / 3_000).rounded(.up)))
            }
            return Plan(target: target, document: document, summary: summary)
        }
    }

    // MARK: - Write

    struct Written {
        let bytesWritten: Int64
        var extra: [String: Any] = [:]
    }

    static func write(
        _ plan: Plan,
        to url: URL,
        registry: DocumentFormatRegistry = .shared
    ) async throws -> Written {
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch plan.target {
        case .xlsx:
            let result = try await WorkbookWorkflowService.export(plan.document, to: url, registry: registry)
            return Written(bytesWritten: result.bytesWritten)
        case .docx, .pdf:
            guard let emitter = registry.emitter(for: plan.document) else {
                throw RoutingError.missingEmitter(plan.target.rawValue)
            }
            do {
                try await emitter.emit(plan.document, to: url)
            } catch let error as DocumentAdapterError {
                throw RoutingError.renderFailed(error.localizedDescription)
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            var extra: [String: Any] = [:]
            if plan.target == .pdf, let pages = pdfPageCount(at: url) {
                extra["pages"] = pages
            }
            return Written(bytesWritten: size, extra: extra)
        }
    }

    private static func pdfPageCount(at url: URL) -> Int? {
        guard let provider = CGDataProvider(url: url as CFURL),
            let document = CGPDFDocument(provider)
        else { return nil }
        return document.numberOfPages
    }

    // MARK: - Workbook building

    enum WorkbookInput: String {
        case csv
        case tsv
        case json
    }

    static let maxSheets = 20
    static let maxRowsPerSheet = 100_000
    static let maxColumns = 1_024

    static func detectedWorkbookInput(_ content: String) -> WorkbookInput {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        // Delimiter sniff on the first non-empty line: tabs win when present.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.contains("\t") ? .tsv : .csv
    }

    static func buildWorkbook(from content: String) throws -> Workbook {
        switch detectedWorkbookInput(content) {
        case .json:
            return try workbook(fromJSON: content)
        case .csv:
            return try workbook(fromDelimited: content, delimiter: .comma)
        case .tsv:
            return try workbook(fromDelimited: content, delimiter: .tab)
        }
    }

    private static func workbook(fromDelimited text: String, delimiter: CSVDelimiter) throws -> Workbook {
        let parsed = CSVRowParser.parseRows(source: text, delimiter: delimiter)
        let rows: [[Any]] = parsed.map { row in
            row.cells.map { $0.wasQuoted ? ($0.text as Any) : (typed($0.text) as Any) }
        }
        // Drop a trailing empty row produced by a final newline.
        let trimmedRows = trimTrailingEmptyRows(rows)
        guard !trimmedRows.isEmpty else { throw RoutingError.noRows }
        return try workbook(sheets: [("Sheet1", trimmedRows)])
    }

    private static func workbook(fromJSON text: String) throws -> Workbook {
        guard let data = text.data(using: .utf8) else { throw RoutingError.invalidJSON("not UTF-8") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RoutingError.invalidJSON(error.localizedDescription)
        }
        var sheets: [(String, [[Any]])] = []
        if let dict = object as? [String: Any] {
            if let sheetList = dict["sheets"] as? [[String: Any]] {
                for (index, sheet) in sheetList.enumerated() {
                    let name = (sheet["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sheet\(index + 1)"
                    guard let rows = sheet["rows"] as? [[Any]] else {
                        throw RoutingError.invalidJSON("sheet \(index + 1) has no `rows` array of arrays")
                    }
                    sheets.append((name, rows))
                }
            } else if let rows = dict["rows"] as? [[Any]] {
                let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sheet1"
                sheets.append((name, rows))
            } else {
                throw RoutingError.invalidJSON("top-level object needs `sheets` or `rows`")
            }
        } else if let rows = object as? [[Any]] {
            sheets.append(("Sheet1", rows))
        } else if let records = object as? [[String: Any]], !records.isEmpty {
            // Array of objects: header from the union of keys (first-seen order).
            var headers: [String] = []
            for record in records {
                for key in record.keys.sorted() where !headers.contains(key) { headers.append(key) }
            }
            var rows: [[Any]] = [headers]
            for record in records {
                rows.append(headers.map { record[$0] ?? "" })
            }
            sheets.append(("Sheet1", rows))
        } else {
            throw RoutingError.invalidJSON(
                "expected an object with `sheets`/`rows`, an array of rows, or an array of objects"
            )
        }
        return try workbook(sheets: sheets)
    }

    /// Build a typed `Workbook` from raw rows (`String` / numeric / `Bool` /
    /// `nil` cells) — shared by the `.xlsx` write route and `db_export`.
    static func workbook(sheets: [(String, [[Any]])]) throws -> Workbook {
        guard !sheets.isEmpty else { throw RoutingError.noRows }
        if sheets.count > maxSheets { throw RoutingError.tooManySheets(sheets.count, max: maxSheets) }
        var built: [Workbook.Sheet] = []
        var usedNames: Set<String> = []
        for (index, entry) in sheets.enumerated() {
            var name = sanitizeSheetName(entry.0)
            if usedNames.contains(name.lowercased()) { name = "\(name.prefix(27))_\(index + 1)" }
            usedNames.insert(name.lowercased())
            let rows = trimTrailingEmptyRows(entry.1)
            if rows.count > maxRowsPerSheet { throw RoutingError.tooManyRows(rows.count, max: maxRowsPerSheet) }
            var sheetRows: [Workbook.Row] = []
            for (rowOffset, rawRow) in rows.enumerated() {
                if rawRow.count > maxColumns { throw RoutingError.tooManyColumns(rawRow.count, max: maxColumns) }
                let rowNumber = rowOffset + 1
                var cells: [Workbook.Cell] = []
                for (columnOffset, rawValue) in rawRow.enumerated() {
                    let value = cellValue(rawValue)
                    if case .empty = value { continue }
                    let columnNumber = columnOffset + 1
                    let reference = "\(columnLetters(columnNumber))\(rowNumber)"
                    cells.append(
                        Workbook.Cell(
                            reference: reference,
                            rowNumber: rowNumber,
                            columnNumber: columnNumber,
                            value: value,
                            formula: nil,
                            anchor: DocumentAnchor(
                                kind: .cell,
                                path: [
                                    .init(kind: .document),
                                    .init(kind: .sheet, identifier: name, index: index),
                                    .init(kind: .cell, identifier: reference),
                                ],
                                sourceRange: DocumentSourceRange(
                                    start: .cell(
                                        sheetName: name,
                                        rowIndex: rowNumber - 1,
                                        columnIndex: columnNumber - 1
                                    )
                                ),
                                label: "\(name)!\(reference)"
                            )
                        )
                    )
                }
                guard !cells.isEmpty else { continue }
                sheetRows.append(
                    Workbook.Row(
                        number: rowNumber,
                        cells: cells,
                        anchor: DocumentAnchor(
                            kind: .row,
                            path: [
                                .init(kind: .document),
                                .init(kind: .sheet, identifier: name, index: index),
                                .init(kind: .row, index: rowNumber - 1),
                            ],
                            sourceRange: DocumentSourceRange(
                                start: DocumentSourceLocation(
                                    sheetIndex: index,
                                    sheetName: name,
                                    rowIndex: rowNumber - 1
                                )
                            ),
                            label: "\(name) row \(rowNumber)"
                        )
                    )
                )
            }
            built.append(
                Workbook.Sheet(
                    name: name,
                    index: index,
                    rows: sheetRows,
                    anchor: DocumentAnchor(
                        kind: .sheet,
                        path: [
                            .init(kind: .document),
                            .init(kind: .sheet, identifier: name, index: index),
                        ],
                        sourceRange: DocumentSourceRange(
                            start: DocumentSourceLocation(sheetIndex: index, sheetName: name)
                        ),
                        label: name,
                        metadata: ["sheetIndex": "\(index)"]
                    )
                )
            )
        }
        guard built.contains(where: { !$0.rows.isEmpty }) else { throw RoutingError.noRows }
        return Workbook(sheets: built)
    }

    // MARK: - Cell typing

    /// Numbers and booleans are typed; everything else stays text. Quoted
    /// CSV fields are kept as text by the caller so "00123" survives.
    static func typed(_ text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        switch trimmed.lowercased() {
        case "true": return true
        case "false": return false
        default: break
        }
        // Only plain decimal numbers (optional sign) become numeric cells. Exponent
        // notation, thousands separators, and leading-zero codes stay text.
        if let number = Double(trimmed),
            trimmed.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil,
            !(trimmed.count > 1 && trimmed.hasPrefix("0") && !trimmed.hasPrefix("0."))
        {
            return number
        }
        return text
    }

    private static func cellValue(_ raw: Any) -> Workbook.CellValue {
        switch raw {
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            // JSONSerialization booleans are NSNumber-backed; distinguish them.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let double as Double:
            return .number(double)
        case let int as Int:
            return .number(Double(int))
        case let int64 as Int64:
            return .number(Double(int64))
        case let string as String:
            return string.isEmpty ? .empty : .string(string)
        case is NSNull:
            return .empty
        case let array as [Any]:
            return .string(array.map { "\($0)" }.joined(separator: ", "))
        default:
            return .string(String(describing: raw))
        }
    }

    private static func trimTrailingEmptyRows(_ rows: [[Any]]) -> [[Any]] {
        var out = rows
        while let last = out.last, isEmptyRow(last) { out.removeLast() }
        return out
    }

    private static func isEmptyRow(_ row: [Any]) -> Bool {
        row.allSatisfy { value in
            if let string = value as? String { return string.trimmingCharacters(in: .whitespaces).isEmpty }
            return value is NSNull
        }
    }

    private static func sanitizeSheetName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: #"[\\/\?\*\[\]:]"#, with: "_", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "Sheet" }
        if cleaned.count > 31 { cleaned = String(cleaned.prefix(31)) }
        return cleaned
    }

    static func columnLetters(_ column: Int) -> String {
        var n = column
        var letters = ""
        while n > 0 {
            let rem = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = (n - 1) / 26
        }
        return letters
    }
}
