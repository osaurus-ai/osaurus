//
//  XLSXEmitter.swift
//  osaurus
//
//  Writes the same conservative workbook subset the dependency-free XLSX
//  reader can parse: sheets, sparse rows, scalar cell values, shared strings,
//  and merged ranges. Formulas and styling are rejected instead of being
//  silently flattened so callers do not mistake a lossy export for a faithful
//  workbook round trip.
//

import Foundation

public struct XLSXEmitter: DocumentFormatEmitter {
    public let formatId = "xlsx"

    public init() {}

    public func canEmit(_ document: StructuredDocument) -> Bool {
        (document.formatId == formatId || document.representation.formatId == formatId)
            && document.representation.underlying is Workbook
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        guard let workbook = document.representation.underlying as? Workbook else {
            throw DocumentAdapterError.unsupportedFormat(formatId: document.formatId)
        }

        do {
            let data = try Self.packageData(for: workbook)
            try data.write(to: url, options: .atomic)
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Package assembly

    private static let spreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let officeRelationshipNamespace =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationshipNamespace =
        "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let worksheetRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
    private static let sharedStringsRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
    private static let officeDocumentRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

    private static func packageData(for workbook: Workbook) throws -> Data {
        let sheets = try validatedSheets(workbook.sheets)
        try rejectFormulaCells(in: sheets)
        try requireRenderableContent(in: sheets)

        var sharedStrings = SharedStringTable()
        var worksheetEntries: [(path: String, xml: String)] = []
        for sheet in sheets {
            worksheetEntries.append(
                (
                    path: "xl/worksheets/sheet\(sheet.index + 1).xml",
                    xml: try worksheetXML(for: sheet, sharedStrings: &sharedStrings)
                )
            )
        }

        var entries: [(path: String, data: Data)] = [
            (
                "[Content_Types].xml",
                try utf8Data(contentTypesXML(sheetCount: sheets.count, hasSharedStrings: !sharedStrings.isEmpty))
            ),
            ("_rels/.rels", try utf8Data(rootRelationshipsXML())),
            ("xl/workbook.xml", try utf8Data(workbookXML(for: sheets))),
            (
                "xl/_rels/workbook.xml.rels",
                try utf8Data(
                    workbookRelationshipsXML(sheetCount: sheets.count, hasSharedStrings: !sharedStrings.isEmpty)
                )
            ),
        ]

        if !sharedStrings.isEmpty {
            entries.append(("xl/sharedStrings.xml", try utf8Data(sharedStringsXML(sharedStrings))))
        }

        for worksheet in worksheetEntries {
            entries.append((worksheet.path, try utf8Data(worksheet.xml)))
        }

        var archive = XLSXStoredZIPWriter()
        for entry in entries {
            try archive.append(path: entry.path, data: entry.data)
        }
        return try archive.finalize()
    }

    private static func contentTypesXML(sheetCount: Int, hasSharedStrings: Bool) throws -> String {
        var overrides: [String] = [
            """
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            """
        ]
        if hasSharedStrings {
            overrides.append(
                """
                <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
                """
            )
        }
        for index in 1 ... sheetCount {
            overrides.append(
                """
                <Override PartName="/xl/worksheets/sheet\(index).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                """
            )
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              \(overrides.joined(separator: "\n  "))
            </Types>
            """
    }

    private static func rootRelationshipsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="\(packageRelationshipNamespace)">
          <Relationship Id="rId1" Type="\(officeDocumentRelationshipType)" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    private static func workbookXML(for sheets: [Workbook.Sheet]) throws -> String {
        let sheetXML = try sheets.map { sheet in
            let escapedName = try escapeXMLAttribute(sheet.name)
            return """
                      <sheet name="\(escapedName)" sheetId="\(sheet.index + 1)" r:id="rId\(sheet.index + 1)"/>
                """
        }.joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="\(spreadsheetNamespace)" xmlns:r="\(officeRelationshipNamespace)">
              <sheets>
            \(sheetXML)
              </sheets>
            </workbook>
            """
    }

    private static func workbookRelationshipsXML(sheetCount: Int, hasSharedStrings: Bool) -> String {
        var relationships = (1 ... sheetCount).map { index in
            """
              <Relationship Id="rId\(index)" Type="\(worksheetRelationshipType)" Target="worksheets/sheet\(index).xml"/>
            """
        }
        if hasSharedStrings {
            relationships.append(
                """
                  <Relationship Id="rId\(sheetCount + 1)" Type="\(sharedStringsRelationshipType)" Target="sharedStrings.xml"/>
                """
            )
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="\(packageRelationshipNamespace)">
            \(relationships.joined(separator: "\n"))
            </Relationships>
            """
    }

    private static func worksheetXML(
        for sheet: Workbook.Sheet,
        sharedStrings: inout SharedStringTable
    ) throws -> String {
        let rows = try sheet.rows
            .sorted { $0.number < $1.number }
            .map { row in try rowXML(row, sheet: sheet, sharedStrings: &sharedStrings) }
            .joined(separator: "\n")
        let mergedRanges = try mergeCellsXML(sheet.mergedRanges)

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="\(spreadsheetNamespace)">
              <sheetData>
            \(rows)
              </sheetData>
            \(mergedRanges)
            </worksheet>
            """
    }

    private static func rowXML(
        _ row: Workbook.Row,
        sheet: Workbook.Sheet,
        sharedStrings: inout SharedStringTable
    ) throws -> String {
        let cells = try row.cells
            .sorted { $0.columnNumber < $1.columnNumber }
            .map { cell in try cellXML(cell, row: row, sheet: sheet, sharedStrings: &sharedStrings) }
            .joined()
        return """
                <row r="\(row.number)">\(cells)</row>
            """
    }

    private static func cellXML(
        _ cell: Workbook.Cell,
        row: Workbook.Row,
        sheet: Workbook.Sheet,
        sharedStrings: inout SharedStringTable
    ) throws -> String {
        guard cell.rowNumber == row.number else {
            throw writeFailed(
                "\(sheet.name)!\(cell.reference) rowNumber \(cell.rowNumber) does not match row \(row.number)"
            )
        }
        let reference = try validatedCellReference(for: cell, sheetName: sheet.name)

        switch cell.value {
        case .empty:
            return #"<c r="\#(reference)"/>"#
        case .number(let value):
            return #"<c r="\#(reference)"><v>\#(try numberText(value))</v></c>"#
        case .string(let value):
            let index = sharedStrings.index(for: value)
            return #"<c r="\#(reference)" t="s"><v>\#(index)</v></c>"#
        case .bool(let value):
            return #"<c r="\#(reference)" t="b"><v>\#(value ? "1" : "0")</v></c>"#
        }
    }

    private static func mergeCellsXML(_ ranges: [Workbook.CellRange]) throws -> String {
        guard !ranges.isEmpty else { return "" }
        let cells = try ranges.map { range in
            guard isValidCellRangeReference(range.reference) else {
                throw writeFailed("Invalid merged range '\(range.reference)'")
            }
            return #"  <mergeCell ref="\#(try escapeXMLAttribute(range.reference))"/>"#
        }.joined(separator: "\n")

        return """
              <mergeCells count="\(ranges.count)">
            \(cells)
              </mergeCells>
            """
    }

    private static func sharedStringsXML(_ table: SharedStringTable) throws -> String {
        let items = try table.values.map { value in
            let escaped = try escapeXMLText(value)
            let space = needsPreservedXMLSpace(value) ? #" xml:space="preserve""# : ""
            return """
                  <si><t\(space)>\(escaped)</t></si>
                """
        }.joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="\(spreadsheetNamespace)" count="\(table.totalReferences)" uniqueCount="\(table.values.count)">
            \(items)
            </sst>
            """
    }

    // MARK: - Validation

    private static let maxRows = 1_048_576
    private static let maxColumns = 16_384
    private static let invalidSheetNameCharacters = CharacterSet(charactersIn: "[]:*?/\\")

    private static func validatedSheets(_ sheets: [Workbook.Sheet]) throws -> [Workbook.Sheet] {
        guard !sheets.isEmpty else { throw DocumentAdapterError.emptyContent }

        var names: Set<String> = []
        for (offset, sheet) in sheets.enumerated() {
            guard sheet.index == offset else {
                throw writeFailed("Sheet '\(sheet.name)' has index \(sheet.index), expected \(offset)")
            }
            try validateSheetName(sheet.name)
            let normalizedName = sheet.name.lowercased()
            guard names.insert(normalizedName).inserted else {
                throw writeFailed("Duplicate sheet name '\(sheet.name)'")
            }
            try validateRows(sheet.rows, sheetName: sheet.name)
            for range in sheet.mergedRanges where !isValidCellRangeReference(range.reference) {
                throw writeFailed("Invalid merged range '\(range.reference)'")
            }
        }
        return sheets
    }

    private static func validateSheetName(_ name: String) throws {
        guard !name.isEmpty else { throw writeFailed("Sheet name cannot be empty") }
        guard name.utf16.count <= 31 else {
            throw writeFailed("Sheet name '\(name)' exceeds the XLSX 31-character limit")
        }
        guard name.rangeOfCharacter(from: invalidSheetNameCharacters) == nil else {
            throw writeFailed("Sheet name '\(name)' contains characters XLSX does not allow")
        }
        guard name.first != "'", name.last != "'" else {
            throw writeFailed("Sheet name '\(name)' cannot start or end with apostrophe")
        }
    }

    private static func validateRows(_ rows: [Workbook.Row], sheetName: String) throws {
        var rowNumbers: Set<Int> = []
        var cellReferences: Set<String> = []
        for row in rows {
            guard row.number >= 1, row.number <= maxRows else {
                throw writeFailed("\(sheetName) row \(row.number) is outside XLSX row bounds")
            }
            guard rowNumbers.insert(row.number).inserted else {
                throw writeFailed("\(sheetName) contains duplicate row \(row.number)")
            }

            for cell in row.cells {
                guard cell.columnNumber >= 1, cell.columnNumber <= maxColumns else {
                    throw writeFailed("\(sheetName)!\(cell.reference) is outside XLSX column bounds")
                }
                guard cell.rowNumber >= 1, cell.rowNumber <= maxRows else {
                    throw writeFailed("\(sheetName)!\(cell.reference) is outside XLSX row bounds")
                }
                let normalizedReference = cell.reference.uppercased()
                guard cellReferences.insert(normalizedReference).inserted else {
                    throw writeFailed("\(sheetName) contains duplicate cell \(cell.reference)")
                }
            }
        }
    }

    private static func rejectFormulaCells(in sheets: [Workbook.Sheet]) throws {
        for sheet in sheets {
            for row in sheet.rows {
                for cell in row.cells where cell.formula != nil {
                    throw writeFailed("XLSX emitter does not write formulas yet (\(sheet.name)!\(cell.reference))")
                }
            }
        }
    }

    private static func requireRenderableContent(in sheets: [Workbook.Sheet]) throws {
        let hasRenderableCell = sheets.contains { sheet in
            sheet.rows.contains { row in
                row.cells.contains { cell in
                    !cell.value.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
        }
        guard hasRenderableCell else {
            throw DocumentAdapterError.emptyContent
        }
    }

    private static func validatedCellReference(for cell: Workbook.Cell, sheetName: String) throws -> String {
        let expected = cellReference(columnNumber: cell.columnNumber, rowNumber: cell.rowNumber)
        guard let parsed = parseCellReference(cell.reference),
            parsed.columnNumber == cell.columnNumber,
            parsed.rowNumber == cell.rowNumber,
            cell.reference.uppercased() == expected
        else {
            throw writeFailed("\(sheetName)!\(cell.reference) does not match row/column \(expected)")
        }
        return expected
    }

    private static func isValidCellRangeReference(_ reference: String) -> Bool {
        let endpoints = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard endpoints.count == 1 || endpoints.count == 2 else { return false }
        return endpoints.allSatisfy { parseCellReference(String($0)) != nil }
    }

    private static func parseCellReference(_ reference: String) -> (columnNumber: Int, rowNumber: Int)? {
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

        guard column > 0, column <= maxColumns, let row = Int(rowText), row > 0, row <= maxRows else {
            return nil
        }
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

    private static func numberText(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw writeFailed("XLSX emitter cannot write non-finite numbers")
        }
        if value >= Double(Int64.min),
            value <= Double(Int64.max),
            value.rounded(.towardZero) == value
        {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - XML escaping

    private static func utf8Data(_ xml: String) throws -> Data {
        guard let data = xml.data(using: .utf8) else {
            throw writeFailed("XML could not be encoded as UTF-8")
        }
        return data
    }

    private static func escapeXMLText(_ value: String) throws -> String {
        try validateXMLCharacters(value)
        return
            value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeXMLAttribute(_ value: String) throws -> String {
        try validateXMLCharacters(value)
        return try escapeXMLText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func validateXMLCharacters(_ value: String) throws {
        for scalar in value.unicodeScalars where !isAllowedXMLCharacter(scalar) {
            throw writeFailed("String contains a character XML 1.0 cannot encode")
        }
    }

    private static func isAllowedXMLCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:
            return true
        case 0x20 ... 0xD7FF, 0xE000 ... 0xFFFD, 0x10000 ... 0x10FFFF:
            return true
        default:
            return false
        }
    }

    private static func needsPreservedXMLSpace(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
            let last = value.unicodeScalars.last
        else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(first)
            || CharacterSet.whitespacesAndNewlines.contains(last)
    }

    private static func writeFailed(_ message: String) -> DocumentAdapterError {
        .writeFailed(underlying: message)
    }
}

private struct SharedStringTable {
    private var indices: [String: Int] = [:]
    private(set) var values: [String] = []
    private(set) var totalReferences = 0

    var isEmpty: Bool { values.isEmpty }

    mutating func index(for value: String) -> Int {
        totalReferences += 1
        if let index = indices[value] {
            return index
        }
        let index = values.count
        indices[value] = index
        values.append(value)
        return index
    }
}

private struct XLSXStoredZIPWriter {
    private struct CentralDirectoryEntry {
        let path: String
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    private var archive = Data()
    private var entries: [CentralDirectoryEntry] = []

    mutating func append(path: String, data: Data) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
            throw DocumentAdapterError.writeFailed(underlying: "Invalid ZIP entry path '\(path)'")
        }
        let name = Data(path.utf8)
        let localHeaderOffset = try uint32(archive.count, label: "ZIP local header offset")
        let size = try uint32(data.count, label: "\(path) size")
        let nameLength = try uint16(name.count, label: "\(path) name length")
        let checksum = crc32(data)

        archive.appendUInt32LE(0x0403_4B50)
        archive.appendUInt16LE(20)
        archive.appendUInt16LE(0x0800)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt32LE(checksum)
        archive.appendUInt32LE(size)
        archive.appendUInt32LE(size)
        archive.appendUInt16LE(nameLength)
        archive.appendUInt16LE(0)
        archive.append(name)
        archive.append(data)

        entries.append(
            CentralDirectoryEntry(
                path: path,
                crc32: checksum,
                size: size,
                localHeaderOffset: localHeaderOffset
            )
        )
    }

    mutating func finalize() throws -> Data {
        var centralDirectory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let nameLength = try uint16(name.count, label: "\(entry.path) name length")

            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0x0800)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(entry.crc32)
            centralDirectory.appendUInt32LE(entry.size)
            centralDirectory.appendUInt32LE(entry.size)
            centralDirectory.appendUInt16LE(nameLength)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(entry.localHeaderOffset)
            centralDirectory.append(name)
        }

        let centralDirectoryOffset = try uint32(archive.count, label: "ZIP central directory offset")
        let centralDirectorySize = try uint32(centralDirectory.count, label: "ZIP central directory size")
        let entryCount = try uint16(entries.count, label: "ZIP entry count")

        archive.append(centralDirectory)
        archive.appendUInt32LE(0x0605_4B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(entryCount)
        archive.appendUInt16LE(entryCount)
        archive.appendUInt32LE(centralDirectorySize)
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)
        return archive
    }

    private func uint16(_ value: Int, label: String) throws -> UInt16 {
        guard value >= 0, value <= Int(UInt16.max) else {
            throw DocumentAdapterError.writeFailed(underlying: "\(label) exceeds ZIP32 limits")
        }
        return UInt16(value)
    }

    private func uint32(_ value: Int, label: String) throws -> UInt32 {
        guard value >= 0, value <= Int(UInt32.max) else {
            throw DocumentAdapterError.writeFailed(underlying: "\(label) exceeds ZIP32 limits")
        }
        return UInt32(value)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private let crc32Table: [UInt32] = (0 ..< 256).map { value in
        var crc = UInt32(value)
        for _ in 0 ..< 8 {
            if crc & 1 == 1 {
                crc = 0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0x00FF),
            UInt8((value >> 8) & 0x00FF),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0x0000_00FF),
            UInt8((value >> 8) & 0x0000_00FF),
            UInt8((value >> 16) & 0x0000_00FF),
            UInt8((value >> 24) & 0x0000_00FF),
        ])
    }
}
