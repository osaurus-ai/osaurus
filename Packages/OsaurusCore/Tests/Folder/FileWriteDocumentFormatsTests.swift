//
//  FileWriteDocumentFormatsTests.swift
//
//  `file_write` generates real documents by extension: `.xlsx` from
//  CSV/TSV text or JSON rows, `.docx` / `.pdf` from Markdown or HTML.
//  Every generated file must read back through `file_read` (the same
//  adapters the model uses to verify its own output), `dry_run` must
//  not touch disk, `append` is refused for documents, overwriting a
//  binary package stays undoable byte-for-byte, and unsupported
//  presentation formats are refused with an honest pivot.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileWriteDocumentFormatsTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-write-formats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withSession<T>(
        _ sessionId: String = "file-write-formats-\(UUID().uuidString)",
        body: (String) async throws -> T
    ) async throws -> T {
        try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await body(sessionId)
        }
    }

    private func write(_ root: URL, _ args: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = try #require(String(data: data, encoding: .utf8))
        return try await FileWriteTool(rootPath: root).execute(argumentsJSON: json)
    }

    private func read(_ root: URL, _ path: String, extra: [String: Any] = [:]) async throws -> String {
        var args: [String: Any] = ["path": path]
        for (key, value) in extra { args[key] = value }
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = try #require(String(data: data, encoding: .utf8))
        return try await FileReadTool(rootPath: root).execute(argumentsJSON: json)
    }

    // MARK: - XLSX

    @Test func xlsxFromCSVRoundTripsThroughFileRead() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await write(
            root,
            ["path": "budget.xlsx", "content": "Region,Revenue\nWest,1200\nEast,\"00450\"\n"]
        )
        #expect(ToolEnvelope.isSuccess(result), "xlsx write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "document_write_result")
        #expect(payload["format"] as? String == "xlsx")
        #expect(payload["sheets"] as? Int == 1)
        #expect(payload["rows"] as? Int == 3)
        #expect((payload["bytes_written"] as? Int ?? 0) > 0)
        #expect(payload["share_hint"] != nil)
        #expect(payload["diff"] == nil)

        // ZIP magic — a real package, not CSV text with an .xlsx name.
        let bytes = try Data(contentsOf: root.appendingPathComponent("budget.xlsx"))
        #expect(bytes.prefix(2) == Data([0x50, 0x4B]))

        let readBack = try await read(root, "budget.xlsx")
        #expect(ToolEnvelope.isSuccess(readBack), "xlsx read-back failed: \(readBack)")
        let readPayload = try #require(EnvelopeAssertions.successPayload(readBack))
        #expect(readPayload["kind"] as? String == "workbook")
        #expect(readPayload["format"] as? String == "xlsx")
        #expect(readPayload["source"] as? String == "workbook_preview")
        let text = readPayload["text"] as? String ?? ""
        #expect(text.contains("West"))
        #expect(text.contains("1200"))
        // Quoted field kept as text (leading zero survives).
        #expect(text.contains("00450"), "quoted numeric string lost its leading zero: \(text)")
    }

    @Test func xlsxFromJSONSheetsBuildsMultipleSheets() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let content = """
            {"sheets":[{"name":"Q1","rows":[["Item","Qty"],["Widgets",4]]},{"name":"Q2","rows":[["Item","Qty"],["Gadgets",7]]}]}
            """
        let result = try await write(root, ["path": "plan.xlsx", "content": content])
        #expect(ToolEnvelope.isSuccess(result), "json xlsx write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["sheets"] as? Int == 2)
        #expect(payload["input"] as? String == "json")

        let readBack = try await read(root, "plan.xlsx", extra: ["sheet_name": "Q2"])
        let text = EnvelopeAssertions.successText(readBack) ?? ""
        #expect(text.contains("Gadgets"), "sheet Q2 not readable: \(text)")
        let readPayload = EnvelopeAssertions.successPayload(readBack)
        #expect((readPayload?["sheet_names"] as? [String]) == ["Q1", "Q2"])
    }

    @Test func xlsxInvalidJSONIsAnArgumentError() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await write(root, ["path": "bad.xlsx", "content": "{\"sheets\": \"nope\"}"])
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureField(result) == "content")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.xlsx").path))
    }

    // MARK: - DOCX / PDF

    @Test func docxFromMarkdownRoundTripsThroughFileRead() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = """
            # Quarterly Brief

            Revenue grew **12%** quarter over quarter.

            - Expand the West region
            - Hire two engineers

            ```swift
            let done = true
            ```
            """
        let result = try await write(root, ["path": "brief.docx", "content": markdown])
        #expect(ToolEnvelope.isSuccess(result), "docx write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "document_write_result")
        #expect(payload["format"] as? String == "docx")
        #expect(payload["input"] as? String == "markdown")

        let bytes = try Data(contentsOf: root.appendingPathComponent("brief.docx"))
        #expect(bytes.prefix(2) == Data([0x50, 0x4B]), "docx is not a ZIP package")

        let readBack = try await read(root, "brief.docx")
        #expect(ToolEnvelope.isSuccess(readBack), "docx read-back failed: \(readBack)")
        let readPayload = try #require(EnvelopeAssertions.successPayload(readBack))
        #expect(readPayload["format"] as? String == "docx")
        #expect(readPayload["source"] as? String == "extracted_text")
        let text = readPayload["text"] as? String ?? ""
        #expect(text.contains("Quarterly Brief"))
        #expect(text.contains("Expand the West region"))
        // Markdown syntax must be rendered, not written literally.
        #expect(!text.contains("# Quarterly"), "heading marker leaked into the document: \(text)")
        #expect(!text.contains("**12%**"), "emphasis marker leaked into the document: \(text)")
    }

    @Test func pdfFromMarkdownRoundTripsThroughFileRead() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await write(
            root,
            ["path": "one-pager.pdf", "content": "# Launch Plan\n\nShip the beta on Friday.\n"]
        )
        #expect(ToolEnvelope.isSuccess(result), "pdf write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["format"] as? String == "pdf")
        #expect(payload["pages"] as? Int == 1)

        let bytes = try Data(contentsOf: root.appendingPathComponent("one-pager.pdf"))
        #expect(bytes.prefix(4) == Data("%PDF".utf8), "pdf header missing")

        let readBack = try await read(root, "one-pager.pdf")
        #expect(ToolEnvelope.isSuccess(readBack), "pdf read-back failed: \(readBack)")
        let readPayload = try #require(EnvelopeAssertions.successPayload(readBack))
        #expect(readPayload["format"] as? String == "pdf")
        #expect(readPayload["pages"] as? Int == 1)
        let text = readPayload["text"] as? String ?? ""
        #expect(text.contains("Launch Plan"))
        #expect(text.contains("Ship the beta on Friday"))
    }

    @Test func htmlInputIsSniffedForDocx() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let html = "<html><body><h1>Memo</h1><p>All hands at <b>noon</b>.</p></body></html>"
        let result = try await write(root, ["path": "memo.docx", "content": html])
        #expect(ToolEnvelope.isSuccess(result), "html docx write failed: \(result)")
        #expect(EnvelopeAssertions.successPayload(result)?["input"] as? String == "html")
        let text = EnvelopeAssertions.successText(try await read(root, "memo.docx")) ?? ""
        #expect(text.contains("All hands at"))
        #expect(!text.contains("<p>"))
    }

    // MARK: - Semantics

    @Test func dryRunPreviewsWithoutWriting() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await write(
            root,
            ["path": "preview.xlsx", "content": "a,b\n1,2\n", "dry_run": true]
        )
        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "document_write_preview")
        #expect(payload["applied"] as? Bool == false)
        #expect(payload["sheets"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preview.xlsx").path))
    }

    @Test func appendIsRefusedForDocuments() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await write(
            root,
            ["path": "notes.docx", "content": "more", "mode": "append"]
        )
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureField(result) == "mode")
        #expect((EnvelopeAssertions.failureMessage(result) ?? "").contains("file_read"))
    }

    @Test func overwritingBinaryDocumentIsUndoableByteForByte() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        await FileOperationLog.shared.clearAll()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("report.docx")
        // Arbitrary non-UTF-8 bytes standing in for a previous package.
        let original = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00, 0x01, 0x80])
        try original.write(to: target)

        try await withSession { sessionId in
            let result = try await write(root, ["path": "report.docx", "content": "# Replaced\n\nBody."])
            #expect(ToolEnvelope.isSuccess(result), "overwrite failed: \(result)")
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["action"] as? String == "overwrite")
            let operationId = try #require(payload["operation_id"] as? String)
            let after = try Data(contentsOf: target)
            #expect(after != original)

            let history = await FileOperationLog.shared.operations(for: sessionId)
            let entry = try #require(history.first(where: { $0.id.uuidString == operationId }))
            #expect(entry.previousContentEncoding == .base64)
            #expect(entry.contentKind == "binary")

            _ = try await FileOperationLog.shared.undo(sessionId: sessionId, operationId: entry.id)
            let restored = try Data(contentsOf: target)
            #expect(restored == original, "undo did not restore the original bytes")
        }
    }

    @Test func presentationFormatsAreRefusedWithHonestPivot() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["deck.pptx", "deck.key", "deck.odp"] {
            let result = try await write(root, ["path": name, "content": "# Slide 1"])
            #expect(ToolEnvelope.isError(result))
            let message = EnvelopeAssertions.failureMessage(result) ?? ""
            #expect(!message.contains("only writes UTF-8 text"), "stale text-only claim: \(message)")
            #expect(message.contains(".docx"), "pivot must name a supported format: \(message)")
            #expect(message.contains("osaurus.pptx"), "pivot must mention the pptx plugin: \(message)")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    @Test func legacyOfficeFormatsPointAtGeneratedSiblings() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let xls = try await write(root, ["path": "old.xls", "content": "a,b"])
        #expect((EnvelopeAssertions.failureMessage(xls) ?? "").contains(".xlsx"))
        let doc = try await write(root, ["path": "old.doc", "content": "hello"])
        #expect((EnvelopeAssertions.failureMessage(doc) ?? "").contains(".docx"))
    }
}
