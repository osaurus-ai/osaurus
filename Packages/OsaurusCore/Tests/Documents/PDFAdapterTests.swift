//
//  PDFAdapterTests.swift
//  osaurusTests
//
//  Exercises the text-layer PDF adapter. Synthesises tiny PDFs via Core
//  Graphics so the test bundle doesn't carry binary fixtures. The
//  image-only fallback path stays in the legacy `DocumentParser` switch
//  for now; the adapter intentionally throws `.emptyContent` when there's
//  no text layer so the shim can fall through.
//

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import OsaurusCore

@Suite("PDFAdapter")
struct PDFAdapterTests {

    @Test func canHandle_acceptsPDFExtensionOnly() {
        let adapter = PDFAdapter()
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.pdf"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.PDF"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/a.txt"), uti: nil) == false)
    }

    @Test func parse_readsTextLayer() async throws {
        let url = try Self.writePDF(text: "Hello PDF body content")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        #expect(doc.formatId == "pdf")
        #expect(doc.textFallback.contains("Hello PDF body content"))
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)
        #expect(representation.pages.count == 1)
        #expect(representation.pages[0].text.contains("Hello PDF body content"))
        #expect(doc.structure.elements(kind: .page).count == 1)
        #expect(doc.structure.elements(kind: .page).first?.anchor.sourceRange?.start.pageIndex == 0)
        #expect(doc.security.inspectionStatus == .partiallyInspected)
        #expect(doc.security.findings.contains { $0.kind == .unsupportedFeature })
    }

    @Test func parse_preservesPageSourceLocationsForMultiPagePDF() async throws {
        let url = try Self.writePDF(pages: [
            "First page text",
            "Second 😀 page",
            "Third page text",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let pages = doc.structure.elements(kind: .page)
        #expect(pages.count == 3)
        #expect(doc.structure.textLengthUTF16 == doc.textFallback.utf16.count)
        try Self.expectAnchorRangesWithinFallback(pages, fallbackLength: doc.textFallback.utf16.count)

        let firstText = try #require(pages[0].text)
        let secondText = try #require(pages[1].text)
        let firstRange = try #require(pages[0].anchor.textRange)
        let secondRange = try #require(pages[1].anchor.textRange)
        let thirdRange = try #require(pages[2].anchor.textRange)

        #expect(firstRange.startUTF16Offset == 0)
        #expect(secondRange.startUTF16Offset == firstText.utf16.count + 2)
        #expect(thirdRange.startUTF16Offset == secondRange.endUTF16Offset + 2)
        #expect(pages.map { $0.anchor.sourceRange?.start.pageIndex ?? -1 } == [0, 1, 2])
        #expect(pages.map { $0.anchor.sourceRange?.end?.pageIndex ?? -1 } == [0, 1, 2])
        #expect(pages[0].anchor.sourceRange?.start.characterOffset == 0)
        #expect(pages[1].anchor.sourceRange?.end?.characterOffset == secondText.utf16.count)
        #expect(pages.map { $0.anchor.metadata["pageOrder"] ?? "" } == ["0", "1", "2"])
    }

    @Test func parse_skipsBlankPagesButKeepsOriginalPageNumbers() async throws {
        let url = try Self.writePDF(pages: [
            "Visible first page",
            "",
            "Visible third page",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let pages = doc.structure.elements(kind: .page)

        #expect(pages.count == 2)
        #expect(pages.map { $0.anchor.sourceRange?.start.pageIndex ?? -1 } == [0, 2])
        #expect(pages.map { $0.anchor.label ?? "" } == ["Page 1", "Page 3"])
        #expect(pages.map { $0.anchor.metadata["pageOrder"] ?? "" } == ["0", "1"])
    }

    @Test func structureForTextFallback_clipsPageAnchorsWhenFallbackIsCapped() throws {
        let pages = [
            DocumentPageText(pageIndex: 0, text: "first"),
            DocumentPageText(pageIndex: 1, text: "😀second"),
            DocumentPageText(pageIndex: 2, text: "third"),
        ]
        let extracted = "first\n\n😀second\n\nthird"
        let fallback = "first\n\n😀se"

        let structure = PDFAdapter.structureForTextFallback(
            filename: "long.pdf",
            pages: pages,
            extractedText: extracted,
            textFallback: fallback
        )

        let pageElements = structure.elements(kind: .page)
        #expect(pageElements.count == 3)
        #expect(structure.elements(kind: .paragraph).isEmpty)
        #expect(structure.textLengthUTF16 == fallback.utf16.count)
        try Self.expectAnchorRangesWithinFallback(pageElements, fallbackLength: fallback.utf16.count)

        let firstRange = try #require(pageElements[0].anchor.textRange)
        let secondRange = try #require(pageElements[1].anchor.textRange)
        let thirdRange = try #require(pageElements[2].anchor.textRange)

        #expect(firstRange == DocumentTextRange(startUTF16Offset: 0, length: "first".utf16.count))
        #expect(secondRange.startUTF16Offset == "first\n\n".utf16.count)
        #expect(secondRange.length == "😀se".utf16.count)
        #expect(thirdRange.startUTF16Offset == fallback.utf16.count)
        #expect(thirdRange.isEmpty)
        #expect(pageElements[1].text == "😀se")
        #expect(pageElements[2].text == nil)
        #expect(pageElements[1].anchor.sourceRange?.end?.characterOffset == "😀se".utf16.count)
        #expect(pageElements[2].anchor.metadata["truncatedByFallbackCap"] == "true")
    }

    @Test func parse_throwsEmptyContentForPDFWithNoTextLayer() async throws {
        let url = try Self.writeBlankPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        }
    }

    @Test func parse_throwsSizeLimitExceededAboveCap() async throws {
        let url = try Self.writePDF(text: "tiny")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await PDFAdapter().parse(url: url, sizeLimit: 1)
        }
    }

    @Test func parse_detectsSimpleTextLayerTable() async throws {
        let url = try Self.writeTablePDF(rows: [
            ["Quarter", "Revenue"],
            ["Q1", "1200"],
            ["Q2", "1800"],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)
        let table = try #require(representation.pages.first?.tables.first)

        #expect(table.rows.count == 3)
        #expect(table.columnCount == 2)
        #expect(table.rows[0].cells.map(\.text) == ["Quarter", "Revenue"])
        #expect(table.rows[2].cells.map(\.text) == ["Q2", "1800"])
        #expect(table.anchor.sourceRange?.start.pageIndex == 0)
        #expect(table.anchor.sourceRange?.boundingBox?.coordinateSpace == .page)
        #expect(doc.structure.elements(kind: .table).count == 1)
        #expect(doc.structure.elements(kind: .tableCell).map(\.text).contains("Revenue"))
    }

    @Test func parse_detectsTableInsideMixedProsePDF() async throws {
        let url = try Self.writeMixedProseAndTablePDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)
        let page = try #require(representation.pages.first)
        let table = try #require(page.tables.first)

        #expect(doc.textFallback.contains("Quarterly summary"))
        #expect(doc.textFallback.contains("Prepared by Finance"))
        #expect(page.tables.count == 1)
        #expect(table.rows.count == 3)
        #expect(table.rows[0].cells.map(\.text) == ["Metric", "Value"])
        #expect(table.rows[1].cells.map(\.text) == ["Revenue", "1200"])
        #expect(table.anchor.metadata["detector"] == "glyph-geometry")
    }

    @Test func parse_ignoresSingleRowTableCandidateWithoutCrashing() async throws {
        let url = try Self.writeTablePDF(rows: [["Label", "Value"]])
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)

        #expect(representation.pages.first?.tables.isEmpty == true)
        #expect(doc.structure.elements(kind: .table).isEmpty)
    }

    @Test func glyphs_preserveTextAndBoundsBeforeFlattenedRowReconciliation() throws {
        let url = try Self.writeMixedProseAndTablePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let glyphs = try PDFAdapter.glyphs(from: page, pageIndex: 0, text: text)

        // Test the collector without the flattened page text. The old row
        // reconciliation could hide wrong character/bounds pairings here.
        let tables = try PDFTableDetector.detectTables(glyphs: glyphs)
        #expect(tables.count == 1)
        let table = try #require(tables.first)
        #expect(table.rows.map { $0.cells.map(\.text) } == [
            ["Metric", "Value"],
            ["Revenue", "1200"],
            ["Expenses", "800"],
        ])
        let nsText = text as NSString
        for glyph in table.rows.flatMap(\.glyphs) {
            let range = NSRange(location: glyph.characterRange.lowerBound, length: glyph.characterRange.count)
            let selection = try #require(page.selection(for: range))
            #expect(glyph.text.utf16.elementsEqual(nsText.substring(with: range).utf16))
            #expect(glyph.text == selection.string)
            #expect(glyph.bounds == selection.bounds(for: page))
        }
    }

    @Test(arguments: [CellDrawingOrder.columnMajor, .reversed])
    func parse_preservesVisualPairsAcrossCellDrawingOrders(order: CellDrawingOrder) async throws {
        let rows = [["Line", "Value"], ["10", "101"], ["11", "202"]]
        let url = try Self.writeTablePDF(rows: rows, drawingOrder: order)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)
        let page = try #require(representation.pages.first)
        #expect(page.tables.count == 1)
        let table = try #require(page.tables.first)
        #expect(table.rows.map { $0.cells.map(\.text) } == rows)
        #expect(table.columnCount == 2)
        for row in table.rows {
            try #require(row.cells.count == 2)
            #expect(row.cells[0].bounds.x < row.cells[1].bounds.x)
        }
    }

    @Test func glyphs_rejectTextThatDoesNotIdentifyNativeSelection() throws {
        let url = try Self.writeTablePDF(rows: [["Quarter", "Revenue"], ["Q1", "1200"]])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let original = try PDFAdapter.glyphs(from: page, pageIndex: 0, text: text)
        let target = try #require(original.first { $0.text == "Q" })
        let mismatched = NSMutableString(string: text)
        mismatched.replaceCharacters(in: NSRange(location: target.characterIndex, length: 1), with: "Z")

        let rejected = try PDFAdapter.glyphs(from: page, pageIndex: 0, text: mismatched as String)
        #expect(rejected == original.filter { $0.characterIndex != target.characterIndex })
        #expect(!rejected.contains { $0.text == "Z" })
    }

    @Test func glyphs_preserveComposedUTF16TextAndSourceRanges() async throws {
        let rows = [["Item", "Count"], ["Café", "101"], ["😀", "202"]]
        let url = try Self.writeTablePDF(rows: rows)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let glyphs = try PDFAdapter.glyphs(from: page, pageIndex: 0, text: text)
        let emoji = try #require(glyphs.first { $0.text == "😀" })
        #expect(emoji.characterRange.count == 2)
        #expect((text as NSString).substring(with: NSRange(
            location: emoji.characterRange.lowerBound, length: emoji.characterRange.count
        )) == "😀")

        let doc = try await PDFAdapter().parse(url: url, sizeLimit: 0)
        let representation = try #require(doc.representation.underlying as? PDFDocumentRepresentation)
        let table = try #require(representation.pages.first?.tables.first)
        #expect(table.rows.map { $0.cells.map(\.text) } == rows)
        let cell = try #require(table.rows.last?.cells.first)
        let sourceRange = try #require(cell.anchor.sourceRange)
        let end = try #require(sourceRange.end)
        let startOffset = try #require(sourceRange.start.characterOffset)
        let endOffset = try #require(end.characterOffset)
        #expect(endOffset - startOffset == 2)
        #expect(cell.anchor.textRange?.length == 2)
    }

    @Test func glyphSelectionRange_acceptsOnlyCompleteWhitespaceExtensions() {
        let rangeCases: [(String, String, NSRange, NSRange, Bool)] = [
            ("exact", "A", NSRange(location: 0, length: 1), NSRange(location: 0, length: 1), true),
            ("trailing_native_newline", "A\n", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), true),
            ("prefix_and_suffix_whitespace", " A\n", NSRange(location: 1, length: 1), NSRange(location: 0, length: 3), true),
            ("extra_visible_suffix", "AB", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("extra_visible_prefix", "BA", NSRange(location: 1, length: 1), NSRange(location: 0, length: 2), false),
            ("wrong_native_range", "AB", NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), false),
            ("source_out_of_bounds", "A", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("range_overflow", "A", NSRange(location: 0, length: 1), NSRange(location: 0, length: Int.max), false),
            ("not_found", "A", NSRange(location: 0, length: 1), NSRange(location: NSNotFound, length: 1), false),
            ("empty_requested", "A", NSRange(location: 0, length: 0), NSRange(location: 0, length: 1), false),
            ("emoji_complete_with_newline", "😀\n", NSRange(location: 0, length: 2), NSRange(location: 0, length: 3), true),
            ("emoji_partial_requested", "😀", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("combining_complete", "e\u{301}\n", NSRange(location: 0, length: 2), NSRange(location: 0, length: 3), true),
            ("combining_partial_requested", "e\u{301}", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("complete_CRLF_suffix", "A\r\n", NSRange(location: 0, length: 1), NSRange(location: 0, length: 3), true),
            ("partial_CRLF_suffix", "A\r\n", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("partial_CRLF_prefix", "\r\nA", NSRange(location: 2, length: 1), NSRange(location: 1, length: 2), false),
            ("partial_requested_CRLF_CR", "\r\n", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
            ("partial_requested_CRLF_LF", "\r\n", NSRange(location: 1, length: 1), NSRange(location: 0, length: 2), false),
            ("zero_width_is_not_whitespace", "A\u{200B}", NSRange(location: 0, length: 1), NSRange(location: 0, length: 2), false),
        ]
        for (name, text, requested, native, expected) in rangeCases {
            let admitted = PDFAdapter.selectionRange(native, covers: requested, in: text as NSString)
            #expect(admitted == expected, Comment(rawValue: name))
        }
    }

    // MARK: - Fixtures

    enum CellDrawingOrder {
        case rowMajor, columnMajor, reversed
    }

    private static func writePDF(text: String) throws -> URL {
        try Self.writePDF(pages: [text])
    }

    private static func writePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        for text in pages {
            ctx.beginPDFPage(nil)

            if !text.isEmpty {
                // Draw the text into the PDF context via NSAttributedString so
                // PDFKit can recover it from the text layer on read-back.
                let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                let font = NSFont.systemFont(ofSize: 14)
                NSAttributedString(string: text, attributes: [.font: font])
                    .draw(at: NSPoint(x: 20, y: 100))
                NSGraphicsContext.restoreGraphicsState()
            }

            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private static func writeTablePDF(
        rows: [[String]], drawingOrder: CellDrawingOrder = .rowMajor
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-table-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 220)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var cells = rows.enumerated().flatMap { rowIndex, row in
            row.enumerated().map { columnIndex, text in (rowIndex, columnIndex, text) }
        }
        switch drawingOrder {
        case .rowMajor:
            break
        case .columnMajor:
            cells.sort { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
            }
        case .reversed:
            cells.reverse()
        }
        for (rowIndex, columnIndex, text) in cells {
            let y = 160 - rowIndex * 24
            NSAttributedString(string: text, attributes: [.font: font])
                .draw(at: NSPoint(x: CGFloat(40 + columnIndex * 120), y: CGFloat(y)))
        }
        NSGraphicsContext.restoreGraphicsState()

        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func writeMixedProseAndTablePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-mixed-table-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 360, height: 280)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let tableFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        NSAttributedString(string: "Quarterly summary", attributes: [.font: bodyFont])
            .draw(at: NSPoint(x: 30, y: 220))
        NSAttributedString(string: "The table below captures reported values.", attributes: [.font: bodyFont])
            .draw(at: NSPoint(x: 30, y: 200))

        let rows = [
            ["Metric", "Value"],
            ["Revenue", "1200"],
            ["Expenses", "800"],
        ]
        for (rowIndex, row) in rows.enumerated() {
            let y = 160 - rowIndex * 24
            for (columnIndex, text) in row.enumerated() {
                NSAttributedString(string: text, attributes: [.font: tableFont])
                    .draw(at: NSPoint(x: CGFloat(40 + columnIndex * 130), y: CGFloat(y)))
            }
        }

        NSAttributedString(string: "Prepared by Finance", attributes: [.font: bodyFont])
            .draw(at: NSPoint(x: 30, y: 70))
        NSGraphicsContext.restoreGraphicsState()

        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func writeBlankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pdf-blank-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private enum FixtureError: Error { case contextCreationFailed }

    private static func expectAnchorRangesWithinFallback(
        _ pages: [DocumentElement],
        fallbackLength: Int
    ) throws {
        for page in pages {
            let range = try #require(page.anchor.textRange)
            #expect(range.startUTF16Offset <= fallbackLength)
            #expect(range.endUTF16Offset <= fallbackLength)
        }
    }
}
