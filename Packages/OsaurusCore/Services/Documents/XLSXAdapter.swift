//
//  XLSXAdapter.swift
//  osaurus
//
//  Reads the stable, low-risk subset of XLSX directly from the OOXML ZIP
//  package: workbook relationships, shared strings, worksheet rows, scalar
//  cells, formulas, and merged ranges. This intentionally avoids adding a
//  package dependency while the document stack is still stacked behind the
//  foundation PR; style evaluation and richer spreadsheet features can move to
//  a dedicated parser dependency once the package graph is less contested.
//

import Compression
import Foundation

public struct XLSXAdapter: DocumentFormatAdapter {
    public let formatId = "xlsx"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        if url.pathExtension.lowercased() == "xlsx" { return true }
        guard let uti = uti?.lowercased() else { return false }
        return uti == "org.openxmlformats.spreadsheetml.sheet"
            || uti == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let archive: XLSXPackageArchive
        do {
            archive = try XLSXPackageArchive(data: Data(contentsOf: url))
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }

        let workbookPath = try Self.workbookPath(in: archive)
        let workbookIndex = try Self.parseWorkbookIndex(
            data: archive.xmlData(for: workbookPath)
        )
        let workbookRelationships = try Self.parseRelationships(
            data: archive.optionalXMLData(for: Self.relationshipPath(for: workbookPath)) ?? Data()
        )
        let sharedStrings = try Self.parseSharedStrings(in: archive)

        var parsedSheets: [ParsedSheet] = []
        for (index, sheet) in workbookIndex.sheets.enumerated() {
            let worksheetPath = try Self.worksheetPath(
                for: sheet,
                sheetIndex: index,
                workbookPath: workbookPath,
                relationships: workbookRelationships
            )
            let worksheet = try Self.parseWorksheet(
                data: archive.xmlData(for: worksheetPath),
                sheetName: sheet.name,
                sheetIndex: index,
                sharedStrings: sharedStrings
            )
            parsedSheets.append(worksheet)
        }

        guard parsedSheets.contains(where: { !$0.rows.isEmpty }) else {
            throw DocumentAdapterError.emptyContent
        }

        let rendered = Self.renderWorkbook(
            parsedSheets: parsedSheets,
            sharedStrings: sharedStrings,
            filename: url.lastPathComponent
        )
        guard !rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let security = Self.securityMetadata(
            url: url,
            archive: archive,
            formulaCount: rendered.formulaCount
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: rendered.workbook
            ),
            structure: rendered.structure,
            security: security,
            textFallback: rendered.text
        )
    }

    // MARK: - Package parts

    fileprivate static let maxXMLPartBytes = 25 * 1024 * 1024

    private static func workbookPath(in archive: XLSXPackageArchive) throws -> String {
        if let rootRelationships = try? parseRelationships(
            data: archive.optionalXMLData(for: "_rels/.rels") ?? Data()
        ) {
            if let target = rootRelationships.first(where: {
                $0.type.hasSuffix("/officeDocument") && !$0.isExternal
            })?.target {
                let resolved = try XLSXPackageArchive.normalizedPackagePath(
                    target,
                    relativeTo: ""
                )
                if archive.contains(resolved) { return resolved }
            }
        }

        guard archive.contains("xl/workbook.xml") else {
            throw DocumentAdapterError.readFailed(underlying: "XLSX package is missing xl/workbook.xml")
        }
        return "xl/workbook.xml"
    }

    private static func relationshipPath(for partPath: String) -> String {
        let nsPath = partPath as NSString
        let directory = nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent
        if directory.isEmpty || directory == "." {
            return "_rels/\(filename).rels"
        }
        return "\(directory)/_rels/\(filename).rels"
    }

    private static func worksheetPath(
        for sheet: WorkbookSheetReference,
        sheetIndex: Int,
        workbookPath: String,
        relationships: [XLSXRelationship]
    ) throws -> String {
        let workbookDirectory = (workbookPath as NSString).deletingLastPathComponent
        if let relationshipId = sheet.relationshipId,
            let relationship = relationships.first(where: { $0.id == relationshipId }),
            !relationship.isExternal
        {
            return try XLSXPackageArchive.normalizedPackagePath(
                relationship.target,
                relativeTo: workbookDirectory
            )
        }
        return "xl/worksheets/sheet\(sheetIndex + 1).xml"
    }

    // MARK: - XML parsing

    private static func parseWorkbookIndex(data: Data) throws -> WorkbookIndex {
        let parser = WorkbookIndexParser()
        try parseXML(data: data, delegate: parser, partName: "workbook.xml")
        return WorkbookIndex(sheets: parser.sheets)
    }

    private static func parseRelationships(data: Data) throws -> [XLSXRelationship] {
        guard !data.isEmpty else { return [] }
        let parser = RelationshipsParser()
        try parseXML(data: data, delegate: parser, partName: "relationships")
        return parser.relationships
    }

    private static func parseSharedStrings(in archive: XLSXPackageArchive) throws -> [String] {
        guard let data = try archive.optionalXMLData(for: "xl/sharedStrings.xml") else { return [] }
        let parser = SharedStringsParser()
        try parseXML(data: data, delegate: parser, partName: "sharedStrings.xml")
        return parser.items
    }

    private static func parseWorksheet(
        data: Data,
        sheetName: String,
        sheetIndex: Int,
        sharedStrings: [String]
    ) throws -> ParsedSheet {
        let parser = WorksheetParser(sharedStrings: sharedStrings)
        try parseXML(data: data, delegate: parser, partName: "\(sheetName).xml")
        return ParsedSheet(
            name: sheetName,
            index: sheetIndex,
            rows: parser.rows,
            mergedRanges: parser.mergedRanges
        )
    }

    private static func parseXML(
        data: Data,
        delegate: XMLParserDelegate,
        partName: String
    ) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "XML parse failed"
            throw DocumentAdapterError.readFailed(underlying: "\(partName): \(message)")
        }
    }

    // MARK: - Rendering and structure

    private static func renderWorkbook(
        parsedSheets: [ParsedSheet],
        sharedStrings: [String],
        filename: String
    ) -> RenderedWorkbook {
        var text = ""
        var sheetModels: [Workbook.Sheet] = []
        var sheetElements: [DocumentElement] = []
        var formulaCount = 0

        for sheet in parsedSheets {
            if !text.isEmpty {
                text.append("\n\n")
            }
            let sheetStart = text.utf16.count
            text.append("## Sheet: \(sheet.name)\n")

            var rowModels: [Workbook.Row] = []
            var rowElements: [DocumentElement] = []

            for row in sheet.rows {
                let rowStart = text.utf16.count
                text.append("\(row.number)\t")
                var cellModels: [Workbook.Cell] = []
                var cellElements: [DocumentElement] = []

                for (cellIndex, cell) in row.cells.enumerated() {
                    if cellIndex > 0 {
                        text.append("\t")
                    }
                    let cellStart = text.utf16.count
                    let cellText = describeCell(cell)
                    text.append(cellText)
                    if cell.formula != nil {
                        formulaCount += 1
                    }

                    let anchor = cellAnchor(
                        cell: cell,
                        sheet: sheet,
                        textStart: cellStart,
                        textLength: cellText.utf16.count
                    )
                    cellModels.append(
                        Workbook.Cell(
                            reference: cell.reference,
                            rowNumber: cell.rowNumber,
                            columnNumber: cell.columnNumber,
                            value: cell.value,
                            formula: cell.formula,
                            anchor: anchor
                        )
                    )
                    cellElements.append(
                        DocumentElement(
                            kind: .tableCell,
                            anchor: anchor,
                            text: cellText,
                            attributes: .init(metadata: cellMetadata(cell))
                        )
                    )
                }

                let rowTextLength = text.utf16.count - rowStart
                let rowAnchor = DocumentAnchor(
                    kind: .row,
                    path: [
                        .init(kind: .document),
                        .init(kind: .sheet, identifier: sheet.name, index: sheet.index),
                        .init(kind: .row, index: row.number - 1),
                    ],
                    textRange: DocumentTextRange(
                        startUTF16Offset: rowStart,
                        length: rowTextLength
                    ),
                    sourceRange: DocumentSourceRange(
                        start: DocumentSourceLocation(
                            sheetIndex: sheet.index,
                            sheetName: sheet.name,
                            rowIndex: row.number - 1
                        )
                    ),
                    label: "\(sheet.name) row \(row.number)"
                )
                rowModels.append(
                    Workbook.Row(
                        number: row.number,
                        cells: cellModels,
                        anchor: rowAnchor
                    )
                )
                rowElements.append(
                    DocumentElement(
                        kind: .tableRow,
                        anchor: rowAnchor,
                        text: String(text.utf16Suffix(from: rowStart)),
                        children: cellElements
                    )
                )
                text.append("\n")
            }

            if !sheet.mergedRanges.isEmpty {
                let ranges = sheet.mergedRanges.map(\.reference).joined(separator: ", ")
                text.append("Merged: \(ranges)\n")
            }

            let sheetLength = text.utf16.count - sheetStart
            let sheetAnchor = DocumentAnchor(
                kind: .sheet,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheet.name, index: sheet.index),
                ],
                textRange: DocumentTextRange(startUTF16Offset: sheetStart, length: sheetLength),
                sourceRange: DocumentSourceRange(
                    start: DocumentSourceLocation(sheetIndex: sheet.index, sheetName: sheet.name)
                ),
                label: sheet.name,
                metadata: ["sheetIndex": "\(sheet.index)"]
            )
            let sheetModel = Workbook.Sheet(
                name: sheet.name,
                index: sheet.index,
                rows: rowModels,
                mergedRanges: sheet.mergedRanges,
                anchor: sheetAnchor
            )
            sheetModels.append(sheetModel)
            sheetElements.append(
                DocumentElement(
                    kind: .sheet,
                    anchor: sheetAnchor,
                    text: String(text.utf16Suffix(from: sheetStart)),
                    attributes: .init(metadata: ["sheetIndex": "\(sheet.index)"]),
                    children: rowElements
                )
            )
        }

        let rootAnchor = DocumentAnchor.root(label: filename)
        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: sheetElements
        )
        return RenderedWorkbook(
            workbook: Workbook(sheets: sheetModels, sharedStrings: sharedStrings),
            structure: DocumentStructure(
                root: root,
                textLengthUTF16: text.utf16.count
            ),
            text: text,
            formulaCount: formulaCount
        )
    }

    private static func cellAnchor(
        cell: ParsedCell,
        sheet: ParsedSheet,
        textStart: Int,
        textLength: Int
    ) -> DocumentAnchor {
        DocumentAnchor(
            kind: .cell,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: sheet.name, index: sheet.index),
                .init(kind: .cell, identifier: cell.reference),
            ],
            textRange: DocumentTextRange(startUTF16Offset: textStart, length: textLength),
            sourceRange: DocumentSourceRange(
                start: .cell(
                    sheetName: sheet.name,
                    rowIndex: cell.rowNumber - 1,
                    columnIndex: cell.columnNumber - 1
                )
            ),
            label: "\(sheet.name)!\(cell.reference)",
            metadata: cellMetadata(cell)
        )
    }

    private static func describeCell(_ cell: ParsedCell) -> String {
        let base = cell.value.fallbackText
        guard let formula = cell.formula, !formula.isEmpty else { return base }
        return base.isEmpty ? "=\(formula)" : "\(base) [=\(formula)]"
    }

    private static func cellMetadata(_ cell: ParsedCell) -> [String: String] {
        var metadata = [
            "reference": cell.reference,
            "rowNumber": "\(cell.rowNumber)",
            "columnNumber": "\(cell.columnNumber)",
            "valueKind": cell.value.kindName,
        ]
        if let formula = cell.formula {
            metadata["formula"] = formula
        }
        return metadata
    }

    // MARK: - Security metadata

    private static func securityMetadata(
        url: URL,
        archive: XLSXPackageArchive,
        formulaCount: Int
    ) -> DocumentSecurityMetadata {
        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "Basic XLSX reader preserves cells but does not evaluate styles, macros, charts, or embedded objects."
            )
        ]
        var activeContentTypes: Set<DocumentActiveContentType> = []
        var externalReferences: [DocumentExternalReference] = []

        if formulaCount > 0 {
            activeContentTypes.insert(.formula)
            findings.append(
                DocumentSecurityFinding(
                    kind: .formula,
                    severity: .informational,
                    message: "Workbook contains formula source text.",
                    metadata: ["count": "\(formulaCount)"]
                )
            )
        }

        if archive.paths.contains(where: { $0.lowercased().hasSuffix("vbaproject.bin") }) {
            activeContentTypes.insert(.macro)
            findings.append(
                DocumentSecurityFinding(
                    kind: .macro,
                    severity: .medium,
                    message: "Workbook package contains a VBA project part."
                )
            )
        }

        if archive.paths.contains(where: { $0.lowercased().hasPrefix("xl/externallinks/") }) {
            activeContentTypes.insert(.externalReference)
            findings.append(
                DocumentSecurityFinding(
                    kind: .externalReference,
                    severity: .low,
                    message: "Workbook package contains external-link parts."
                )
            )
        }

        for relationshipEntry in archive.paths where relationshipEntry.hasSuffix(".rels") {
            guard
                let data = try? archive.optionalXMLData(for: relationshipEntry),
                let relationships = try? parseRelationships(data: data)
            else { continue }
            for relationship in relationships where relationship.isExternal {
                activeContentTypes.insert(.externalReference)
                externalReferences.append(
                    DocumentExternalReference(
                        kind: .packageRelationship,
                        urlString: relationship.target,
                        relationshipId: relationship.id
                    )
                )
            }
        }

        if !externalReferences.isEmpty {
            findings.append(
                DocumentSecurityFinding(
                    kind: .externalReference,
                    severity: .low,
                    message: "Workbook package relationships reference external resources.",
                    metadata: ["count": "\(externalReferences.count)"]
                )
            )
        }

        return DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: "xlsx",
            inspectionStatus: .partiallyInspected,
            findings: findings,
            externalReferences: externalReferences,
            activeContentTypes: activeContentTypes
        )
    }
}

// MARK: - Parsed workbook staging

private struct RenderedWorkbook {
    let workbook: Workbook
    let structure: DocumentStructure
    let text: String
    let formulaCount: Int
}

private struct WorkbookIndex {
    let sheets: [WorkbookSheetReference]
}

private struct WorkbookSheetReference {
    let name: String
    let relationshipId: String?
    let sheetId: Int?
}

private struct ParsedSheet {
    let name: String
    let index: Int
    let rows: [ParsedRow]
    let mergedRanges: [Workbook.CellRange]
}

private struct ParsedRow {
    let number: Int
    let cells: [ParsedCell]
}

private struct ParsedCell {
    let reference: String
    let rowNumber: Int
    let columnNumber: Int
    let value: Workbook.CellValue
    let formula: String?
}

private struct XLSXRelationship {
    let id: String
    let type: String
    let target: String
    let targetMode: String?

    var isExternal: Bool {
        let lowercasedTarget = target.lowercased()
        return targetMode?.lowercased() == "external"
            || lowercasedTarget.hasPrefix("http://")
            || lowercasedTarget.hasPrefix("https://")
            || lowercasedTarget.hasPrefix("file://")
            || lowercasedTarget.hasPrefix("//")
    }
}

private extension Workbook.CellValue {
    var kindName: String {
        switch self {
        case .empty: return "empty"
        case .number: return "number"
        case .string: return "string"
        case .bool: return "bool"
        }
    }
}

private extension String {
    func utf16Suffix(from startOffset: Int) -> String {
        guard startOffset > 0 else { return self }
        let utf16View = utf16
        guard let start = utf16View.index(utf16View.startIndex, offsetBy: startOffset, limitedBy: utf16View.endIndex),
            let scalarStart = String.Index(start, within: self)
        else { return "" }
        return String(self[scalarStart...])
    }
}

// MARK: - XML delegates

private final class WorkbookIndexParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheetReference] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.xlsxLocalName == "sheet" else { return }
        let name = attributeDict["name"] ?? "Sheet \(sheets.count + 1)"
        let relationshipId = attributeDict["r:id"] ?? attributeDict["id"]
        let sheetId = attributeDict["sheetId"].flatMap(Int.init)
        sheets.append(
            WorkbookSheetReference(
                name: name,
                relationshipId: relationshipId,
                sheetId: sheetId
            )
        )
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private(set) var relationships: [XLSXRelationship] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.xlsxLocalName == "Relationship",
            let id = attributeDict["Id"] ?? attributeDict["id"],
            let target = attributeDict["Target"] ?? attributeDict["target"]
        else { return }
        relationships.append(
            XLSXRelationship(
                id: id,
                type: attributeDict["Type"] ?? attributeDict["type"] ?? "",
                target: target,
                targetMode: attributeDict["TargetMode"] ?? attributeDict["targetMode"]
            )
        )
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var items: [String] = []
    private var currentItem: String?
    private var textBuffer: String?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        switch elementName.xlsxLocalName {
        case "si":
            currentItem = ""
        case "t" where currentItem != nil:
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard textBuffer != nil else { return }
        textBuffer?.append(string)
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        switch elementName.xlsxLocalName {
        case "t" where currentItem != nil:
            currentItem?.append(textBuffer ?? "")
            textBuffer = nil
        case "si":
            items.append(currentItem ?? "")
            currentItem = nil
        default:
            break
        }
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [ParsedRow] = []
    private(set) var mergedRanges: [Workbook.CellRange] = []

    private var currentRowNumber: Int?
    private var currentCells: [ParsedCell] = []
    private var currentCell: CellBuilder?
    private var textBuffer: String?
    private var insideInlineString = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.xlsxLocalName {
        case "row":
            currentRowNumber = attributeDict["r"].flatMap(Int.init) ?? rows.count + 1
            currentCells = []
        case "c":
            currentCell = CellBuilder(
                reference: attributeDict["r"],
                type: attributeDict["t"]
            )
        case "v", "f":
            if currentCell != nil {
                textBuffer = ""
            }
        case "is" where currentCell != nil:
            insideInlineString = true
        case "t" where currentCell != nil && insideInlineString:
            textBuffer = ""
        case "mergeCell":
            if let ref = attributeDict["ref"], !ref.isEmpty {
                mergedRanges.append(Workbook.CellRange(reference: ref))
            }
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard textBuffer != nil else { return }
        textBuffer?.append(string)
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        switch elementName.xlsxLocalName {
        case "v":
            currentCell?.rawValue = textBuffer ?? ""
            textBuffer = nil
        case "f":
            currentCell?.formula = nilIfEmpty(textBuffer)
            textBuffer = nil
        case "t" where insideInlineString:
            currentCell?.inlineText.append(textBuffer ?? "")
            textBuffer = nil
        case "is":
            insideInlineString = false
        case "c":
            if let cell = buildCurrentCell() {
                currentCells.append(cell)
            }
            currentCell = nil
        case "row":
            if let rowNumber = currentRowNumber, !currentCells.isEmpty {
                rows.append(ParsedRow(number: rowNumber, cells: currentCells))
            }
            currentRowNumber = nil
            currentCells = []
        default:
            break
        }
    }

    private func buildCurrentCell() -> ParsedCell? {
        guard let builder = currentCell else { return nil }
        let parsedReference = builder.reference.flatMap(Self.parseCellReference)
        let rowNumber = parsedReference?.rowNumber ?? currentRowNumber ?? rows.count + 1
        let columnNumber = parsedReference?.columnNumber ?? currentCells.count + 1
        let reference = builder.reference ?? Self.cellReference(columnNumber: columnNumber, rowNumber: rowNumber)
        let value = Self.cellValue(
            type: builder.type,
            rawValue: builder.rawValue,
            inlineText: builder.inlineText,
            sharedStrings: sharedStrings
        )
        guard value != .empty || builder.formula != nil else { return nil }
        return ParsedCell(
            reference: reference,
            rowNumber: rowNumber,
            columnNumber: columnNumber,
            value: value,
            formula: builder.formula
        )
    }

    private static func cellValue(
        type: String?,
        rawValue: String?,
        inlineText: String,
        sharedStrings: [String]
    ) -> Workbook.CellValue {
        let normalizedType = type?.lowercased()
        let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch normalizedType {
        case "s":
            guard let index = Int(raw), sharedStrings.indices.contains(index) else {
                return raw.isEmpty ? .empty : .string(raw)
            }
            return .string(sharedStrings[index])
        case "b":
            return .bool(raw == "1" || raw.lowercased() == "true")
        case "inlinestr":
            return inlineText.isEmpty ? .empty : .string(inlineText)
        case "str", "d", "e":
            return raw.isEmpty ? .empty : .string(raw)
        default:
            if raw.isEmpty { return .empty }
            if let number = Double(raw) {
                return .number(number)
            }
            return .string(raw)
        }
    }

    private static func parseCellReference(_ reference: String) -> (columnNumber: Int, rowNumber: Int)? {
        var column = 0
        var rowText = ""
        for scalar in reference.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                let value = Int(scalar.value)
                let upperA = Int(UnicodeScalar("A").value)
                let lowerA = Int(UnicodeScalar("a").value)
                if value >= upperA, value <= upperA + 25 {
                    column = column * 26 + (value - upperA + 1)
                } else if value >= lowerA, value <= lowerA + 25 {
                    column = column * 26 + (value - lowerA + 1)
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                rowText.unicodeScalars.append(scalar)
            }
        }
        guard column > 0, let row = Int(rowText), row > 0 else { return nil }
        return (column, row)
    }

    private static func cellReference(columnNumber: Int, rowNumber: Int) -> String {
        var column = columnNumber
        var letters = ""
        while column > 0 {
            let remainder = (column - 1) % 26
            let scalar = UnicodeScalar(65 + remainder)!
            letters.insert(Character(scalar), at: letters.startIndex)
            column = (column - 1) / 26
        }
        return "\(letters)\(rowNumber)"
    }

    private struct CellBuilder {
        let reference: String?
        let type: String?
        var rawValue: String?
        var inlineText = ""
        var formula: String?
    }
}

private func nilIfEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension String {
    var xlsxLocalName: String {
        split(separator: ":").last.map(String.init) ?? self
    }
}

// MARK: - Minimal ZIP reader

private struct XLSXPackageArchive {
    private struct Entry {
        let path: String
        let compressionMethod: Int
        let flags: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    var paths: [String] {
        entries.keys.sorted()
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data: data)
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    func xmlData(for path: String) throws -> Data {
        guard let data = try optionalXMLData(for: path) else {
            throw DocumentAdapterError.readFailed(underlying: "XLSX package is missing \(path)")
        }
        return data
    }

    func optionalXMLData(for path: String) throws -> Data? {
        try entryData(for: path, maxUncompressedSize: XLSXAdapter.maxXMLPartBytes)
    }

    static func normalizedPackagePath(_ rawPath: String, relativeTo baseDirectory: String) throws -> String {
        let combined: String
        if rawPath.hasPrefix("/") {
            combined = String(rawPath.drop { $0 == "/" })
        } else if baseDirectory.isEmpty || baseDirectory == "." {
            combined = rawPath
        } else {
            combined = "\(baseDirectory)/\(rawPath)"
        }
        return try normalizeEntryName(combined)
    }

    private func entryData(for path: String, maxUncompressedSize: Int) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        if entry.flags & 0x1 != 0 {
            throw DocumentAdapterError.readFailed(underlying: "Encrypted ZIP entries are not supported")
        }
        if entry.uncompressedSize > maxUncompressedSize {
            throw DocumentAdapterError.readFailed(
                underlying: "\(path) exceeds XML part limit (\(entry.uncompressedSize) bytes)"
            )
        }
        let localOffset = entry.localHeaderOffset
        guard try data.uint32LE(at: localOffset) == 0x0403_4B50 else {
            throw DocumentAdapterError.readFailed(underlying: "\(path) has an invalid local ZIP header")
        }
        let fileNameLength = try data.uint16LE(at: localOffset + 26)
        let extraLength = try data.uint16LE(at: localOffset + 28)
        let localNameStart = localOffset + 30
        let localNameEnd = localNameStart + fileNameLength
        guard localNameEnd <= data.count,
            let rawLocalName = String(data: data.subdata(in: localNameStart ..< localNameEnd), encoding: .utf8)
        else {
            throw DocumentAdapterError.readFailed(underlying: "\(path) local ZIP header name is invalid")
        }
        let localPath = try Self.normalizeEntryName(rawLocalName)
        guard localPath == entry.path else {
            throw DocumentAdapterError.readFailed(underlying: "\(path) local ZIP header name mismatch")
        }
        let payloadOffset = localNameEnd + extraLength
        let payloadEnd = payloadOffset + entry.compressedSize
        guard payloadOffset >= 0, payloadEnd <= data.count else {
            throw DocumentAdapterError.readFailed(underlying: "\(path) ZIP payload is truncated")
        }
        let payload = data.subdata(in: payloadOffset ..< payloadEnd)
        switch entry.compressionMethod {
        case 0:
            guard payload.count == entry.uncompressedSize else {
                throw DocumentAdapterError.readFailed(underlying: "\(path) stored ZIP size mismatch")
            }
            return payload
        case 8:
            return try Self.inflate(payload, uncompressedSize: entry.uncompressedSize, path: path)
        default:
            throw DocumentAdapterError.readFailed(
                underlying: "\(path) uses unsupported ZIP compression method \(entry.compressionMethod)"
            )
        }
    }

    private static func readCentralDirectory(data: Data) throws -> [String: Entry] {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        let diskNumber = try data.uint16LE(at: eocdOffset + 4)
        let centralDirectoryDisk = try data.uint16LE(at: eocdOffset + 6)
        let entriesOnDisk = try data.uint16LE(at: eocdOffset + 8)
        let entryCount = try data.uint16LE(at: eocdOffset + 10)
        let centralDirectorySize = try data.uint32LE(at: eocdOffset + 12)
        let centralDirectoryOffset = try data.uint32LE(at: eocdOffset + 16)

        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
            throw DocumentAdapterError.readFailed(underlying: "Multi-disk XLSX ZIP archives are not supported")
        }
        guard entryCount != Int(UInt16.max),
            centralDirectorySize != Int(UInt32.max),
            centralDirectoryOffset != Int(UInt32.max)
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP64 XLSX packages are not supported")
        }
        guard centralDirectoryOffset >= 0,
            centralDirectorySize >= 0,
            centralDirectoryOffset + centralDirectorySize <= eocdOffset
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP central directory is truncated")
        }

        var entries: [String: Entry] = [:]
        var offset = centralDirectoryOffset
        for _ in 0 ..< entryCount {
            guard offset + 46 <= data.count,
                try data.uint32LE(at: offset) == 0x0201_4B50
            else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP central directory entry is invalid")
            }
            let flags = try data.uint16LE(at: offset + 8)
            let compressionMethod = try data.uint16LE(at: offset + 10)
            let compressedSize = try data.uint32LE(at: offset + 20)
            let uncompressedSize = try data.uint32LE(at: offset + 24)
            let fileNameLength = try data.uint16LE(at: offset + 28)
            let extraLength = try data.uint16LE(at: offset + 30)
            let commentLength = try data.uint16LE(at: offset + 32)
            let localHeaderOffset = try data.uint32LE(at: offset + 42)
            guard compressedSize != Int(UInt32.max),
                uncompressedSize != Int(UInt32.max),
                localHeaderOffset != Int(UInt32.max)
            else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP64 XLSX entries are not supported")
            }
            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            let nextOffset = nameEnd + extraLength + commentLength
            guard nameEnd <= data.count, nextOffset <= data.count else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP central directory entry is truncated")
            }
            guard let rawName = String(data: data.subdata(in: nameStart ..< nameEnd), encoding: .utf8) else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP entry name is not UTF-8")
            }
            let path = try normalizeEntryName(rawName)
            if entries[path] != nil {
                throw DocumentAdapterError.readFailed(underlying: "Duplicate ZIP entry \(path)")
            }
            entries[path] = Entry(
                path: path,
                compressionMethod: compressionMethod,
                flags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            offset = nextOffset
        }
        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP package is too small")
        }
        let searchStart = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= searchStart {
            if (try? data.uint32LE(at: offset)) == 0x0605_4B50,
                let commentLength = try? data.uint16LE(at: offset + 20),
                offset + 22 + commentLength == data.count
            {
                return offset
            }
            offset -= 1
        }
        throw DocumentAdapterError.readFailed(underlying: "ZIP end of central directory was not found")
    }

    private static func inflate(_ payload: Data, uncompressedSize: Int, path: String) throws -> Data {
        if uncompressedSize == 0 { return Data() }
        var output = Data(count: uncompressedSize)
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
            payload.withUnsafeBytes { inputBuffer in
                guard
                    let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    outputBase,
                    uncompressedSize,
                    inputBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else {
            throw DocumentAdapterError.readFailed(underlying: "\(path) deflate stream could not be decoded")
        }
        return output
    }

    private static func normalizeEntryName(_ rawName: String) throws -> String {
        let normalizedSeparators = rawName.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedSeparators.hasPrefix("/") else {
            throw DocumentAdapterError.readFailed(underlying: "Absolute ZIP entry paths are not supported")
        }
        var components: [String] = []
        for component in normalizedSeparators.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                throw DocumentAdapterError.readFailed(underlying: "Parent-relative ZIP entry paths are not supported")
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw DocumentAdapterError.readFailed(underlying: "Empty ZIP entry path")
        }
        return components.joined(separator: "/")
    }
}

private extension Data {
    func uint16LE(at offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= count else {
            throw DocumentAdapterError.readFailed(underlying: "Unexpected end of ZIP data")
        }
        return Int(self[offset])
            | (Int(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= count else {
            throw DocumentAdapterError.readFailed(underlying: "Unexpected end of ZIP data")
        }
        return Int(self[offset])
            | (Int(self[offset + 1]) << 8)
            | (Int(self[offset + 2]) << 16)
            | (Int(self[offset + 3]) << 24)
    }
}
