//
//  FileReadDocumentFormatsTests.swift
//
//  Pins the widened `file_read` routing: text-extractable documents the
//  shared document infrastructure can parse (PPTX, PDF, Word, …) now flow
//  through `DocumentParser` instead of being rejected as binary, while
//  images stay refused (text-only tool) and UTF-8 source files such as
//  HTML/RTF/SVG/CSV keep the raw line-numbered read path. The PPTX package is built in memory
//  (stored ZIP, no checked-in binary) mirroring the OpenXML adapter tests.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadDocumentFormatsTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-read-formats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - PPTX (the headline new format)

    @Test func fileReadExtractsPPTXSlideText() async throws {
        // PPTX resolves through `DocumentFormatRegistry.shared` (via
        // DocumentParser), so make sure the built-in adapters are present.
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = root.appendingPathComponent("deck.pptx")
        try PPTXFixture.write(slideText: "Quarterly Strategy Review", to: deck)

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path":"deck.pptx"}"#)

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(
            text.contains("Quarterly Strategy Review"),
            "PPTX slide text was not extracted: \(text)"
        )
    }

    @Test func fileReadExtractsPDFTextLayerPages() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report.pdf")
        try Self.writePDF(pages: ["Executive summary", "Revenue table follows"], to: report)

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path":"report.pdf"}"#)

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("Executive summary"))
        #expect(text.contains("Revenue table follows"))
        #expect(text.contains("binary") == false)
    }

    // MARK: - PDF page markers, provenance note, `pages`

    @Test func pdfReadCarriesPageMarkersCountsAndProvenanceNote() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Page 2 is blank: it has no text layer and must show up as a gap,
        // not as a silently renumbered page.
        try Self.writePDF(pages: ["Executive summary", "", "Revenue table follows"], to: root.appendingPathComponent("report.pdf"))

        let result = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"report.pdf"}"#)
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        let payload = try #require(EnvelopeAssertions.successPayload(result))

        #expect(text.contains("|--- Page 1 of 3 ---"))
        #expect(!text.contains("--- Page 2 of 3 ---"))
        #expect(text.contains("|--- Page 3 of 3 ---"))
        #expect(payload["format"] as? String == "pdf")
        #expect(payload["source"] as? String == "extracted_text")
        #expect(payload["pages"] as? Int == 3)
        #expect(payload["pages_with_text"] as? Int == 2)
        #expect(payload["pages_layout_ordered"] as? Int == 0)
        #expect(payload["pages_requested"] == nil)

        let note = try #require(payload["note"] as? String)
        #expect(note.hasPrefix("Text layer of a 3-page PDF (1 page(s) have no text layer and are absent)."))
        #expect(note.contains("Gutter numbers are line numbers of the extracted text, not the document's own line or field numbers"))
        #expect(note.contains("`--- Page N of 3 ---` lines mark page boundaries"))
        #expect(note.contains("pass `pages`"))
        #expect(!note.contains("rebuilt from layout geometry"))
    }

    @Test func pdfReadOfFlattenedFormReportsLayoutOrderedPages() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try PDFFormFixture.write(to: root.appendingPathComponent("return.pdf"))

        let result = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"return.pdf"}"#)
        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        let payload = try #require(EnvelopeAssertions.successPayload(result))

        // Label and value on one visual row share a gutter line.
        #expect(text.contains("|9 Total income   184,554"), Comment(rawValue: text))
        #expect(text.contains("|Daniel M.   Reyes   XXX-XX-4821"), Comment(rawValue: text))
        #expect(payload["pages"] as? Int == 1)
        #expect(payload["pages_with_text"] as? Int == 1)
        #expect(payload["pages_layout_ordered"] as? Int == 1)
        let note = try #require(payload["note"] as? String)
        #expect(note.contains("1 page(s) were rebuilt from layout geometry so each label and its value share a line"))
        #expect(note.contains("gaps of three spaces separate columns"))
    }

    @Test func pdfReadPagesSelectsASinglePage() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Alpha page", "Bravo page", "Charlie page"], to: root.appendingPathComponent("report.pdf"))

        let result = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"report.pdf","pages":"2"}"#)
        #expect(ToolEnvelope.isSuccess(result), Comment(rawValue: result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        let payload = try #require(EnvelopeAssertions.successPayload(result))

        #expect(text.contains("--- Page 2 of 3 ---"))
        #expect(text.contains("Bravo page"))
        #expect(!text.contains("Alpha page"))
        #expect(!text.contains("Charlie page"))
        #expect(payload["pages_requested"] as? String == "2")
        // Page reads keep the global gutter: page 1 is lines 1-3
        // (header, body, blank), so page 2 starts at line 4.
        #expect(payload["start_line"] as? Int == 4)
        #expect(payload["end_line"] as? Int == 5)
        #expect(payload["total_lines"] as? Int == 8)
        #expect(payload["pages"] as? Int == 3)
    }

    @Test func pdfReadPagesSelectsAContiguousRangeAndAcceptsAnInteger() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Alpha page", "Bravo page", "Charlie page", "Delta page"], to: root.appendingPathComponent("report.pdf"))
        let tool = FileReadTool(rootPath: root)

        let range = try await tool.execute(argumentsJSON: #"{"path":"report.pdf","pages":"2-3"}"#)
        #expect(ToolEnvelope.isSuccess(range), Comment(rawValue: range))
        let rangeText = EnvelopeAssertions.successText(range) ?? ""
        #expect(rangeText.contains("Bravo page"))
        #expect(rangeText.contains("Charlie page"))
        #expect(!rangeText.contains("Alpha page"))
        #expect(!rangeText.contains("Delta page"))
        #expect(EnvelopeAssertions.successPayload(range)?["pages_requested"] as? String == "2-3")

        // Models often send numbers as JSON integers.
        let integer = try await tool.execute(argumentsJSON: #"{"path":"report.pdf","pages":4}"#)
        #expect(ToolEnvelope.isSuccess(integer), Comment(rawValue: integer))
        let integerText = EnvelopeAssertions.successText(integer) ?? ""
        #expect(integerText.contains("Delta page"))
        #expect(!integerText.contains("Charlie page"))
        #expect(EnvelopeAssertions.successPayload(integer)?["pages_requested"] as? String == "4")
    }

    @Test func pdfReadPagesOverridesStartAndEndLine() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Alpha page", "Bravo page", "Charlie page"], to: root.appendingPathComponent("report.pdf"))

        let result = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"report.pdf","pages":"3","start_line":1,"end_line":2}"#
        )
        #expect(ToolEnvelope.isSuccess(result), Comment(rawValue: result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("Charlie page"))
        #expect(!text.contains("Alpha page"))
    }

    @Test func pdfReadPagesRejectsOutOfRangeMalformedAndNonContiguous() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Alpha page", "Bravo page"], to: root.appendingPathComponent("report.pdf"))
        let tool = FileReadTool(rootPath: root)

        for (spec, expectedFragment) in [
            ("5", "between 1 and 2"),
            ("0", "between 1 and 2"),
            ("2-1", "contiguous range"),
            ("one", "contiguous range"),
            ("1,2", "separate calls for non-adjacent pages"),
        ] {
            let result = try await tool.execute(argumentsJSON: #"{"path":"report.pdf","pages":"\#(spec)"}"#)
            #expect(ToolEnvelope.isError(result), Comment(rawValue: result))
            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args", Comment(rawValue: result))
            #expect(EnvelopeAssertions.failureField(result) == "pages", Comment(rawValue: result))
            let envelope = result
            #expect(envelope.contains(expectedFragment), Comment(rawValue: "\(spec): \(result)"))
        }
    }

    @Test func pdfReadPagesIsRejectedForNonPDFFiles() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a\nb\nc".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"notes.txt","pages":"1"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(EnvelopeAssertions.failureField(result) == "pages")
        #expect((EnvelopeAssertions.failureMessage(result) ?? "").contains("is a .txt file"))
    }

    @Test func pdfReadPagesForATextlessPageSaysSo() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Alpha page", "", "Charlie page"], to: root.appendingPathComponent("report.pdf"))

        let result = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"report.pdf","pages":"2"}"#)
        #expect(ToolEnvelope.isSuccess(result), Comment(rawValue: result))
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["text"] as? String == "Page(s) 2 of this 3-page PDF have no extractable text layer.")
        #expect(payload["pages_requested"] as? String == "2")
        #expect(payload["pages"] as? Int == 3)

        // A range that straddles the blank page still returns its neighbours.
        let straddle = try await FileReadTool(rootPath: root).execute(argumentsJSON: #"{"path":"report.pdf","pages":"1-2"}"#)
        let straddleText = EnvelopeAssertions.successText(straddle) ?? ""
        #expect(straddleText.contains("Alpha page"))
        #expect(!straddleText.contains("Charlie page"))
    }

    @Test func parsePagesArgumentContract() throws {
        #expect(try FileReadTool.parsePagesArgument("3", pageCount: 11) == 3 ... 3)
        #expect(try FileReadTool.parsePagesArgument(" 3 - 5 ", pageCount: 11) == 3 ... 5)
        #expect(try FileReadTool.parsePagesArgument("11", pageCount: 0) == 11 ... 11)  // unknown page count: no upper bound

        #expect(throws: FileReadTool.PagesArgumentError.outOfRange(pageCount: 11)) {
            try FileReadTool.parsePagesArgument("12", pageCount: 11)
        }
        #expect(throws: FileReadTool.PagesArgumentError.outOfRange(pageCount: 11)) {
            try FileReadTool.parsePagesArgument("0", pageCount: 11)
        }
        #expect(throws: FileReadTool.PagesArgumentError.notContiguous) {
            try FileReadTool.parsePagesArgument("1,4-6", pageCount: 11)
        }
        for malformed in ["", "5-3", "a", "1-2-3", "-"] {
            #expect(throws: FileReadTool.PagesArgumentError.malformed, Comment(rawValue: malformed)) {
                try FileReadTool.parsePagesArgument(malformed, pageCount: 11)
            }
        }
    }

    @Test func lineRangeForPagesUsesHeadersAndExcludesTheSeparator() throws {
        let lines = [
            "--- Page 1 of 4 ---", "one", "",
            "--- Page 2 of 4 ---", "two a", "two b", "",
            "--- Page 4 of 4 ---", "four",
        ]
        #expect(try FileReadTool.lineRange(forPages: "1", in: lines) == 1 ... 2)
        #expect(try FileReadTool.lineRange(forPages: "2", in: lines) == 4 ... 6)
        #expect(try FileReadTool.lineRange(forPages: "1-2", in: lines) == 1 ... 6)
        #expect(try FileReadTool.lineRange(forPages: "4", in: lines) == 8 ... 9)
        #expect(try FileReadTool.lineRange(forPages: "2-4", in: lines) == 4 ... 9)
        // Page 3 has no text layer.
        #expect(try FileReadTool.lineRange(forPages: "3", in: lines) == nil)
        #expect(try FileReadTool.lineRange(forPages: "3-4", in: lines) == 8 ... 9)
        #expect(throws: FileReadTool.PagesArgumentError.outOfRange(pageCount: 4)) {
            try FileReadTool.lineRange(forPages: "5", in: lines)
        }
    }

    // MARK: - Mislabelled image bytes

    @Test func fileReadMislabelledImageBytesFailHonestly() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A `.png` that is not decodable as an image: the image branch must
        // fall back to a binary refusal that never claims text-only support.
        let image = root.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let tool = FileReadTool(rootPath: root)
        let envelope: String
        do {
            envelope = try await tool.execute(argumentsJSON: #"{"path":"photo.png"}"#)
        } catch {
            envelope = ToolEnvelope.fromError(error, tool: tool.name)
        }

        #expect(ToolEnvelope.isError(envelope))
        #expect(EnvelopeAssertions.failureRetryable(envelope) == false)
        let message = EnvelopeAssertions.failureMessage(envelope) ?? ""
        #expect(!message.contains("only supports text"), Comment(rawValue: message))
        #expect(!message.isEmpty)
    }

    // MARK: - Source / CSV stays on the raw line-numbered path

    @Test func fileWriteThenReadHTMLPreservesSource() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
            <!doctype html>
            <html>
            <body>
            <div id="board"></div>
            <script>
            document.querySelector("#board").textContent = "ready";
            </script>
            </body>
            </html>
            """
        let writeData = try JSONSerialization.data(
            withJSONObject: ["path": "minesweeper.html", "content": source]
        )
        let writeArguments = try #require(String(data: writeData, encoding: .utf8))
        let writeResult = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: writeArguments
        )
        #expect(ToolEnvelope.isSuccess(writeResult))

        let readResult = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"minesweeper.html"}"#
        )

        #expect(ToolEnvelope.isSuccess(readResult))
        let text = EnvelopeAssertions.successText(readResult) ?? ""
        #expect(text.contains("<!doctype html>"))
        #expect(text.contains(#"<div id="board"></div>"#))
        #expect(text.contains("document.querySelector(\"#board\")"))
        let payload = EnvelopeAssertions.successPayload(readResult)
        #expect(payload?["total_lines"] as? Int == source.components(separatedBy: .newlines).count)
    }

    @Test func fileWriteThenReadSVGPreservesSource() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
              <script>document.documentElement.dataset.ready = "true";</script>
              <rect id="tile" width="20" height="20"/>
            </svg>
            """
        let writeData = try JSONSerialization.data(
            withJSONObject: ["path": "board.svg", "content": source]
        )
        let writeArguments = try #require(String(data: writeData, encoding: .utf8))
        let writeResult = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: writeArguments
        )
        #expect(ToolEnvelope.isSuccess(writeResult))

        let readResult = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"board.svg"}"#
        )

        #expect(ToolEnvelope.isSuccess(readResult))
        let text = EnvelopeAssertions.successText(readResult) ?? ""
        #expect(text.contains(#"<script>document.documentElement.dataset.ready = "true";</script>"#))
        #expect(text.contains(#"<rect id="tile""#))
    }

    @Test @MainActor func fileReadRTFDDirectoryUsesDocumentExtraction() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "RTFD package text"
        let attributed = NSAttributedString(string: body)
        let wrapper = try attributed.fileWrapper(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        try wrapper.write(
            to: root.appendingPathComponent("note.rtfd"),
            options: .atomic,
            originalContentsURL: nil
        )

        let result = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.rtfd"}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        #expect((EnvelopeAssertions.successText(result) ?? "").contains(body))
    }

    @Test func fileReadUTF8SourceWinsOverImageExtension() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "not binary image bytes\nconst status = 'source';\n"
        try source.write(
            to: root.appendingPathComponent("mislabelled.png"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"mislabelled.png"}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        #expect((EnvelopeAssertions.successText(result) ?? "").contains("const status"))
    }

    @Test func fileReadCSVStaysRawLineNumbered() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let csv = root.appendingPathComponent("data.csv")
        try "Month,Revenue\nJan,1200\nFeb,1400".write(
            to: csv,
            atomically: true,
            encoding: .utf8
        )

        let tool = FileReadTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path":"data.csv","start_line":2,"end_line":2}"#)

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        // Raw path renders 1-indexed line numbers and honours start/end_line —
        // NOT the structured "Workbook:" preview the XLSX adapter emits.
        #expect(text.contains("Jan,1200"))
        #expect(text.contains("Workbook:") == false)
        let payload = EnvelopeAssertions.successPayload(result)
        #expect(payload?["total_lines"] as? Int == 3)
    }
}

/// Minimal in-memory PowerPoint (.pptx) package writer. Emits just enough
/// of the OpenXML structure for `PPTXAdapter` to extract one slide's text;
/// the ZIP container itself is built by the shared `OpenXMLZipFixture`.
private enum PPTXFixture {
    static func write(slideText: String, to url: URL) throws {
        let escaped =
            slideText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="xml" ContentType="application/xml"/>
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            </Types>
            """
        let presentation = """
            <?xml version="1.0" encoding="UTF-8"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst>
                <p:sldId id="256" r:id="rId1"/>
              </p:sldIdLst>
            </p:presentation>
            """
        let presentationRels = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
            </Relationships>
            """
        let slide = """
            <?xml version="1.0" encoding="UTF-8"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:sp><p:txBody><a:p><a:r><a:t>\(escaped)</a:t></a:r></a:p></p:txBody></p:sp>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """

        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("ppt/presentation.xml", Data(presentation.utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presentationRels.utf8)),
            ("ppt/slides/slide1.xml", Data(slide.utf8)),
        ]
        try OpenXMLZipFixture.write(entries: entries, to: url)
    }
}

private extension FileReadDocumentFormatsTests {
    static func writePDF(pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 220)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.contextCreationFailed
        }
        for (index, pageText) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            let font = NSFont.systemFont(ofSize: 14)
            NSAttributedString(
                string: pageText,
                attributes: [.font: font]
            )
            .draw(at: NSPoint(x: 24, y: 160 - CGFloat(index * 12)))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    enum PDFFixtureError: Error { case contextCreationFailed }
}
