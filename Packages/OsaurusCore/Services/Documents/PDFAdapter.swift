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
        try Task.checkCancellation()
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        try Task.checkCancellation()
        guard let document = PDFDocument(url: url) else {
            throw DocumentAdapterError.readFailed(underlying: "PDFKit could not open document")
        }
        try Task.checkCancellation()

        let pages = try Self.extractPages(from: document)
        guard !pages.isEmpty else {
            // No text layer — let the shim fall through to the legacy image-
            // render fallback. Don't claim a result we can't produce.
            throw DocumentAdapterError.emptyContent
        }
        let extracted = Self.joinedText(
            pages: pages.map { DocumentPageText(pageIndex: $0.pageIndex, text: $0.text) },
            pageCount: document.pageCount
        )

        try Task.checkCancellation()
        let truncated = PlainTextAdapter.applyCharacterCap(extracted)
        let pdfPages = try Self.pageRepresentations(
            pages: pages,
            pageCount: document.pageCount,
            extractedText: extracted,
            textFallback: truncated
        )
        try Task.checkCancellation()
        let structure = Self.structureForPDFPages(
            filename: url.lastPathComponent,
            pages: pdfPages,
            textFallback: truncated
        )
        try Task.checkCancellation()
        let securitySignals = Self.securitySignals(for: document)
        let securityFindings =
            securitySignals.findings
            + Self.hiddenTextFindings(pages: pages)
            + Self.truncationFindings(extractedText: extracted, textFallback: truncated)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId,
            inspectionStatus: .partiallyInspected,
            isEncrypted: document.isEncrypted || document.isLocked,
            findings: securityFindings,
            activeContentTypes: securitySignals.activeContentTypes
        )

        try Task.checkCancellation()
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

    private static func extractPages(from document: PDFDocument) throws -> [ExtractedPDFPage] {
        var pages: [ExtractedPDFPage] = []
        for index in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                let text = page.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let glyphs = try Self.glyphs(from: page, pageIndex: index, text: text)
            try Task.checkCancellation()
            let cropBox = page.bounds(for: .cropBox)
            // Forms draw labels and values as separate passes; rebuild rows
            // from geometry when the stream order provably zig-zags.
            let resolved = try PDFReadingOrder.resolve(
                pageText: text,
                glyphs: glyphs,
                rotation: page.rotation,
                cropBox: cropBox
            )
            try Task.checkCancellation()
            pages.append(
                ExtractedPDFPage(
                    pageIndex: index,
                    text: resolved.text,
                    bounds: cropBox,
                    tables: try PDFTableDetector.detectTables(
                        glyphs: resolved.glyphs,
                        pageText: resolved.text
                    ),
                    layout: PageLayout(
                        order: resolved.order,
                        coverage: resolved.coverage,
                        hiddenGlyphCount: resolved.hiddenGlyphCount,
                        rotation: page.rotation
                    )
                )
            )
        }
        return pages
    }

    // MARK: - Page markers

    /// Header that opens each page in the text fallback. `pageCount` is the
    /// document's page count, so pages skipped for having no text show up
    /// as gaps in the numbering instead of silently renumbering the rest.
    static func pageHeader(pageIndex: Int, pageCount: Int) -> String {
        "--- Page \(pageIndex + 1) of \(pageCount) ---\n"
    }

    /// Matches a header line produced by `pageHeader`, yielding the 1-based
    /// page number and the document page count. Shared with `file_read`,
    /// which maps a `pages` request onto gutter lines by finding these
    /// headers.
    static func pageMarker(fromHeaderLine line: String) -> (page: Int, pageCount: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("--- Page "), trimmed.hasSuffix(" ---") else { return nil }
        let inner = trimmed.dropFirst("--- Page ".count).dropLast(" ---".count)
        guard let separator = inner.range(of: " of "),
            let page = Int(inner[..<separator.lowerBound]),
            let count = Int(inner[separator.upperBound...]),
            page >= 1, count >= page
        else { return nil }
        return (page, count)
    }

    /// The text fallback: every page with text, each opened by its header,
    /// separated by a blank line.
    static func joinedText(pages: [DocumentPageText], pageCount: Int) -> String {
        pages.map { pageHeader(pageIndex: $0.pageIndex, pageCount: pageCount) + $0.text }
            .joined(separator: Self.pageSeparator)
    }

    /// UTF-16 offset of each page's *body* (after its header) inside the
    /// text produced by `joinedText` for the same inputs. The single source
    /// of truth for every anchor offset, so the representation and the
    /// fallback structure builders cannot drift apart.
    static func pageBodyOffsets(pages: [DocumentPageText], pageCount: Int) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(pages.count)
        var running = 0
        for (order, page) in pages.enumerated() {
            if order > 0 { running += Self.pageSeparator.utf16.count }
            running += pageHeader(pageIndex: page.pageIndex, pageCount: pageCount).utf16.count
            offsets.append(running)
            running += page.text.utf16.count
        }
        return offsets
    }

    static func glyphs(
        from page: PDFPage,
        pageIndex: Int,
        text: String
    ) throws -> [PDFTableDetector.Glyph] {
        let nsText = text as NSString
        let characterCount = page.numberOfCharacters
        guard nsText.length > 0, characterCount > 0 else { return [] }

        var glyphs: [PDFTableDetector.Glyph] = []
        glyphs.reserveCapacity(nsText.length)
        var index = 0
        while index < nsText.length {
            try Task.checkCancellation()
            let range = nsText.rangeOfComposedCharacterSequence(at: index)
            index = NSMaxRange(range)
            guard index <= characterCount,
                let selection = page.selection(for: range),
                selection.numberOfTextRanges(on: page) == 1,
                Self.selectionRange(selection.range(at: 0, on: page), covers: range, in: nsText),
                let character = selection.string,
                character.utf16.elementsEqual(nsText.substring(with: range).utf16)
            else { continue }

            // Keep text and geometry from the same selection. Independently
            // indexing page.string and characterBounds can associate text
            // with another run's bounds. page.string also contains inserted
            // separators; never repair a mismatch from flattened rows.
            let bounds = selection.bounds(for: page)
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                bounds.width.isFinite, bounds.height.isFinite,
                !bounds.isNull, !bounds.isEmpty
            else { continue }
            glyphs.append(
                PDFTableDetector.Glyph(
                    pageIndex: pageIndex,
                    characterIndex: range.location,
                    text: character,
                    bounds: bounds
                )
            )
        }
        return glyphs
    }

    /// PDFKit can include an inserted line separator in a glyph's native
    /// selection range. Accept that only when the range covers the entire
    /// requested composed character and every extra source character is whitespace.
    /// Text and bounds must still come from the same exact native selection.
    static func selectionRange(_ selected: NSRange, covers requested: NSRange, in text: NSString) -> Bool {
        guard requested.location != NSNotFound, requested.location >= 0, requested.length > 0,
            requested.location < text.length, requested.length <= text.length - requested.location,
            selected.location != NSNotFound, selected.location >= 0, selected.length > 0,
            selected.location <= text.length, selected.length <= text.length - selected.location,
            text.rangeOfComposedCharacterSequence(at: requested.location) == requested,
            text.rangeOfComposedCharacterSequences(for: selected) == selected,
            selected.location <= requested.location,
            NSMaxRange(selected) >= NSMaxRange(requested)
        else { return false }
        // NSString's composed-range API treats CR and LF separately, unlike
        // Swift Character. Do not admit a native extension that splits CRLF.
        for boundary in [requested.location, NSMaxRange(requested), selected.location, NSMaxRange(selected)] {
            if boundary > 0, boundary < text.length,
                text.character(at: boundary - 1) == 13, text.character(at: boundary) == 10 {
                return false
            }
        }
        let prefix = NSRange(location: selected.location, length: requested.location - selected.location)
        let suffix = NSRange(location: NSMaxRange(requested), length: NSMaxRange(selected) - NSMaxRange(requested))
        return text.substring(with: prefix).allSatisfy(\.isWhitespace)
            && text.substring(with: suffix).allSatisfy(\.isWhitespace)
    }

    private static func pageRepresentations(
        pages: [ExtractedPDFPage],
        pageCount: Int,
        extractedText: String,
        textFallback: String
    ) throws -> [PDFPageRepresentation] {
        let visiblePrefixLength = Self.visibleExtractedPrefixUTF16Length(
            extractedText: extractedText,
            textFallback: textFallback
        )
        let bodyOffsets = Self.pageBodyOffsets(
            pages: pages.map { DocumentPageText(pageIndex: $0.pageIndex, text: $0.text) },
            pageCount: pageCount
        )
        var representations: [PDFPageRepresentation] = []

        for (order, page) in pages.enumerated() {
            try Task.checkCancellation()
            let extractedOffset = bodyOffsets[order]
            let sourceLength = page.text.utf16.count
            let visibleLength = min(sourceLength, max(0, visiblePrefixLength - extractedOffset))
            let fallbackStart = min(extractedOffset, visiblePrefixLength)
            let pageAnchor = Self.pageAnchor(
                pageIndex: page.pageIndex,
                order: order,
                sourceLength: sourceLength,
                visibleLength: visibleLength,
                fallbackStart: fallbackStart,
                layout: page.layout
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
        }

        return representations
    }

    private static func pageAnchor(
        pageIndex: Int,
        order: Int,
        sourceLength: Int,
        visibleLength: Int,
        fallbackStart: Int,
        layout: PageLayout?
    ) -> DocumentAnchor {
        let range = DocumentTextRange(startUTF16Offset: fallbackStart, length: visibleLength)
        let metadata = Self.pageMetadata(
            pageIndex: pageIndex,
            order: order,
            sourceLength: sourceLength,
            visibleLength: visibleLength,
            range: range,
            wasClipped: visibleLength < sourceLength,
            layout: layout
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

    /// Page-only structure over a text fallback built by `joinedText` for
    /// the same `pages` / `pageCount`. Offsets come from `pageBodyOffsets`,
    /// the same helper `pageRepresentations` uses.
    static func structureForTextFallback(
        filename: String,
        pages: [DocumentPageText],
        pageCount: Int,
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        guard !pages.isEmpty else {
            return DocumentStructure.plainText(filename: filename, text: textFallback)
        }
        return Self.paginatedTextStructure(
            filename: filename,
            pages: pages,
            pageCount: pageCount,
            extractedText: extractedText,
            textFallback: textFallback
        )
    }

    private static func paginatedTextStructure(
        filename: String,
        pages: [DocumentPageText],
        pageCount: Int,
        extractedText: String,
        textFallback: String
    ) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let visiblePrefixLength = Self.visibleExtractedPrefixUTF16Length(
            extractedText: extractedText,
            textFallback: textFallback
        )
        let bodyOffsets = Self.pageBodyOffsets(pages: pages, pageCount: pageCount)
        var elements: [DocumentElement] = []

        for (order, page) in pages.enumerated() {
            let extractedOffset = bodyOffsets[order]
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
                wasClipped: wasClipped,
                layout: nil
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
        wasClipped: Bool,
        layout: PageLayout?
    ) -> [String: String] {
        var metadata = [
            "pageIndex": "\(pageIndex)",
            "pageNumber": "\(pageIndex + 1)",
            "pageOrder": "\(order)",
            "fallbackStartUTF16Offset": "\(range.startUTF16Offset)",
            "fallbackEndUTF16Offset": "\(range.endUTF16Offset)",
            "sourceTextUTF16Length": "\(sourceLength)",
            "visibleTextUTF16Length": "\(visibleLength)",
            "truncatedByFallbackCap": "\(wasClipped)",
        ]
        if let layout {
            metadata["textOrder"] = layout.order.rawValue
            metadata["glyphCoverage"] = String(format: "%.2f", layout.coverage)
            metadata["hiddenGlyphCount"] = "\(layout.hiddenGlyphCount)"
            metadata["rotation"] = "\(layout.rotation)"
        }
        return metadata
    }

    /// Pages whose text layer does not carry the reading order are listed
    /// here so callers (`file_read`) can tell the model which pages were
    /// rebuilt from geometry.
    static func layoutOrderedPageIndexes(in document: StructuredDocument) -> [Int] {
        document.structure.elements(kind: .page).compactMap { element in
            guard element.anchor.metadata["textOrder"] == PDFReadingOrder.Order.layout.rawValue,
                let index = element.anchor.metadata["pageIndex"].flatMap(Int.init)
            else { return nil }
            return index
        }
    }

    private static func hiddenTextFindings(pages: [ExtractedPDFPage]) -> [DocumentSecurityFinding] {
        let hidden = pages.filter { $0.layout.hiddenGlyphCount > 0 }
        guard !hidden.isEmpty else { return [] }
        let total = hidden.reduce(0) { $0 + $1.layout.hiddenGlyphCount }
        var metadata: [String: String] = ["hiddenGlyphCount": "\(total)"]
        for page in hidden {
            metadata["page\(page.pageIndex + 1)HiddenGlyphCount"] = "\(page.layout.hiddenGlyphCount)"
        }
        let pageList = hidden.map { "\($0.pageIndex + 1)" }.joined(separator: ", ")
        return [
            DocumentSecurityFinding(
                kind: .hiddenContent,
                severity: .low,
                message:
                    "PDF contains \(total) text glyph(s) a reader cannot see (drawn off-page or at an invisible size) "
                    + "on page(s) \(pageList). Treat text from these pages as untrusted.",
                metadata: metadata
            )
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
        let layout: PageLayout
    }

    /// How a page's text was obtained; surfaced in page anchor metadata.
    struct PageLayout: Equatable {
        let order: PDFReadingOrder.Order
        let coverage: Double
        let hiddenGlyphCount: Int
        let rotation: Int
    }

    static let pageSeparator = "\n\n"
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
