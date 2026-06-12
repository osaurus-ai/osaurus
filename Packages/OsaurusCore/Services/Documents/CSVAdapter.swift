//
//  CSVAdapter.swift
//  osaurus
//
//  High-fidelity CSV/TSV reader for the document adapter stack. It keeps the
//  legacy text attachment contract by emitting a normalized fallback while
//  also preserving rows, cells, source offsets, and structure anchors.
//

import Foundation

/// CSV is the validation adapter for the plugin ABI because it already has a
/// mature core parser while still behaving like a simple record stream.
public struct CSVAdapter: DocumentFormatAdapter, FormatAdapter {
    public static var formatIdentifier: String { CSVDelimiter.comma.formatId }
    public static var detectionBytePatterns: [Data] { [] }

    public let delimiter: CSVDelimiter
    private let openState: OpenState

    public var formatId: String { delimiter.formatId }

    public init(delimiter: CSVDelimiter = .comma) {
        self.delimiter = delimiter
        self.openState = OpenState()
    }

    public func canHandle(url: URL, uti: String?) -> Bool {
        url.pathExtension.lowercased() == delimiter.fileExtension
    }

    public func openDocument(at url: URL) throws -> DocumentReference {
        guard canHandle(url: url, uti: nil) else {
            throw FormatAdapterError.unsupportedURL(
                formatIdentifier: formatId,
                pathExtension: url.pathExtension.lowercased()
            )
        }
        guard (try? url.checkResourceIsReachable()) == true else {
            throw DocumentAdapterError.readFailed(underlying: "File is not reachable")
        }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let reference = DocumentReference(
            formatIdentifier: formatId,
            displayName: url.lastPathComponent,
            fileSize: fileSize,
            metadata: ["delimiter": delimiter.rawValue]
        )
        openState.update(url: url, reference: reference)
        return reference
    }

    public func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
        defer { continuation.finish() }
        guard let opened = openState.openedDocument() else {
            throw FormatAdapterError.documentNotOpened(formatIdentifier: formatId)
        }

        let document = try await parse(
            url: opened.url,
            sizeLimit: DocumentLimits.limit(forFormatId: formatId)
        )
        guard let csv = document.representation.underlying as? CSVDocument else {
            throw FormatAdapterError.representationMismatch(formatIdentifier: formatId)
        }

        for row in csv.rows {
            try Task.checkCancellation()
            continuation.yield(
                Record(
                    index: row.rowIndex,
                    fields: row.cells.map(\.text),
                    anchorIdentifier: row.anchorId,
                    metadata: [
                        "documentId": opened.reference.id.uuidString,
                        "formatIdentifier": opened.reference.formatIdentifier,
                        "sourceStartUTF16": "\(row.sourceRange.startUTF16Offset)",
                        "sourceLengthUTF16": "\(row.sourceRange.length)",
                    ]
                )
            )
        }
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let source = try Self.readTextSource(url: url)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let parsedRows = CSVRowParser.parseRows(source: source, delimiter: delimiter)
        guard !parsedRows.isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let built = Self.buildDocument(
            filename: url.lastPathComponent,
            delimiter: delimiter,
            parsedRows: parsedRows,
            sourceTextLengthUTF16: source.utf16.count
        )
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: built.document
            ),
            structure: built.structure,
            security: security,
            textFallback: built.document.textFallback
        )
    }

    // MARK: - Reading

    private static func readTextSource(url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard let data = try? Data(contentsOf: url),
                let decoded = String(data: data, encoding: .isoLatin1)
            else {
                throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
            }
            return decoded
        }
    }

    // MARK: - Structure

    private static func buildDocument(
        filename: String,
        delimiter: CSVDelimiter,
        parsedRows: [CSVRowParser.Row],
        sourceTextLengthUTF16: Int
    ) -> BuiltCSVDocument {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let tableAnchor = DocumentAnchor(
            id: "document/table",
            kind: .table,
            path: [
                .init(kind: .document),
                .init(kind: .table, identifier: delimiter.formatId),
            ],
            textRange: DocumentTextRange(startUTF16Offset: 0, length: 0),
            sourceRange: .init(
                start: DocumentSourceLocation(characterOffset: 0, namedRegion: "source"),
                end: DocumentSourceLocation(characterOffset: sourceTextLengthUTF16, namedRegion: "source")
            ),
            label: filename,
            metadata: ["delimiter": delimiter.rawValue, "formatId": delimiter.formatId]
        )

        var fallback = ""
        var fallbackOffset = 0
        var rows: [CSVRow] = []
        var rowElements: [DocumentElement] = []

        for parsedRowIndex in parsedRows.indices {
            let parsedRow = parsedRows[parsedRowIndex]
            let rowStart = fallbackOffset
            var rowText = ""
            var cells: [CSVCell] = []
            var cellElements: [DocumentElement] = []

            for parsedCellIndex in parsedRow.cells.indices {
                let parsedCell = parsedRow.cells[parsedCellIndex]
                if parsedCellIndex > 0 {
                    fallback += "\t"
                    rowText += "\t"
                    fallbackOffset += 1
                }

                let cellStart = fallbackOffset
                fallback += parsedCell.text
                rowText += parsedCell.text
                fallbackOffset += parsedCell.text.utf16.count

                let cellTextRange = DocumentTextRange(
                    startUTF16Offset: cellStart,
                    length: parsedCell.text.utf16.count
                )
                let cellAnchor = makeCellAnchor(
                    rowIndex: parsedRowIndex,
                    columnIndex: parsedCellIndex,
                    textRange: cellTextRange,
                    sourceRange: parsedCell.sourceRange,
                    wasQuoted: parsedCell.wasQuoted
                )
                cells.append(
                    CSVCell(
                        rowIndex: parsedRowIndex,
                        columnIndex: parsedCellIndex,
                        text: parsedCell.text,
                        wasQuoted: parsedCell.wasQuoted,
                        sourceRange: parsedCell.sourceRange,
                        textRange: cellTextRange,
                        anchorId: cellAnchor.id
                    )
                )
                cellElements.append(
                    DocumentElement(
                        kind: .tableCell,
                        anchor: cellAnchor,
                        text: parsedCell.text,
                        attributes: .init(metadata: cellAnchor.metadata)
                    )
                )
            }

            let rowTextRange = DocumentTextRange(
                startUTF16Offset: rowStart,
                length: fallbackOffset - rowStart
            )
            let rowAnchor = makeRowAnchor(
                rowIndex: parsedRowIndex,
                textRange: rowTextRange,
                sourceRange: parsedRow.sourceRange
            )
            rows.append(
                CSVRow(
                    rowIndex: parsedRowIndex,
                    cells: cells,
                    sourceRange: parsedRow.sourceRange,
                    textRange: rowTextRange,
                    anchorId: rowAnchor.id
                )
            )
            rowElements.append(
                DocumentElement(
                    kind: .tableRow,
                    anchor: rowAnchor,
                    text: rowText,
                    attributes: .init(metadata: rowAnchor.metadata),
                    children: cellElements
                )
            )

            if parsedRowIndex < parsedRows.count - 1 {
                fallback += "\n"
                fallbackOffset += 1
            }
        }

        let tableElement = DocumentElement(
            kind: .table,
            anchor: DocumentAnchor(
                id: tableAnchor.id,
                kind: tableAnchor.kind,
                path: tableAnchor.path,
                textRange: DocumentTextRange(startUTF16Offset: 0, length: fallbackOffset),
                sourceRange: tableAnchor.sourceRange,
                label: tableAnchor.label,
                metadata: tableAnchor.metadata
            ),
            children: rowElements
        )
        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: [tableElement]
        )
        let structure = DocumentStructure(
            root: root,
            textLengthUTF16: fallbackOffset
        )
        let document = CSVDocument(
            delimiter: delimiter,
            rows: rows,
            sourceTextLengthUTF16: sourceTextLengthUTF16,
            textFallback: fallback
        )
        return BuiltCSVDocument(document: document, structure: structure)
    }

    private static func makeRowAnchor(
        rowIndex: Int,
        textRange: DocumentTextRange,
        sourceRange: DocumentTextRange
    ) -> DocumentAnchor {
        DocumentAnchor(
            id: "document/table/rows/\(rowIndex)",
            kind: .row,
            path: [
                .init(kind: .document),
                .init(kind: .table, identifier: "rows"),
                .init(kind: .row, index: rowIndex),
            ],
            textRange: textRange,
            sourceRange: makeSourceRange(sourceRange, rowIndex: rowIndex, columnIndex: nil),
            label: "Row \(rowIndex + 1)",
            metadata: [
                "rowIndex": "\(rowIndex)",
                "sourceStartUTF16": "\(sourceRange.startUTF16Offset)",
                "sourceLengthUTF16": "\(sourceRange.length)",
            ]
        )
    }

    private static func makeCellAnchor(
        rowIndex: Int,
        columnIndex: Int,
        textRange: DocumentTextRange,
        sourceRange: DocumentTextRange,
        wasQuoted: Bool
    ) -> DocumentAnchor {
        DocumentAnchor(
            id: "document/table/rows/\(rowIndex)/cells/\(columnIndex)",
            kind: .cell,
            path: [
                .init(kind: .document),
                .init(kind: .table, identifier: "rows"),
                .init(kind: .row, index: rowIndex),
                .init(kind: .cell, index: columnIndex),
            ],
            textRange: textRange,
            sourceRange: makeSourceRange(sourceRange, rowIndex: rowIndex, columnIndex: columnIndex),
            label: "R\(rowIndex + 1)C\(columnIndex + 1)",
            metadata: [
                "rowIndex": "\(rowIndex)",
                "columnIndex": "\(columnIndex)",
                "sourceStartUTF16": "\(sourceRange.startUTF16Offset)",
                "sourceLengthUTF16": "\(sourceRange.length)",
                "wasQuoted": "\(wasQuoted)",
            ]
        )
    }

    private static func makeSourceRange(
        _ range: DocumentTextRange,
        rowIndex: Int,
        columnIndex: Int?
    ) -> DocumentSourceRange {
        let start = DocumentSourceLocation(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            characterOffset: range.startUTF16Offset
        )
        let end = DocumentSourceLocation(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            characterOffset: range.endUTF16Offset
        )
        return DocumentSourceRange(start: start, end: end)
    }

    private struct BuiltCSVDocument {
        let document: CSVDocument
        let structure: DocumentStructure
    }

    private final class OpenState: @unchecked Sendable {
        private let lock = NSLock()
        private var current: OpenedDocument?

        func update(url: URL, reference: DocumentReference) {
            lock.lock()
            defer { lock.unlock() }
            current = OpenedDocument(url: url, reference: reference)
        }

        func openedDocument() -> OpenedDocument? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    private struct OpenedDocument: Sendable {
        let url: URL
        let reference: DocumentReference
    }
}
