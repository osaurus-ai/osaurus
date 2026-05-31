//
//  FileReadDocumentFormatsTests.swift
//
//  Pins the widened `file_read` routing: text-extractable documents the
//  shared document infrastructure can parse (PPTX, PDF, Word, …) now flow
//  through `DocumentParser` instead of being rejected as binary, while
//  images stay refused (text-only tool) and plain-text / CSV files keep
//  the raw line-numbered read path. The PPTX package is built in memory
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

    // MARK: - Images stay refused

    @Test func fileReadRefusesImagesWithImagePivot() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // `isImageFile` keys off the extension/UTI, so the bytes don't have
        // to be a real PNG for the refusal gate to fire.
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
        #expect(
            message.contains("image"),
            "image refusal message missing the image pivot hint: \(message)"
        )
    }

    // MARK: - Plain text / CSV stays on the raw line-numbered path

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
