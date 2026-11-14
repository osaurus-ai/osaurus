//
//  WorkbookWorkflowService.swift
//  osaurus
//
//  Inspection and export orchestration for typed workbook documents. This is
//  deliberately a service, not an agent-facing default tool: callers must come
//  through an explicit UI/plugin/export surface and a registered emitter.
//

import Foundation

public struct WorkbookExportPolicy: Codable, Equatable, Sendable {
    public let maxSheets: Int
    public let maxRowsPerSheet: Int
    public let maxColumnsPerSheet: Int
    public let maxCells: Int
    public let maxMergedRanges: Int
    public let maxCellTextUTF16Units: Int
    public let allowFormulaCells: Bool

    public init(
        maxSheets: Int = 1_024,
        maxRowsPerSheet: Int = 1_048_576,
        maxColumnsPerSheet: Int = 16_384,
        maxCells: Int = 1_000_000,
        maxMergedRanges: Int = 100_000,
        maxCellTextUTF16Units: Int = 32_767,
        allowFormulaCells: Bool = false
    ) {
        self.maxSheets = max(1, maxSheets)
        self.maxRowsPerSheet = max(1, maxRowsPerSheet)
        self.maxColumnsPerSheet = max(1, maxColumnsPerSheet)
        self.maxCells = max(1, maxCells)
        self.maxMergedRanges = max(0, maxMergedRanges)
        self.maxCellTextUTF16Units = max(1, maxCellTextUTF16Units)
        self.allowFormulaCells = allowFormulaCells
    }

    public static let xlsxExport = WorkbookExportPolicy()
    /// `file_write` workbooks: cells the model wrote as `=…` are real formulas.
    public static let xlsxExportWithFormulas = WorkbookExportPolicy(allowFormulaCells: true)
}

public struct WorkbookValidationIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case warning
        case error
    }

    public enum Code: String, Codable, Hashable, Sendable {
        case noSheets
        case tooManySheets
        case invalidSheetIndex
        case invalidSheetName
        case duplicateSheetName
        case rowOutOfBounds
        case duplicateRow
        case columnOutOfBounds
        case cellRowMismatch
        case duplicateCell
        case invalidCellReference
        case overlongCellText
        case invalidXMLText
        case formulaNotWritable
        case nonFiniteNumber
        case invalidMergedRange
        case tooManyCells
        case tooManyMergedRanges
        case noRenderableCells
    }

    public let severity: Severity
    public let code: Code
    public let message: String
    public let sheetName: String?
    public let cellReference: String?

    public init(
        severity: Severity,
        code: Code,
        message: String,
        sheetName: String? = nil,
        cellReference: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.sheetName = sheetName
        self.cellReference = cellReference
    }
}

public struct WorkbookSheetWorkflowSummary: Codable, Equatable, Sendable {
    public let name: String
    public let index: Int
    public let rowCount: Int
    public let cellCount: Int
    public let formulaCellCount: Int
    public let mergedRangeCount: Int
    public let maxColumn: Int

    public init(
        name: String,
        index: Int,
        rowCount: Int,
        cellCount: Int,
        formulaCellCount: Int,
        mergedRangeCount: Int,
        maxColumn: Int
    ) {
        self.name = name
        self.index = index
        self.rowCount = rowCount
        self.cellCount = cellCount
        self.formulaCellCount = formulaCellCount
        self.mergedRangeCount = mergedRangeCount
        self.maxColumn = maxColumn
    }
}

public struct WorkbookExportAvailability: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        case available
        case missingEmitter
        case invalidWorkbook
        case notChecked
    }

    public let reason: Reason
    public let formatId: String?
    public let message: String

    public var canExport: Bool { reason == .available }

    public init(reason: Reason, formatId: String?, message: String) {
        self.reason = reason
        self.formatId = formatId
        self.message = message
    }
}

public struct WorkbookWorkflowInspection: Codable, Equatable, Sendable {
    public let formatId: String
    public let filename: String
    public let sheetSummaries: [WorkbookSheetWorkflowSummary]
    public let totalRows: Int
    public let totalCells: Int
    public let formulaCellCount: Int
    public let mergedRangeCount: Int
    public let validationIssues: [WorkbookValidationIssue]
    public let exportAvailability: WorkbookExportAvailability

    public var blockingIssues: [WorkbookValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    public var isValidForExport: Bool {
        blockingIssues.isEmpty && exportAvailability.canExport
    }
}

public struct WorkbookExportResult: Codable, Equatable, Sendable {
    public let url: URL
    public let formatId: String
    public let bytesWritten: Int64
    public let inspection: WorkbookWorkflowInspection
}

public enum WorkbookWorkflowError: LocalizedError, Sendable {
    case notWorkbook(formatId: String)
    case missingEmitter(formatId: String)
    case validationFailed([WorkbookValidationIssue])
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notWorkbook(let formatId):
            return "Document format '\(formatId)' does not contain a workbook representation"
        case .missingEmitter(let formatId):
            return "No registered emitter can export workbook format '\(formatId)'"
        case .validationFailed(let issues):
            let first = issues.first?.message ?? "Workbook failed validation"
            return "Workbook validation failed: \(first)"
        case .writeFailed(let message):
            return "Workbook export failed: \(message)"
        }
    }
}

public enum WorkbookWorkflowService {
    public static func inspect(
        _ document: StructuredDocument,
        registry: DocumentFormatRegistry? = .shared,
        policy: WorkbookExportPolicy = .xlsxExport
    ) throws -> WorkbookWorkflowInspection {
        guard let workbook = document.representation.underlying as? Workbook else {
            throw WorkbookWorkflowError.notWorkbook(formatId: document.formatId)
        }

        let issues = validationIssues(for: workbook, policy: policy)
        let availability = exportAvailability(
            for: document,
            registry: registry,
            hasBlockingIssues: issues.contains { $0.severity == .error }
        )
        let sheetSummaries = workbook.sheets.map(sheetSummary)

        return WorkbookWorkflowInspection(
            formatId: document.formatId,
            filename: document.filename,
            sheetSummaries: sheetSummaries,
            totalRows: sheetSummaries.reduce(0) { $0 + $1.rowCount },
            totalCells: sheetSummaries.reduce(0) { $0 + $1.cellCount },
            formulaCellCount: sheetSummaries.reduce(0) { $0 + $1.formulaCellCount },
            mergedRangeCount: sheetSummaries.reduce(0) { $0 + $1.mergedRangeCount },
            validationIssues: issues,
            exportAvailability: availability
        )
    }

    public static func export(
        _ document: StructuredDocument,
        to url: URL,
        registry: DocumentFormatRegistry = .shared,
        policy: WorkbookExportPolicy = .xlsxExport
    ) async throws -> WorkbookExportResult {
        let inspection = try inspect(document, registry: registry, policy: policy)
        if !inspection.blockingIssues.isEmpty {
            throw WorkbookWorkflowError.validationFailed(inspection.blockingIssues)
        }
        guard let emitter = registry.emitter(for: document) else {
            throw WorkbookWorkflowError.missingEmitter(formatId: document.formatId)
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await emitter.emit(document, to: url)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return WorkbookExportResult(
                url: url,
                formatId: emitter.formatId,
                bytesWritten: size,
                inspection: inspection
            )
        } catch let error as WorkbookWorkflowError {
            throw error
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw WorkbookWorkflowError.writeFailed(error.localizedDescription)
        }
    }

    public static func validationIssues(
        for workbook: Workbook,
        policy: WorkbookExportPolicy = .xlsxExport
    ) -> [WorkbookValidationIssue] {
        var validator = WorkbookWorkflowValidator(policy: policy)
        return validator.validate(workbook)
    }

    private static func exportAvailability(
        for document: StructuredDocument,
        registry: DocumentFormatRegistry?,
        hasBlockingIssues: Bool
    ) -> WorkbookExportAvailability {
        guard !hasBlockingIssues else {
            return WorkbookExportAvailability(
                reason: .invalidWorkbook,
                formatId: document.formatId,
                message: "Workbook has validation errors that must be fixed before export."
            )
        }
        guard let registry else {
            return WorkbookExportAvailability(
                reason: .notChecked,
                formatId: document.formatId,
                message: "No registry was provided, so exporter availability was not checked."
            )
        }
        if let emitter = registry.emitter(for: document) {
            return WorkbookExportAvailability(
                reason: .available,
                formatId: emitter.formatId,
                message: "Workbook can be exported through the registered '\(emitter.formatId)' emitter."
            )
        }
        return WorkbookExportAvailability(
            reason: .missingEmitter,
            formatId: document.formatId,
            message: "Workbook export requires a registered emitter; no default workbook write tool is exposed."
        )
    }

    private static func sheetSummary(_ sheet: Workbook.Sheet) -> WorkbookSheetWorkflowSummary {
        let cells = sheet.rows.flatMap(\.cells)
        return WorkbookSheetWorkflowSummary(
            name: sheet.name,
            index: sheet.index,
            rowCount: sheet.rows.count,
            cellCount: cells.count,
            formulaCellCount: cells.filter { $0.formula != nil }.count,
            mergedRangeCount: sheet.mergedRanges.count,
            maxColumn: cells.map(\.columnNumber).max() ?? 0
        )
    }
}

private struct WorkbookWorkflowValidator {
    private let policy: WorkbookExportPolicy
    private var issues: [WorkbookValidationIssue] = []
    private var totalCells = 0
    private var totalMergedRanges = 0
    private var hasRenderableCell = false

    init(policy: WorkbookExportPolicy) {
        self.policy = policy
    }

    mutating func validate(_ workbook: Workbook) -> [WorkbookValidationIssue] {
        issues = []
        totalCells = 0
        totalMergedRanges = 0
        hasRenderableCell = false

        if workbook.sheets.isEmpty {
            add(.noSheets, "Workbook must contain at least one sheet.")
        }
        if workbook.sheets.count > policy.maxSheets {
            add(.tooManySheets, "Workbook has \(workbook.sheets.count) sheets, limit is \(policy.maxSheets).")
        }

        var normalizedNames: Set<String> = []
        for (offset, sheet) in workbook.sheets.enumerated() {
            validateSheet(sheet, expectedIndex: offset, normalizedNames: &normalizedNames)
        }

        if totalCells > policy.maxCells {
            add(.tooManyCells, "Workbook has \(totalCells) cells, limit is \(policy.maxCells).")
        }
        if totalMergedRanges > policy.maxMergedRanges {
            add(
                .tooManyMergedRanges,
                "Workbook has \(totalMergedRanges) merged ranges, limit is \(policy.maxMergedRanges)."
            )
        }
        if !hasRenderableCell {
            add(.noRenderableCells, "Workbook must contain at least one non-empty renderable cell.")
        }
        return issues
    }

    private mutating func validateSheet(
        _ sheet: Workbook.Sheet,
        expectedIndex: Int,
        normalizedNames: inout Set<String>
    ) {
        if sheet.index != expectedIndex {
            add(
                .invalidSheetIndex,
                "Sheet '\(sheet.name)' has index \(sheet.index), expected \(expectedIndex).",
                sheetName: sheet.name
            )
        }
        validateSheetName(sheet.name)
        let normalizedName = sheet.name.lowercased()
        if !normalizedName.isEmpty, !normalizedNames.insert(normalizedName).inserted {
            add(.duplicateSheetName, "Duplicate sheet name '\(sheet.name)'.", sheetName: sheet.name)
        }
        if sheet.rows.count > policy.maxRowsPerSheet {
            add(
                .rowOutOfBounds,
                "Sheet '\(sheet.name)' has \(sheet.rows.count) rows, limit is \(policy.maxRowsPerSheet).",
                sheetName: sheet.name
            )
        }

        var rowNumbers: Set<Int> = []
        var cellReferences: Set<String> = []
        for row in sheet.rows {
            validateRow(row, sheet: sheet, rowNumbers: &rowNumbers, cellReferences: &cellReferences)
        }

        totalMergedRanges += sheet.mergedRanges.count
        for range in sheet.mergedRanges {
            guard isValidCellRangeReference(range.reference) else {
                add(
                    .invalidMergedRange,
                    "Invalid merged range '\(range.reference)' in sheet '\(sheet.name)'.",
                    sheetName: sheet.name
                )
                continue
            }
        }
    }

    private mutating func validateSheetName(_ name: String) {
        let invalidCharacters = CharacterSet(charactersIn: "[]:*?/\\")
        if name.isEmpty {
            add(.invalidSheetName, "Sheet name cannot be empty.")
        }
        if name.utf16.count > 31 {
            add(.invalidSheetName, "Sheet name '\(name)' exceeds the XLSX 31-character limit.", sheetName: name)
        }
        if name.rangeOfCharacter(from: invalidCharacters) != nil {
            add(.invalidSheetName, "Sheet name '\(name)' contains characters XLSX does not allow.", sheetName: name)
        }
        if name.first == "'" || name.last == "'" {
            add(.invalidSheetName, "Sheet name '\(name)' cannot start or end with apostrophe.", sheetName: name)
        }
        if let scalar = firstDisallowedXMLScalar(in: name) {
            add(
                .invalidXMLText,
                "Sheet name '\(name)' contains XML 1.0-incompatible character \(scalarDescription(scalar)).",
                sheetName: name
            )
        }
    }

    private mutating func validateRow(
        _ row: Workbook.Row,
        sheet: Workbook.Sheet,
        rowNumbers: inout Set<Int>,
        cellReferences: inout Set<String>
    ) {
        if row.number < 1 || row.number > policy.maxRowsPerSheet {
            add(
                .rowOutOfBounds,
                "\(sheet.name) row \(row.number) is outside XLSX row bounds.",
                sheetName: sheet.name
            )
        }
        if !rowNumbers.insert(row.number).inserted {
            add(.duplicateRow, "\(sheet.name) contains duplicate row \(row.number).", sheetName: sheet.name)
        }

        for cell in row.cells {
            validateCell(cell, row: row, sheet: sheet, cellReferences: &cellReferences)
        }
    }

    private mutating func validateCell(
        _ cell: Workbook.Cell,
        row: Workbook.Row,
        sheet: Workbook.Sheet,
        cellReferences: inout Set<String>
    ) {
        totalCells += 1
        if !cell.value.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasRenderableCell = true
        }
        if cell.rowNumber != row.number {
            add(
                .cellRowMismatch,
                "\(sheet.name)!\(cell.reference) rowNumber \(cell.rowNumber) does not match row \(row.number).",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
        }
        if cell.columnNumber < 1 || cell.columnNumber > policy.maxColumnsPerSheet {
            add(
                .columnOutOfBounds,
                "\(sheet.name)!\(cell.reference) is outside XLSX column bounds.",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
        }
        guard let parsed = parseCellReference(cell.reference) else {
            add(
                .invalidCellReference,
                "\(sheet.name)!\(cell.reference) is not a valid A1 cell reference.",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
            return
        }
        if parsed.columnNumber != cell.columnNumber || parsed.rowNumber != cell.rowNumber {
            add(
                .invalidCellReference,
                "\(sheet.name)!\(cell.reference) does not match row \(cell.rowNumber), column \(cell.columnNumber).",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
        }

        let normalizedReference = cell.reference.uppercased()
        if !cellReferences.insert(normalizedReference).inserted {
            add(
                .duplicateCell,
                "\(sheet.name) contains duplicate cell \(cell.reference).",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
        }

        switch cell.value {
        case .string(let value):
            if value.utf16.count > policy.maxCellTextUTF16Units {
                add(
                    .overlongCellText,
                    "\(sheet.name)!\(cell.reference) text exceeds Excel's "
                        + "\(policy.maxCellTextUTF16Units)-character cell limit.",
                    sheetName: sheet.name,
                    cellReference: cell.reference
                )
            }
            if let scalar = firstDisallowedXMLScalar(in: value) {
                add(
                    .invalidXMLText,
                    "\(sheet.name)!\(cell.reference) contains XML 1.0-incompatible character "
                        + "\(scalarDescription(scalar)).",
                    sheetName: sheet.name,
                    cellReference: cell.reference
                )
            }
        case .number(let value):
            if !value.isFinite {
                add(
                    .nonFiniteNumber,
                    "\(sheet.name)!\(cell.reference) contains a non-finite number.",
                    sheetName: sheet.name,
                    cellReference: cell.reference
                )
            }
        case .empty, .bool:
            break
        }

        if cell.formula != nil, !policy.allowFormulaCells {
            add(
                .formulaNotWritable,
                "XLSX export does not write formulas yet (\(sheet.name)!\(cell.reference)).",
                sheetName: sheet.name,
                cellReference: cell.reference
            )
        }
    }

    private mutating func add(
        _ code: WorkbookValidationIssue.Code,
        _ message: String,
        sheetName: String? = nil,
        cellReference: String? = nil
    ) {
        issues.append(
            WorkbookValidationIssue(
                severity: .error,
                code: code,
                message: message,
                sheetName: sheetName,
                cellReference: cellReference
            )
        )
    }

    private func isValidCellRangeReference(_ reference: String) -> Bool {
        let endpoints = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard endpoints.count == 1 || endpoints.count == 2 else { return false }
        let parsed = endpoints.compactMap { parseCellReference(String($0)) }
        guard parsed.count == endpoints.count else { return false }
        guard parsed.count == 2 else { return true }
        return parsed[0].columnNumber <= parsed[1].columnNumber
            && parsed[0].rowNumber <= parsed[1].rowNumber
    }

    private func firstDisallowedXMLScalar(in value: String) -> UnicodeScalar? {
        value.unicodeScalars.first { !isAllowedXMLCharacter($0) }
    }

    private func isAllowedXMLCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:
            return true
        case 0x20 ... 0xD7FF, 0xE000 ... 0xFFFD, 0x10000 ... 0x10FFFF:
            return true
        default:
            return false
        }
    }

    private func scalarDescription(_ scalar: UnicodeScalar) -> String {
        "U+\(String(scalar.value, radix: 16).uppercased())"
    }

    private func parseCellReference(_ reference: String) -> (columnNumber: Int, rowNumber: Int)? {
        var column = 0
        var rowText = ""
        var readingRow = false

        for scalar in reference.unicodeScalars {
            if CharacterSet.letters.contains(scalar), !readingRow {
                let value = Int(scalar.value)
                let upperA = Int(UnicodeScalar("A").value)
                let lowerA = Int(UnicodeScalar("a").value)
                if value >= upperA, value <= upperA + 25 {
                    column = column * 26 + (value - upperA + 1)
                } else if value >= lowerA, value <= lowerA + 25 {
                    column = column * 26 + (value - lowerA + 1)
                } else {
                    return nil
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                readingRow = true
                rowText.unicodeScalars.append(scalar)
            } else {
                return nil
            }
        }

        guard column > 0,
            column <= policy.maxColumnsPerSheet,
            let row = Int(rowText),
            row > 0,
            row <= policy.maxRowsPerSheet
        else { return nil }
        return (column, row)
    }
}
