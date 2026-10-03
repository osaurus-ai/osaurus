//
//  FileSearchDocumentsTests.swift
//
//  `file_search` content mode looks inside PDF / Word / PowerPoint / Excel
//  through the same adapters `file_read` uses. Matches carry a page /
//  slide / sheet-row locator instead of a line number, extraction is
//  cached per path+mtime, the per-search document budget is honored, and
//  the skipped note names the document kinds it could not open.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileSearchDocumentsTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-search-docs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ root: URL, _ args: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = try #require(String(data: data, encoding: .utf8))
        return try await FileWriteTool(rootPath: root).execute(argumentsJSON: json)
    }

    private func search(_ root: URL, _ args: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = try #require(String(data: data, encoding: .utf8))
        return try await FileSearchTool(rootPath: root).execute(argumentsJSON: json)
    }

    @Test func findsTextInsideGeneratedDocxPdfAndXlsxWithLocators() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        await DocumentTextExtractionCache.shared.removeAll()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let docx = try await write(
            root,
            [
                "path": "contracts/alpha.docx",
                "content": "# Alpha agreement\n\nThe indemnification clause survives termination.\n",
            ]
        )
        #expect(ToolEnvelope.isSuccess(docx), "docx write failed: \(docx)")
        let pdf = try await write(
            root,
            [
                "path": "contracts/beta.pdf",
                "content": "# Beta agreement\n\nNo indemnification is offered under this contract.\n",
            ]
        )
        #expect(ToolEnvelope.isSuccess(pdf), "pdf write failed: \(pdf)")
        let xlsx = try await write(
            root,
            [
                "path": "contracts/index.xlsx",
                "content": "Contract,Clause\nAlpha,indemnification\nGamma,warranty\n",
            ]
        )
        #expect(ToolEnvelope.isSuccess(xlsx), "xlsx write failed: \(xlsx)")
        try "plain text with indemnification\n".write(
            to: root.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await search(root, ["pattern": "indemnification"])
        #expect(ToolEnvelope.isSuccess(result), "search failed: \(result)")
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("contracts/alpha.docx [paragraph"), "docx locator missing: \(text)")
        #expect(text.contains("contracts/beta.pdf [page 1]"), "pdf locator missing: \(text)")
        #expect(text.contains("contracts/index.xlsx [Sheet1 row 2]"), "xlsx locator missing: \(text)")
        #expect(text.contains("notes.txt:1:"), "plain text line number missing: \(text)")
        #expect(!text.contains("skipped"))
        // Extractions were cached (three documents).
        #expect(await DocumentTextExtractionCache.shared.count == 3)

        // Second search reuses the cache and still finds the same rows.
        let again = try await search(root, ["pattern": "warranty"])
        let againText = EnvelopeAssertions.successText(again) ?? ""
        #expect(againText.contains("contracts/index.xlsx [Sheet1 row 3]"))
        #expect(await DocumentTextExtractionCache.shared.count == 3)
    }

    @Test func flattenedFormRowIsOneSearchUnit() async throws {
        // A flattened form draws labels and values in separate passes, so
        // PDFKit's own text puts "9 Total income" and "184,554" on different
        // lines. Search must see the visual row the reader sees: searching
        // for the amount returns the label beside it on one `[page 1]` hit.
        DocumentAdaptersBootstrap.registerBuiltIns()
        await DocumentTextExtractionCache.shared.removeAll()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taxes = root.appendingPathComponent("taxes")
        try FileManager.default.createDirectory(at: taxes, withIntermediateDirectories: true)
        _ = try PDFFormFixture.write(to: taxes.appendingPathComponent("return.pdf"))

        let result = try await search(root, ["pattern": "70,820"])
        #expect(ToolEnvelope.isSuccess(result), "search failed: \(result)")
        let text = EnvelopeAssertions.successText(result) ?? ""
        let hits = text.components(separatedBy: "\n").filter { $0.contains("70,820") }
        #expect(hits.count == 1, Comment(rawValue: text))
        let hit = try #require(hits.first)
        #expect(hit.contains("taxes/return.pdf [page 1]"), Comment(rawValue: text))
        #expect(hit.contains("8 Other income   70,820"), Comment(rawValue: text))

        // Header cells too: the SSN lands beside the name on its visual row,
        // and the page marker is a `file_read` affordance, not searchable text.
        let ssn = EnvelopeAssertions.successText(try await search(root, ["pattern": "XXX-XX-7356"])) ?? ""
        #expect(ssn.contains("Claire A.   Reyes   XXX-XX-7356"), Comment(rawValue: ssn))
        let marker = EnvelopeAssertions.successText(try await search(root, ["pattern": "--- Page 1"])) ?? ""
        #expect(marker.contains("No matches found"), Comment(rawValue: marker))
    }

    @Test func modifiedDocumentInvalidatesCacheEntry() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        await DocumentTextExtractionCache.shared.removeAll()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await write(root, ["path": "memo.docx", "content": "First draft mentions apples.\n"])
        let first = try await search(root, ["pattern": "apples"])
        #expect((EnvelopeAssertions.successText(first) ?? "").contains("memo.docx [paragraph 1]"))

        // Overwrite with different content and a later mtime.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await write(root, ["path": "memo.docx", "content": "Second draft mentions pears.\n"])
        let stale = try await search(root, ["pattern": "apples"])
        #expect((EnvelopeAssertions.successText(stale) ?? "").contains("No matches found"))
        let fresh = try await search(root, ["pattern": "pears"])
        #expect((EnvelopeAssertions.successText(fresh) ?? "").contains("memo.docx [paragraph 1]"))
    }

    @Test func unextractableDocumentIsNamedInSkippedNote() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Garbage bytes with a .pdf name: extraction fails, must be counted
        // as a skipped DOCUMENT (with the extension and a file_read pointer),
        // not lumped in with binaries.
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("broken.pdf"))
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("photo.png"))

        let result = try await search(root, ["pattern": "anything"])
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("2 file(s) skipped"))
        #expect(text.contains("1 document(s) (.pdf)"))
        #expect(text.contains("`file_read`"))
        #expect(text.contains("1 media/archive/executable file(s)"))
    }

    @Test func legacyFormatsWithoutAdapterStaySkipped() {
        // `.xls` / `.key` have no extractor: they must be pre-skipped, not
        // routed into extraction.
        #expect(FolderToolHelpers.contentSearchSkippedExtensions.contains("xls"))
        #expect(FolderToolHelpers.contentSearchSkippedExtensions.contains("key"))
        #expect(!FolderToolHelpers.contentSearchSkippedExtensions.contains("pdf"))
        #expect(!FolderToolHelpers.contentSearchSkippedExtensions.contains("docx"))
        #expect(!FolderToolHelpers.contentSearchSkippedExtensions.contains("xlsx"))
        #expect(!FolderToolHelpers.contentSearchSkippedExtensions.contains("pptx"))
        #expect(DocumentTextExtractionCache.isSearchableDocument(extension: "pptx"))
        #expect(!DocumentTextExtractionCache.isSearchableDocument(extension: "xls"))
    }

    @Test func skippedNoteFormatsEveryKind() {
        var tally = FileSearchTool.ContentSearchSkipTally()
        tally.record(.binaryExtension)
        tally.record(.tooLarge)
        tally.record(.undecodable)
        tally.record(.document(extension: "pptx"))
        tally.record(.document(extension: "pdf"))
        let note = FileSearchTool.skippedFilesNote(tally) ?? ""
        #expect(note.hasPrefix("5 file(s) skipped: "))
        #expect(note.contains("1 media/archive/executable file(s)"))
        #expect(note.contains("1 text file(s) over 2MB"))
        #expect(note.contains("1 non-UTF-8 file(s)"))
        #expect(note.contains("2 document(s) (.pdf/.pptx)"))
        #expect(FileSearchTool.skippedFilesNote(FileSearchTool.ContentSearchSkipTally()) == nil)
    }
}
