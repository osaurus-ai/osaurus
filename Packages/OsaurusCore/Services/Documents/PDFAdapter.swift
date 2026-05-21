//
//  PDFAdapter.swift
//  osaurus
//
//  Wraps the text-layer extraction path in `DocumentParser.parsePDFWithFallback`.
//  Intentionally does NOT cover the image-rendering fallback — when a PDF has
//  no extractable text, this adapter throws `.emptyContent` and the
//  `DocumentParser` shim falls through to the legacy switch, which still
//  renders each page as PNG.
//

import Foundation
import PDFKit

public struct PDFAdapter: DocumentFormatAdapter {
    public let formatId = "pdf"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        guard let document = PDFDocument(url: url) else {
            throw DocumentAdapterError.readFailed(underlying: "PDFKit could not open document")
        }

        let pages = Self.extractPages(from: document)
        let extracted = pages.map(\.text).joined(separator: "\n\n")
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No text layer — let the shim fall through to the legacy image-
            // render fallback. Don't claim a result we can't produce.
            throw DocumentAdapterError.emptyContent
        }

        let truncated = PlainTextAdapter.applyCharacterCap(extracted)
        let pdfPages = Self.pageRepresentations(
            pages: pages,
            extractedText: extracted,
            textFallback: truncated
        )
        let structure = Self.structureForPDFPages(
            filename: url.lastPathComponent,
            pages: pdfPages,
            textFallback: truncated
        )
        let securitySignals = Self.securitySignals(for: document)
        let securityFindings =
            securitySignals.findings
            + Self.truncationFindings(extractedText: extracted, textFallback: truncated)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId,
            inspectionStatus: .partiallyInspected,
            isEncrypted: document.isEncrypted || document.isLocked,
            findings: securityFindings,
            activeContentTypes: securitySignals.activeContentTypes
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PDFDocumentRepresentation(pages: pdfPages)
            ),
            structure: structure,
            security: security,
            textFallback: truncated
        )
    }

    private static func extractPages(from document: PDFDocument) -> [ExtractedPDFPage] {
        var pages: [ExtractedPDFPage] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                let text = page.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let glyphs = Self.glyphs(from: page, pageIndex: index, text: text)
            pages.append(
                ExtractedPDFPage(
                    pageIndex: index,
                    text: text,
                    bounds: page.bounds(for: .cropBox),
                    tables: PDFTableDetector.detectTables(glyphs: glyphs, pageText: text)
                )
            )
        }
        return pages
    }

    private static func glyphs(
        from page: PDFPage,
        pageIndex: Int,
        text: String
    ) -> [PDFTableDetector.Glyph] {
        let nsText = text as NSString
        let count = min(page.numberOfCharacters, nsText.length)
        guard count > 0 else { return [] }

        return (0 ..< count).compactMap { index in
            let character = nsText.substring(with: NSRange(location: index, length: 1))
            let bounds = page.characterBounds(at: index)
            guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
            return PDFTableDetector.Glyph(
                pageIndex: pageIndex,
                characterIndex: index,
                text: character,
                bounds: bounds
            )
        }
    }

    private static func pageRepresentations(
        pages: [ExtractedPDFPage],
        extractedText: String,
        textFallback: String
    ) -> [PDFPageRepresentation] {
        let visiblePrefixLength = Self.visibleExtractedPrefixUTF16Length(
            extractedText: extractedText,
            textFallback: textFallback
        )
        var extractedOffset = 0
        var representations: [PDFPageRepresentation] = []

        for (order, page) in pages.enumerated() {
            if order > 0 {
                extractedOffset += Self.pageSeparatorUTF16Length
            }

            let sourceLength = page.text.utf16.count
            let visibleLength = min(sourceLength, max(0, visiblePrefixLength - extractedOffset))
            let fallbackStart = min(extractedOffset, visiblePrefixLength)
            let pageAnchor = Self.pageAnchor(
                pageIndex: page.pageIndex,
                order: order,
                sourceLength: sourceLength,
                visibleLength: visibleLength,
                fallbackStart: fallbackStart
            )
            let tables = page.tables.map { table in
                Self.pdfTable(
                    table,
                    pageIndex: page.pageIndex,
                    fallbackStart: fallbackStart,
                    visibleLength: visibleLength
                )
            }

            representations.append(
                PDFPageRepresentation(
                    pageIndex: page.pageIndex,
                    text: page.text,
                    bounds: Self.documentBoundingBox(page.bounds),
                    tables: tables,
                    anchor: pageAnchor
                )
            )
            extractedOffset += sourceLength
        }

        return representations
    }

    private static func pageAnchor(
        pageIndex: Int,
        order: Int,
        sourceLength: Int,
        visibleLength: Int,
        fallbackStart: Int
    ) -> DocumentAnchor {
        let range = DocumentTextRange(startUTF16Offset: fallbackStart, length: visibleLength)
        let metadata = Self.pageMetadata(
            pageIndex: pageIndex,
            order: order,
            sourceLength: sourceLength,
            visibleLength: visibleLength,
            range: range,
            wasClipped: visibleLength < sourceLength
        )
        return DocumentAnchor(
            kind: .page,
            path: [
                .init(kind: .document),
                .init(kind: .page, index: pageIndex),
            ],
            textRange: range,
            sourceRange: .init(
                start: .init(pageIndex: pageIndex, characterOffset: 0),
                end: .init(pageIndex: pageIndex, characterOffset: visibleLength)
            ),
            label: "Page \(pageIndex + 1)",
            metadata: metadata
        )
    }

    private static func pdfTable(
        _ table: PDFTableDetector.Table,
        pageIndex: Int,
        fallbackStart: Int,
        visibleLength: Int
    ) -> PDFTable {
        let rows = table.rows.map { row in
            Self.pdfTableRow(
                row,
                pageIndex: pageIndex,
                tableIndex: table.index,
                fallbackStart: fallbackStart,
                visibleLength: visibleLength
            )
        }
        let anchor = Self.anchor(
            kind: .table,
            pageIndex: pageIndex,
            path: Self.path(pageIndex: pageIndex, tableIndex: table.index),
            sourceRange: table.characterRange,
            bounds: table.bounds,
            fallbackStart: fallbackStart,
            visibleLength: visibleLength,
            label: "Page \(pageIndex + 1) Table \(table.index + 1)",
            metadata: [
                "pageIndex": "\(pageIndex)",
                "pageNumber": "\(pageIndex + 1)",
                "tableIndex": "\(table.index)",
                "rowCount": "\(rows.count)",
                "columnCount": "\(rows.map(\.cells.count).max() ?? 0)",
                "detector": "glyph-geometry",
            ]
        )
        return PDFTable(
            pageIndex: pageIndex,
            index: table.index,
            rows: rows,
            bounds: Self.documentBoundingBox(table.bounds) ?? .zeroPage,
            anchor: anchor
        )
    }

    private static func pdfTableRow(
        _ row: PDFTableDetector.Row,
        pageIndex: Int,
        tableIndex: Int,
        fallbackStart: Int,
        visibleLength: Int
    ) -> PDFTableRow {
        let cells = row.cells.map { cell in
            Self.pdfTableCell(
                cell,
                pageIndex: pageIndex,
                tableIndex: tableIndex,
                fallbackStart: fallbackStart,
                visibleLength: visibleLength
            )
        }
        let anchor = Self.anchor(
            kind: .row,
            pageIndex: pageIndex,
            path: Self.path(pageIndex: pageIndex, tableIndex: tableIndex, rowIndex: row.cells.first?.rowIndex ?? 0),
            sourceRange: row.characterRange,
            bounds: row.bounds,
            fallbackStart: fallbackStart,
            visibleLength: visibleLength,
            label: "Row \((row.cells.first?.rowIndex ?? 0) + 1)",
            metadata: [
                "pageIndex": "\(pageIndex)",
                "tableIndex": "\(tableIndex)",
                "rowIndex": "\(row.cells.first?.rowIndex ?? 0)",
                "cellCount": "\(cells.count)",
            ]
        )
        return PDFTableRow(
            index: row.cells.first?.rowIndex ?? 0,
            cells: cells,
            bounds: Self.documentBoundingBox(row.bounds) ?? .zeroPage,
            anchor: anchor
        )
    }

    private static func pdfTableCell(
        _ cell: PDFTableDetector.Cell,
        pageIndex: Int,
        tableIndex: Int,
        fallbackStart: Int,
        visibleLength: Int
    ) -> PDFTableCell {
        let anchor = Self.anchor(
            kind: .cell,
            pageIndex: pageIndex,
            path: Self.path(
                pageIndex: pageIndex,
                tableIndex: tableIndex,
                rowIndex: cell.rowIndex,
                columnIndex: cell.columnIndex
            ),
            sourceRange: cell.characterRange,
            bounds: cell.bounds,
            fallbackStart: fallbackStart,
            visibleLength: visibleLength,
            label: "R\(cell.rowIndex + 1)C\(cell.columnIndex + 1)",
            metadata: [
                "pageIndex": "\(pageIndex)",
                "tableIndex": "\(tableIndex)",
                "rowIndex": "\(cell.rowIndex)",
                "columnIndex": "\(cell.columnIndex)",
            ]
        )
        return PDFTableCell(
            rowIndex: cell.rowIndex,
            columnIndex: cell.columnIndex,
            text: cell.text,
            bounds: Self.documentBoundingBox(cell.bounds) ?? .zeroPage,
            anchor: anchor
        )
    }

    private static func anchor(
        kind: DocumentAnchor.Kind,
        pageIndex: Int,
        path: [DocumentAnchor.PathComponent],
        sourceRange: Range<Int>,
        bounds: CGRect,
        fallbackStart: Int,
        visibleLength: Int,
        label: String,
        metadata: [String: String]
    ) -> DocumentAnchor {
        let visibleStart = min(max(sourceRange.lowerBound, 0), visibleLength)
        let visibleEnd = min(max(sourceRange.upperBound, visibleStart), visibleLength)
        return DocumentAnchor(
            kind: kind,
            path: path,
            textRange: DocumentTextRange(
                startUTF16Offset: fallbackStart + visibleStart,
                length: visibleEnd - visibleStart
            ),
            sourceRange: .init(
                start: .init(pageIndex: pageIndex, characterOffset: sourceRange.lowerBound),
                end: .init(pageIndex: pageIndex, characterOffset: sourceRange.upperBound),
                boundingBox: Self.documentBoundingBox(bounds)
            ),
            label: label,
            metadata: metadata
        )
    }

    private static func path(
        pageIndex: Int,
        tableIndex: Int,
        rowIndex: Int? = nil,
        columnIndex: Int? = nil
    ) -> [DocumentAnchor.PathComponent] {
        var path: [DocumentAnchor.PathComponent] = [
            .init(kind: .document),
            .init(kind: .page, index: pageIndex),
            .init(kind: .table, index: tableIndex),
        ]
        if let rowIndex {
            path.append(.init(kind: .row, index: rowIndex))
        }
        if let columnIndex {
            path.append(.init(kind: .cell, index: columnIndex))
        }
        return path
    }

    private static func documentBoundingBox(_ rect: CGRect) -> DocumentBoundingBox? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return DocumentBoundingBox(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height),
            coordinateSpace: .page
        )
    }

    private static func structureForPDFPages(
        filename: String,
        pages: [PDFPageRepresentation],
        textFallback: String
    ) -> DocumentStructure {
        guard !pages.isEmpty else {
            return DocumentStructure.plainText(filename: filename, text: textFallback)
        }

        let rootAnchor = DocumentAnchor.root(label: filename)
        let pageElements = pages.map { page in
            DocumentElement(
                kind: .page,
                anchor: page.anchor,
                text: page.anchor.textRange?.isEmpty == true ? nil : clippedPageText(page),
                attributes: .init(metadata: page.anchor.metadata),
                children: page.tables.map(Self.tableElement)
            )
        }
        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: pageElements
        )
        return DocumentStructure(root: root, textLengthUTF16: textFallback.utf16.count)
    }

    private static func tableElement(_ table: PDFTable) -> DocumentElement {
        DocumentElement(
            kind: .table,
            anchor: table.anchor,
            attributes: .init(metadata: table.anchor.metadata),
            children: table.rows.map { row in
                DocumentElement(
                    kind: .tableRow,
                    anchor: row.anchor,
                    attributes: .init(metadata: row.anchor.metadata),
                    children: row.cells.map { cell in
                        DocumentElement(
                            kind: .tableCell,
                            anchor: cell.anchor,
                            text: cell.text,
                            attributes: .init(metadata: cell.anchor.metadata)
                        )
                    }
                )
            }
        )
    }

    private static func clippedPageText(_ page: PDFPageRepresentation) -> String? {
        guard let range = page.anchor.textRange, range.length > 0 else { return nil }
        return Self.prefix(page.text, maxUTF16Length: range.length)
    }

    static func structureForTextFallback(
        filename: String,
        pages: [DocumentPageText],
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        guard !pages.isEmpty else {
            return DocumentStructure.plainText(filename: filename, text: textFallback)
        }
        return Self.paginatedTextStructure(
            filename: filename,
            pages: pages,
            extractedText: extractedText,
            textFallback: textFallback
        )
    }

    private static func paginatedTextStructure(
        filename: String,
        pages: [DocumentPageText],
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let visiblePrefixLength = Self.visibleExtractedPrefixUTF16Length(
            extractedText: extractedText,
            textFallback: textFallback
        )
        var extractedOffset = 0
        var elements: [DocumentElement] = []

        for (order, page) in pages.enumerated() {
            if order > 0 {
                extractedOffset += Self.pageSeparatorUTF16Length
            }

            let sourceLength = page.text.utf16.count
            let visibleLength = min(sourceLength, max(0, visiblePrefixLength - extractedOffset))
            let fallbackStart = min(extractedOffset, visiblePrefixLength)
            let range = DocumentTextRange(startUTF16Offset: fallbackStart, length: visibleLength)
            let clippedText = Self.prefix(page.text, maxUTF16Length: visibleLength)
            let wasClipped = visibleLength < sourceLength
            let metadata = Self.pageMetadata(
                pageIndex: page.pageIndex,
                order: order,
                sourceLength: sourceLength,
                visibleLength: visibleLength,
                range: range,
                wasClipped: wasClipped
            )
            let anchor = DocumentAnchor(
                kind: .page,
                path: [
                    .init(kind: .document),
                    .init(kind: .page, index: page.pageIndex),
                ],
                textRange: range,
                sourceRange: .init(
                    start: .init(pageIndex: page.pageIndex, characterOffset: 0),
                    end: .init(pageIndex: page.pageIndex, characterOffset: visibleLength)
                ),
                label: "Page \(page.pageIndex + 1)",
                metadata: metadata
            )
            elements.append(
                DocumentElement(
                    kind: .page,
                    anchor: anchor,
                    text: clippedText.isEmpty ? nil : clippedText,
                    attributes: .init(metadata: metadata)
                )
            )
            extractedOffset += sourceLength
        }

        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: elements
        )
        return DocumentStructure(root: root, textLengthUTF16: textFallback.utf16.count)
    }

    private static func visibleExtractedPrefixUTF16Length(
        extractedText: String,
        textFallback: String
    ) -> Int {
        if extractedText == textFallback {
            return textFallback.utf16.count
        }

        // The fallback may contain the truncation marker, which is not source
        // PDF text. Only the shared prefix can safely receive page anchors.
        var extractedIndex = extractedText.startIndex
        var fallbackIndex = textFallback.startIndex
        var length = 0
        while extractedIndex < extractedText.endIndex && fallbackIndex < textFallback.endIndex {
            guard extractedText[extractedIndex] == textFallback[fallbackIndex] else { break }
            let nextExtractedIndex = extractedText.index(after: extractedIndex)
            length += extractedText[extractedIndex ..< nextExtractedIndex].utf16.count
            extractedIndex = nextExtractedIndex
            fallbackIndex = textFallback.index(after: fallbackIndex)
        }
        return length
    }

    private static func prefix(_ text: String, maxUTF16Length: Int) -> String {
        guard maxUTF16Length > 0 else { return "" }
        guard text.utf16.count > maxUTF16Length else { return text }

        var endIndex = text.startIndex
        var length = 0
        while endIndex < text.endIndex {
            let nextIndex = text.index(after: endIndex)
            let nextLength = text[endIndex ..< nextIndex].utf16.count
            guard length + nextLength <= maxUTF16Length else { break }
            length += nextLength
            endIndex = nextIndex
        }
        return String(text[..<endIndex])
    }

    private static func pageMetadata(
        pageIndex: Int,
        order: Int,
        sourceLength: Int,
        visibleLength: Int,
        range: DocumentTextRange,
        wasClipped: Bool
    ) -> [String: String] {
        [
            "pageIndex": "\(pageIndex)",
            "pageNumber": "\(pageIndex + 1)",
            "pageOrder": "\(order)",
            "fallbackStartUTF16Offset": "\(range.startUTF16Offset)",
            "fallbackEndUTF16Offset": "\(range.endUTF16Offset)",
            "sourceTextUTF16Length": "\(sourceLength)",
            "visibleTextUTF16Length": "\(visibleLength)",
            "truncatedByFallbackCap": "\(wasClipped)",
        ]
    }

    private static func securitySignals(
        for document: PDFDocument
    ) -> (findings: [DocumentSecurityFinding], activeContentTypes: Set<DocumentActiveContentType>) {
        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "PDF active content, embedded files, and annotations are not fully inspected by the text-layer adapter."
            )
        ]
        let activeContentTypes: Set<DocumentActiveContentType> = []

        if document.isEncrypted || document.isLocked {
            findings.append(
                DocumentSecurityFinding(
                    kind: .encryptedContent,
                    severity: document.isLocked ? .high : .low,
                    message: "PDF reports encrypted or locked content."
                )
            )
        }

        if !document.allowsCopying {
            findings.append(
                DocumentSecurityFinding(
                    kind: .permissionRestriction,
                    severity: .low,
                    message: "PDF permissions disallow copying."
                )
            )
        }

        return (findings, activeContentTypes)
    }

    private static func truncationFindings(
        extractedText: String,
        textFallback: String
    ) -> [DocumentSecurityFinding] {
        guard extractedText != textFallback else { return [] }
        return [
            DocumentSecurityFinding(
                kind: .truncatedContent,
                severity: .low,
                message: "PDF text fallback was character-capped; page anchors were clipped to visible fallback text.",
                metadata: [
                    "extractedUTF16Length": "\(extractedText.utf16.count)",
                    "fallbackUTF16Length": "\(textFallback.utf16.count)",
                ]
            )
        ]
    }

    private struct ExtractedPDFPage {
        let pageIndex: Int
        let text: String
        let bounds: CGRect
        let tables: [PDFTableDetector.Table]
    }

    private static let pageSeparatorUTF16Length = "\n\n".utf16.count
}

private extension DocumentBoundingBox {
    static let zeroPage = DocumentBoundingBox(
        x: 0,
        y: 0,
        width: 0,
        height: 0,
        coordinateSpace: .page
    )
}
