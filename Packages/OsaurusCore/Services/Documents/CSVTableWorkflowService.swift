//
//  CSVTableWorkflowService.swift
//  osaurus
//
//  Table workflow helpers for CSV/TSV documents: bounded previews, schema
//  inference, and explicit delimited-text export.
//

import Foundation

public struct CSVTablePreviewPolicy: Codable, Equatable, Sendable {
    public let maxPreviewBytes: Int
    public let maxRows: Int
    public let maxColumns: Int
    public let maxSampleValuesPerColumn: Int
    public let maxCellPreviewUTF16Units: Int

    public init(
        maxPreviewBytes: Int = 1 * 1024 * 1024,
        maxRows: Int = 1_000,
        maxColumns: Int = 200,
        maxSampleValuesPerColumn: Int = 5,
        maxCellPreviewUTF16Units: Int = 512
    ) {
        self.maxPreviewBytes = max(1, maxPreviewBytes)
        self.maxRows = max(1, maxRows)
        self.maxColumns = max(1, maxColumns)
        self.maxSampleValuesPerColumn = max(0, maxSampleValuesPerColumn)
        self.maxCellPreviewUTF16Units = max(1, maxCellPreviewUTF16Units)
    }

    public static let standard = CSVTablePreviewPolicy()
}

public enum CSVInferredColumnType: String, Codable, Hashable, Sendable {
    case empty
    case integer
    case decimal
    case boolean
    case date
    case string
    case mixed
}

public struct CSVColumnPreview: Codable, Equatable, Sendable {
    public let index: Int
    public let name: String
    public let inferredType: CSVInferredColumnType
    public let nonEmptyCount: Int
    public let emptyCount: Int
    public let distinctSampleCount: Int
    public let maxUTF16Length: Int
    public let sampleValues: [String]
}

public struct CSVSampleRow: Codable, Equatable, Sendable {
    public let rowIndex: Int
    public let values: [String]
    public let sourceRange: DocumentTextRange?
    public let truncatedCellTextCount: Int
}

public struct CSVTablePreview: Codable, Equatable, Sendable {
    public let formatId: String
    public let filename: String
    public let fileSize: Int64
    public let delimiter: CSVDelimiter
    public let hasHeader: Bool
    public let sourceBytesRead: Int
    public let rowsScanned: Int
    public let sampledRows: [CSVSampleRow]
    public let columns: [CSVColumnPreview]
    public let truncatedByByteLimit: Bool
    public let truncatedByRowLimit: Bool
    public let truncatedByColumnLimit: Bool

    public var sampledRowCount: Int { sampledRows.count }
    public var columnCount: Int { columns.count }
}

public struct CSVTableExportPolicy: Codable, Equatable, Sendable {
    public let maxRows: Int
    public let maxColumns: Int
    public let maxCells: Int
    public let maxCellTextUTF16Units: Int
    public let allowFormulaLikeText: Bool

    public init(
        maxRows: Int = 1_000_000,
        maxColumns: Int = 16_384,
        maxCells: Int = 2_000_000,
        maxCellTextUTF16Units: Int = 32_767,
        allowFormulaLikeText: Bool = false
    ) {
        self.maxRows = max(1, maxRows)
        self.maxColumns = max(1, maxColumns)
        self.maxCells = max(1, maxCells)
        self.maxCellTextUTF16Units = max(1, maxCellTextUTF16Units)
        self.allowFormulaLikeText = allowFormulaLikeText
    }

    public static let standard = CSVTableExportPolicy()
}

public struct CSVTableExportIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case noRows
        case tooManyRows
        case tooManyColumns
        case tooManyCells
        case overlongCellText
        case formulaLikeText
        case invalidText
    }

    public let code: Code
    public let message: String
    public let rowIndex: Int?
    public let columnIndex: Int?
}

public struct CSVTableExportResult: Codable, Equatable, Sendable {
    public let url: URL
    public let formatId: String
    public let delimiter: CSVDelimiter
    public let rowCount: Int
    public let columnCount: Int
    public let bytesWritten: Int64
}

public enum CSVTableWorkflowError: LocalizedError, Sendable {
    case notCSV(formatId: String)
    case emptyPreview
    case validationFailed([CSVTableExportIssue])
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notCSV(let formatId):
            return "Document format '\(formatId)' does not contain a CSV/TSV table representation"
        case .emptyPreview:
            return "CSV/TSV preview contains no complete rows"
        case .validationFailed(let issues):
            let first = issues.first?.message ?? "CSV/TSV export failed validation"
            return "CSV/TSV export validation failed: \(first)"
        case .writeFailed(let message):
            return "CSV/TSV export failed: \(message)"
        }
    }
}

public enum CSVTableWorkflowService {
    public static func preview(
        _ document: StructuredDocument,
        policy: CSVTablePreviewPolicy = .standard
    ) throws -> CSVTablePreview {
        guard let csv = document.representation.underlying as? CSVDocument else {
            throw CSVTableWorkflowError.notCSV(formatId: document.formatId)
        }
        let rows = csv.rows.map { row in
            SourceRow(
                rowIndex: row.rowIndex,
                values: row.cells.map(\.text),
                sourceRange: row.sourceRange
            )
        }
        return try buildPreview(
            filename: document.filename,
            fileSize: document.fileSize,
            delimiter: csv.delimiter,
            rows: rows,
            sourceBytesRead: Int(min(document.fileSize, Int64(Int.max))),
            truncatedByByteLimit: false,
            policy: policy
        )
    }

    public static func preview(
        url: URL,
        delimiter: CSVDelimiter,
        policy: CSVTablePreviewPolicy = .standard
    ) async throws -> CSVTablePreview {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let prefix = try readPreviewPrefix(url: url, policy: policy)
        let parsedRows = CSVRowParser.parseRows(source: prefix.source, delimiter: delimiter)
        let rows = parsedRows.enumerated().map { index, row in
            SourceRow(rowIndex: index, values: row.cells.map(\.text), sourceRange: row.sourceRange)
        }
        return try buildPreview(
            filename: url.lastPathComponent,
            fileSize: fileSize,
            delimiter: delimiter,
            rows: rows,
            sourceBytesRead: prefix.bytesRead,
            truncatedByByteLimit: prefix.truncatedByByteLimit,
            policy: policy
        )
    }

    public static func export(
        _ document: StructuredDocument,
        to url: URL,
        delimiter: CSVDelimiter,
        policy: CSVTableExportPolicy = .standard
    ) async throws -> CSVTableExportResult {
        guard let csv = document.representation.underlying as? CSVDocument else {
            throw CSVTableWorkflowError.notCSV(formatId: document.formatId)
        }
        let issues = validationIssues(for: csv, policy: policy)
        guard issues.isEmpty else {
            throw CSVTableWorkflowError.validationFailed(issues)
        }

        do {
            try await CSVEmitter(
                delimiter: delimiter,
                allowFormulaLikeText: policy.allowFormulaLikeText
            ).emit(document, to: url)
            let bytesWritten = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return CSVTableExportResult(
                url: url,
                formatId: delimiter.formatId,
                delimiter: delimiter,
                rowCount: csv.rowCount,
                columnCount: csv.columnCount,
                bytesWritten: bytesWritten
            )
        } catch let error as CSVTableWorkflowError {
            throw error
        } catch let error as DocumentAdapterError {
            throw CSVTableWorkflowError.writeFailed(error.localizedDescription)
        } catch {
            throw CSVTableWorkflowError.writeFailed(error.localizedDescription)
        }
    }

    public static func validationIssues(
        for csv: CSVDocument,
        policy: CSVTableExportPolicy = .standard
    ) -> [CSVTableExportIssue] {
        var validator = CSVTableExportValidator(policy: policy)
        return validator.validate(csv)
    }

    private static func buildPreview(
        filename: String,
        fileSize: Int64,
        delimiter: CSVDelimiter,
        rows: [SourceRow],
        sourceBytesRead: Int,
        truncatedByByteLimit: Bool,
        policy: CSVTablePreviewPolicy
    ) throws -> CSVTablePreview {
        guard !rows.isEmpty else { throw CSVTableWorkflowError.emptyPreview }

        let truncatedByRowLimit = rows.count > policy.maxRows
        let sampledSourceRows = Array(rows.prefix(policy.maxRows))
        let maxObservedColumns = sampledSourceRows.map(\.values.count).max() ?? 0
        let visibleColumnCount = min(maxObservedColumns, policy.maxColumns)
        let truncatedByColumnLimit = maxObservedColumns > policy.maxColumns
        let hasHeader = inferHasHeader(rows: sampledSourceRows, columnCount: visibleColumnCount)
        let dataRows = hasHeader ? Array(sampledSourceRows.dropFirst()) : sampledSourceRows
        let columns = buildColumns(
            rows: dataRows.isEmpty ? sampledSourceRows : dataRows,
            headerRow: hasHeader ? sampledSourceRows.first : nil,
            columnCount: visibleColumnCount,
            policy: policy
        )
        let sampledRows = sampledSourceRows.map { row in
            let values = row.values.prefix(visibleColumnCount).map {
                truncate($0, maxUTF16Units: policy.maxCellPreviewUTF16Units).value
            }
            let truncatedCellTextCount = row.values.prefix(visibleColumnCount).filter {
                truncate($0, maxUTF16Units: policy.maxCellPreviewUTF16Units).wasTruncated
            }.count
            return CSVSampleRow(
                rowIndex: row.rowIndex,
                values: Array(values),
                sourceRange: row.sourceRange,
                truncatedCellTextCount: truncatedCellTextCount
            )
        }

        return CSVTablePreview(
            formatId: delimiter.formatId,
            filename: filename,
            fileSize: fileSize,
            delimiter: delimiter,
            hasHeader: hasHeader,
            sourceBytesRead: sourceBytesRead,
            rowsScanned: sampledSourceRows.count,
            sampledRows: sampledRows,
            columns: columns,
            truncatedByByteLimit: truncatedByByteLimit,
            truncatedByRowLimit: truncatedByRowLimit,
            truncatedByColumnLimit: truncatedByColumnLimit
        )
    }

    private static func readPreviewPrefix(
        url: URL,
        policy: CSVTablePreviewPolicy
    ) throws -> (source: String, bytesRead: Int, truncatedByByteLimit: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: policy.maxPreviewBytes + 1) ?? Data()
        let truncated = data.count > policy.maxPreviewBytes
        let prefixData = truncated ? data.prefix(policy.maxPreviewBytes) : data[...]
        let prefixBytes = Array(prefixData)
        var source =
            String(bytes: prefixBytes, encoding: .utf8)
            ?? String(bytes: prefixBytes, encoding: .isoLatin1)
            ?? ""
        if truncated {
            source = trimTrailingPartialRow(source)
        }
        return (source, prefixData.count, truncated)
    }

    private static func trimTrailingPartialRow(_ source: String) -> String {
        guard let lastNewline = source.lastIndex(where: { $0 == "\n" || $0 == "\r" }) else {
            return source
        }
        return String(source[...lastNewline])
    }

    private static func inferHasHeader(rows: [SourceRow], columnCount: Int) -> Bool {
        guard rows.count >= 2, columnCount > 0 else { return false }
        let first = rows[0].values
        let names = first.prefix(columnCount).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.contains(where: { !$0.isEmpty }) else { return false }
        guard Set(names.filter { !$0.isEmpty }.map { $0.lowercased() }).count == names.filter({ !$0.isEmpty }).count
        else { return false }

        let dataRows = Array(rows.dropFirst())
        for columnIndex in 0 ..< columnCount {
            let headerType = classify(names[safe: columnIndex] ?? "")
            let dataTypes = dataRows.compactMap { row -> CSVInferredColumnType? in
                let value = row.values[safe: columnIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !value.isEmpty else { return nil }
                return classify(value)
            }
            if headerType == .string, dataTypes.contains(where: { $0 != .string && $0 != .mixed }) {
                return true
            }
        }
        return false
    }

    private static func buildColumns(
        rows: [SourceRow],
        headerRow: SourceRow?,
        columnCount: Int,
        policy: CSVTablePreviewPolicy
    ) -> [CSVColumnPreview] {
        var usedNames: [String: Int] = [:]
        return (0 ..< columnCount).map { columnIndex in
            let rawName = headerRow?.values[safe: columnIndex]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = rawName?.isEmpty == false ? rawName! : "Column \(columnIndex + 1)"
            let name = uniqueName(baseName, usedNames: &usedNames)
            let values = rows.map { $0.values[safe: columnIndex] ?? "" }
            let nonEmptyValues = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var sampleValues: [String] = []
            var seenSamples: Set<String> = []
            for value in nonEmptyValues where sampleValues.count < policy.maxSampleValuesPerColumn {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard seenSamples.insert(normalized).inserted else { continue }
                sampleValues.append(truncate(normalized, maxUTF16Units: policy.maxCellPreviewUTF16Units).value)
            }
            return CSVColumnPreview(
                index: columnIndex,
                name: name,
                inferredType: inferType(values: nonEmptyValues),
                nonEmptyCount: nonEmptyValues.count,
                emptyCount: values.count - nonEmptyValues.count,
                distinctSampleCount: Set(nonEmptyValues).count,
                maxUTF16Length: values.map { $0.utf16.count }.max() ?? 0,
                sampleValues: sampleValues
            )
        }
    }

    private static func uniqueName(_ value: String, usedNames: inout [String: Int]) -> String {
        let normalized = value.lowercased()
        let next = (usedNames[normalized] ?? 0) + 1
        usedNames[normalized] = next
        return next == 1 ? value : "\(value) (\(next))"
    }

    private static func inferType(values: [String]) -> CSVInferredColumnType {
        let types = Set(values.map { classify($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        guard !types.isEmpty else { return .empty }
        if types.count == 1 { return types.first! }
        if types.isSubset(of: [.integer, .decimal]) { return .decimal }
        return .mixed
    }

    private static func classify(_ value: String) -> CSVInferredColumnType {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if isBoolean(trimmed) { return .boolean }
        if Int64(trimmed) != nil { return .integer }
        if Double(trimmed) != nil { return .decimal }
        if isISODate(trimmed) { return .date }
        return .string
    }

    private static func isBoolean(_ value: String) -> Bool {
        switch value.lowercased() {
        case "true", "false":
            return true
        default:
            return false
        }
    }

    private static func isISODate(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}([T ][0-9:.+-Zz]+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func truncate(_ value: String, maxUTF16Units: Int) -> (value: String, wasTruncated: Bool) {
        guard value.utf16.count > maxUTF16Units else { return (value, false) }
        var result = ""
        result.reserveCapacity(maxUTF16Units)
        for character in value {
            if result.utf16.count + String(character).utf16.count > maxUTF16Units { break }
            result.append(character)
        }
        return (result, true)
    }

    private struct SourceRow {
        let rowIndex: Int
        let values: [String]
        let sourceRange: DocumentTextRange?
    }
}

private struct CSVTableExportValidator {
    private let policy: CSVTableExportPolicy
    private var issues: [CSVTableExportIssue] = []
    private var totalCells = 0

    init(policy: CSVTableExportPolicy) {
        self.policy = policy
    }

    mutating func validate(_ csv: CSVDocument) -> [CSVTableExportIssue] {
        issues = []
        totalCells = 0

        if csv.rows.isEmpty {
            add(.noRows, "CSV/TSV export requires at least one row.")
        }
        if csv.rows.count > policy.maxRows {
            add(.tooManyRows, "CSV/TSV export has \(csv.rows.count) rows, limit is \(policy.maxRows).")
        }
        for row in csv.rows {
            validate(row)
        }
        if totalCells > policy.maxCells {
            add(.tooManyCells, "CSV/TSV export has \(totalCells) cells, limit is \(policy.maxCells).")
        }
        return issues
    }

    private mutating func validate(_ row: CSVRow) {
        if row.cells.count > policy.maxColumns {
            add(
                .tooManyColumns,
                "Row \(row.rowIndex + 1) has \(row.cells.count) cells, limit is \(policy.maxColumns).",
                rowIndex: row.rowIndex
            )
        }
        for cell in row.cells {
            validate(cell)
        }
    }

    private mutating func validate(_ cell: CSVCell) {
        totalCells += 1
        if cell.text.utf16.count > policy.maxCellTextUTF16Units {
            add(
                .overlongCellText,
                "R\(cell.rowIndex + 1)C\(cell.columnIndex + 1) exceeds "
                    + "\(policy.maxCellTextUTF16Units) UTF-16 units.",
                rowIndex: cell.rowIndex,
                columnIndex: cell.columnIndex
            )
        }
        if !policy.allowFormulaLikeText, Self.isFormulaLike(cell.text) {
            add(
                .formulaLikeText,
                "R\(cell.rowIndex + 1)C\(cell.columnIndex + 1) starts with a spreadsheet formula prefix.",
                rowIndex: cell.rowIndex,
                columnIndex: cell.columnIndex
            )
        }
        if cell.text.unicodeScalars.contains(where: { !Self.isAllowedTextScalar($0) }) {
            add(
                .invalidText,
                "R\(cell.rowIndex + 1)C\(cell.columnIndex + 1) contains an unsupported control character.",
                rowIndex: cell.rowIndex,
                columnIndex: cell.columnIndex
            )
        }
    }

    private static func isFormulaLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "=" || first == "@" { return true }
        if first == "+" || first == "-", Double(trimmed) == nil { return true }
        return false
    }

    private static func isAllowedTextScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:
            return true
        case 0x20 ... 0xD7FF, 0xE000 ... 0xFFFD, 0x10000 ... 0x10FFFF:
            return true
        default:
            return false
        }
    }

    private mutating func add(
        _ code: CSVTableExportIssue.Code,
        _ message: String,
        rowIndex: Int? = nil,
        columnIndex: Int? = nil
    ) {
        issues.append(
            CSVTableExportIssue(
                code: code,
                message: message,
                rowIndex: rowIndex,
                columnIndex: columnIndex
            )
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
