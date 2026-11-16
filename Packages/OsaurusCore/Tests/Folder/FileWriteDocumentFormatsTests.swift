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

    /// Record rows (`{"Item": "Rent", "Amount": 1200}`) describe the same
    /// sheet as positional rows; a header spelled as a record is not written
    /// twice. Accepted inside `sheets[].rows` and top-level `rows` alike.
    @Test func xlsxFromJSONRecordRowsBuildsHeaderFromKeys() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let content = """
            {"sheets": [{"name": "Budget", "rows": [{"Item": "Item", "Amount": "Amount"}, {"Item": "Rent", "Amount": 1200}, {"Item": "Groceries", "Amount": 450}]}]}
            """
        let result = try await write(root, ["path": "budget.xlsx", "content": content])
        #expect(ToolEnvelope.isSuccess(result), "record rows xlsx write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["rows"] as? Int == 3, "\(payload)")

        let readBack = try await read(root, "budget.xlsx")
        let text = EnvelopeAssertions.successText(readBack) ?? ""
        #expect(text.contains("Rent") && text.contains("1200") && text.contains("Groceries"), "\(text)")
        #expect(text.components(separatedBy: "Amount").count == 2, "header written once: \(text)")

        let rows = FileWriteDocumentRouting.rowsFromJSON([["b": 2, "a": 1], ["a": 3]])
        #expect(rows?.count == 3)
        #expect(rows?[0] as? [String] == ["a", "b"])
        #expect(rows?[2].map { "\($0)" } == ["3", ""])
    }

    /// A draft written with typographic bullets (what `file_read` renders
    /// for list paragraphs) must produce list paragraphs, not one soft-wrapped
    /// paragraph per section.
    /// One package part as text (`unzip -p`).
    private func packagePart(_ url: URL, _ part: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, part]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Cells written as `=…` are formulas, not text: `<f>` elements, no shared string, and the workbook asks the
    /// spreadsheet app to calculate on open. `'=…` stays literal text. (Before: every cell was a string, so a
    /// model's `=SUM(B2:B3)` opened as the text "=SUM(B2:B3)".)
    @Test func xlsxFormulaCellsAreWrittenAsFormulas() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = #"""
            {"sheets": [{"name": "Budget", "rows": [
              ["Item", "Amount", "Note"],
              ["Rent", 1200, "'=not a formula"],
              ["Food", 450, ""],
              ["Total", "=SUM(B2:B3)", "=B4*1.1"]
            ]}]}
            """#
        let result = try await write(root, ["path": "budget.xlsx", "content": content])
        #expect(ToolEnvelope.isSuccess(result), "formula xlsx write failed: \(result)")
        let url = root.appendingPathComponent("budget.xlsx")
        let sheet = try packagePart(url, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<c r=\"B4\"><f>SUM(B2:B3)</f></c>"), Comment(rawValue: sheet))
        #expect(sheet.contains("<c r=\"C4\"><f>B4*1.1</f></c>"), Comment(rawValue: sheet))
        let workbook = try packagePart(url, "xl/workbook.xml")
        #expect(workbook.contains("fullCalcOnLoad=\"1\""), Comment(rawValue: workbook))
        let strings = try packagePart(url, "xl/sharedStrings.xml")
        #expect(strings.contains("<t>=not a formula</t>") || strings.contains(">=not a formula<"), Comment(rawValue: strings))
        #expect(!strings.contains("SUM(B2:B3)"), "the formula must not also be stored as text")

        let readBack = try await read(root, "budget.xlsx")
        #expect(ToolEnvelope.isSuccess(readBack))
        #expect(readBack.contains("SUM(B2:B3)"), Comment(rawValue: readBack))

        // CSV rows take formulas too (quoted when they contain the delimiter).
        let csv = try await write(root, ["path": "t.xlsx", "content": "a,b,sum\n1,2,\"=SUM(A2,B2)\"\n"])
        #expect(ToolEnvelope.isSuccess(csv), "csv formula write failed: \(csv)")
        let csvSheet = try packagePart(root.appendingPathComponent("t.xlsx"), "xl/worksheets/sheet1.xml")
        #expect(csvSheet.contains("<f>SUM(A2,B2)</f>"), Comment(rawValue: csvSheet))
    }

    /// `db_export` builds through the same row builder but must never turn stored text into a formula.
    @Test func databaseRowsKeepFormulaLikeTextLiteral() throws {
        let workbook = try FileWriteDocumentRouting.workbook(sheets: [("S", [["=1+1", "x"]])])
        let cell = try #require(workbook.sheets.first?.rows.first?.cells.first)
        #expect(cell.formula == nil)
        #expect(cell.value == .string("=1+1"))
    }

    /// Replacing an existing workbook that has layout/formatting is refused (bytes untouched) and points at
    /// file_edit, which keeps it; a plain generated workbook can still be regenerated.
    @Test func overwritingAFormattedWorkbookIsRefusedAndFileEditKeepsIt() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await write(root, ["path": "plain.xlsx", "content": "Item,Amount\nRent,1200\n"])
        #expect(ToolEnvelope.isSuccess(first))
        let again = try await write(root, ["path": "plain.xlsx", "content": "Item,Amount\nRent,1300\n"])
        #expect(ToolEnvelope.isSuccess(again), "a plain generated workbook regenerates: \(again)")

        // Give a copy column widths and a frozen header row (what spreadsheet apps add).
        let plain = try Data(contentsOf: root.appendingPathComponent("plain.xlsx"))
        let package = try OOXMLPackage(data: plain)
        let sheet = String(decoding: try package.data("xl/worksheets/sheet1.xml"), as: UTF8.self)
        let styled = sheet.replacingOccurrences(
            of: "<sheetData",
            with: #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="22" customWidth="1"/></cols><sheetData"#)
        #expect(styled != sheet)
        package.setData("xl/worksheets/sheet1.xml", Data(styled.utf8))
        let formatted = try package.serialize()
        try formatted.write(to: root.appendingPathComponent("ops.xlsx"))
        #expect(XLSXPreservation.featuresLostByRegeneration(formatted) == ["column widths", "freeze panes"])
        #expect(XLSXPreservation.featuresLostByRegeneration(plain).isEmpty)

        let refused = try await write(root, ["path": "ops.xlsx", "content": "Item,Amount\nRent,1500\n"])
        #expect(!ToolEnvelope.isSuccess(refused))
        let message = EnvelopeAssertions.failureMessage(refused) ?? ""
        #expect(message.contains("column widths") && message.contains("file_edit"), Comment(rawValue: message))
        #expect(try Data(contentsOf: root.appendingPathComponent("ops.xlsx")) == formatted, "file untouched")
        // The model must get to act on the refusal in the same turn: the chat loop stops on `rejected`.
        #expect(EnvelopeAssertions.failureKind(refused) == "invalid_args")
        let outcome = AgentLoopToolOutcome(
            invocation: ServiceToolInvocation(toolName: "file_write", jsonArguments: "{}", toolCallId: "w1"),
            callId: "w1", result: refused, wasDeduped: false, wasError: true)
        #expect(!AgentToolLoop.shouldStopAfterToolOutcome(outcome), "refusal must not end the turn")

        let edited = try await FileEditTool(rootPath: root).execute(argumentsJSON:
            #"{"path":"ops.xlsx","operations":[{"op":"set_cells","cells":{"B2":1500,"C2":"=B2*2"}}]}"#)
        #expect(ToolEnvelope.isSuccess(edited), "file_edit failed: \(edited)")
        let after = try Data(contentsOf: root.appendingPathComponent("ops.xlsx"))
        #expect(XLSXPreservation.featuresLostByRegeneration(after) == ["column widths", "freeze panes"], "file_edit kept the layout")
        let afterSheet = try packagePart(root.appendingPathComponent("ops.xlsx"), "xl/worksheets/sheet1.xml")
        #expect(afterSheet.contains("<f>B2*2</f>"), Comment(rawValue: afterSheet))
    }

    /// The osaurus.xlsx plugin's save_xlsx with overwrite over an existing formatted workbook is refused
    /// before the plugin runs (it writes a minimal package); everything else passes through untouched.
    @Test func pluginSaveOverAFormattedWorkbookIsRefused() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ToolEnvelope.isSuccess(try await write(root, ["path": "plain.xlsx", "content": "Item,Amount\nRent,1200\n"])))
        let plain = try Data(contentsOf: root.appendingPathComponent("plain.xlsx"))
        let package = try OOXMLPackage(data: plain)
        let sheet = String(decoding: try package.data("xl/worksheets/sheet1.xml"), as: UTF8.self)
        package.setData("xl/worksheets/sheet1.xml", Data(sheet.replacingOccurrences(
            of: "<sheetData", with: #"<cols><col min="1" max="1" width="22" customWidth="1"/></cols><sheetData"#).utf8))
        try package.serialize().write(to: root.appendingPathComponent("ops.xlsx"))

        func refusal(_ args: String, plugin: String = "osaurus.xlsx", tool: String = "save_xlsx", folder: URL? = nil) -> String? {
            XLSXPreservation.pluginOverwriteRefusal(pluginId: plugin, toolName: tool, argumentsJSON: args, folderRoot: folder ?? root)
        }
        let refused = try #require(refusal(#"{"workbook_id":"w1","path":"ops.xlsx","overwrite":true}"#))
        #expect(EnvelopeAssertions.failureKind(refused) == "invalid_args")
        #expect((EnvelopeAssertions.failureMessage(refused) ?? "").contains("file_edit"))
        // The extension is optional (save_xlsx adds it) and absolute paths resolve as-is.
        #expect(refusal(#"{"workbook_id":"w1","path":"ops","overwrite":true}"#) != nil)
        #expect(refusal(#"{"workbook_id":"w1","path":"\#(root.appendingPathComponent("ops.xlsx").path)","overwrite":true}"#, folder: URL(fileURLWithPath: "/nonexistent")) != nil)
        // Passes through: no overwrite, dry run, a plain workbook, a new path, another tool or plugin.
        #expect(refusal(#"{"workbook_id":"w1","path":"ops.xlsx"}"#) == nil)
        #expect(refusal(#"{"workbook_id":"w1","path":"ops.xlsx","overwrite":true,"dry_run":true}"#) == nil)
        #expect(refusal(#"{"workbook_id":"w1","path":"plain.xlsx","overwrite":true}"#) == nil)
        #expect(refusal(#"{"workbook_id":"w1","path":"new.xlsx","overwrite":true}"#) == nil)
        #expect(refusal(#"{"path":"ops.xlsx","overwrite":true}"#, tool: "read_xlsx") == nil)
        #expect(refusal(#"{"workbook_id":"w1","path":"ops.xlsx","overwrite":true}"#, plugin: "someone.else") == nil)
        // A relative path with no folder cannot be resolved: the plugin runs exactly as before.
        #expect(XLSXPreservation.pluginOverwriteRefusal(
            pluginId: "osaurus.xlsx", toolName: "save_xlsx",
            argumentsJSON: #"{"workbook_id":"w1","path":"ops.xlsx","overwrite":true}"#, folderRoot: nil) == nil)
    }

    @Test func namespacedWorkbookFormattingIsPreservedOnOverwrite() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ToolEnvelope.isSuccess(try await write(root, ["path": "prefixed.xlsx", "content": "Item,Amount\nRent,1200\n"])))
        let url = root.appendingPathComponent("prefixed.xlsx")
        let package = try OOXMLPackage(data: Data(contentsOf: url))
        let sheet = String(decoding: try package.data("xl/worksheets/sheet1.xml"), as: UTF8.self)
        let formatted = sheet.replacingOccurrences(
            of: "<sheetData", with: #"<cols><col min="1" max="1" width="22" customWidth="1"/></cols><sheetData"#)
        let prefixed = formatted.replacingOccurrences(
            of: #"<(\/?)([A-Za-z][\w.-]*)"#, with: "<$1s:$2", options: .regularExpression
        ).replacingOccurrences(of: "xmlns=", with: "xmlns:s=")
        package.setData("xl/worksheets/sheet1.xml", Data(prefixed.utf8))
        let before = try package.serialize()
        try before.write(to: url)
        #expect(XLSXPreservation.featuresLostByRegeneration(before).contains("column widths"))
        let result = try await write(root, ["path": "prefixed.xlsx", "content": "Item,Amount\nRent,1500\n"])
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func docxBulletGlyphLinesBecomeListParagraphs() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let content = "Atlas Brief\n\nGoal\n• Migrate the platform\n•\tKeep data intact\n\nRisks\n• Vendor delays\n\n```\n• not a bullet\n```"
        let result = try await write(root, ["path": "brief.docx", "content": content])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let editor = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: root.appendingPathComponent("brief.docx"))))
        let texts = try editor.paragraphs().map { OOXMLText.text(of: $0) }
        // The OOXML writer renders each list item as its own paragraph
        // (bullet + tab, the same shape `file_read` reports back).
        #expect(texts.contains("Goal") && texts.contains("•\tMigrate the platform") && texts.contains("•\tKeep data intact"), "\(texts)")
        #expect(texts.contains("Risks") && texts.contains("•\tVendor delays"), "\(texts)")
        #expect(!texts.contains { $0.contains("Goal •") || $0.contains("• Migrate") }, "\(texts)")
        #expect(texts.contains { $0.contains("• not a bullet") }, "fenced code keeps its glyph: \(texts)")

        #expect(
            MarkdownRichTextRenderer.normalizingBulletGlyphs("a\n• b\n\t◦ c\nplain • inline") == "a\n- b\n  - c\nplain • inline")
        #expect(MarkdownRichTextRenderer.normalizingBulletGlyphs("no glyphs") == "no glyphs")
    }

    /// A `file_edit` operations array typed into `file_write` on a document
    /// path is refused (it would replace the document with JSON text) and
    /// the rejection carries the exact `file_edit` call to make instead.
    @Test func operationsArrayInContentIsRedirectedToFileEdit() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intake.pdf")
        try Data("%PDF-1.4 placeholder".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let content = #"[{"op": "fill_form", "fields": {"Name": "Ada Lovelace", "Agree": true}}]"#
        let result = try await write(root, ["path": "intake.pdf", "content": content, "mode": "overwrite"])
        #expect(ToolEnvelope.isError(result), "\(result)")
        #expect(EnvelopeAssertions.failureField(result) == "content")
        let message = EnvelopeAssertions.failureMessage(result) ?? ""
        #expect(message.contains("file_edit") && message.contains("fill_form"), "\(message)")
        #expect(try Data(contentsOf: url) == before, "document bytes must be untouched")

        // Wrapped form is recognized too; a bare array of rows for .xlsx is not an operations payload.
        #expect(FileWriteTool.fileEditOperationsPayload(#"{"operations": [{"op": "set_cells", "cells": {"B2": 1}}]}"#)?.count == 1)
        #expect(FileWriteTool.fileEditOperationsPayload(#"[["Item", "Amount"], ["Rent", 1200]]"#) == nil)
        #expect(FileWriteTool.fileEditOperationsPayload(#"[{"op": "not_a_real_op"}]"#) == nil)
        #expect(FileWriteTool.fileEditOperationsPayload("# Heading\n\n- item") == nil)
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
        let message = EnvelopeAssertions.failureMessage(result) ?? ""
        #expect(message.contains("file_read"))
        // The refusal must name the way out for a large document: whole
        // content of any length, or render from an assembled text file.
        #expect(message.contains("source_path"))
    }

    // MARK: - Large documents

    /// Markdown well above the old 30,000-character cap: ~110 numbered
    /// sections so the body is prose, not one long token. The exact size
    /// a user hit ("got 34172") sits inside this range.
    private func largeMarkdown(minimumCharacters: Int) -> String {
        var text = "# Field Report\n\nThis report was assembled from an 80 KB source file.\n\n"
        var section = 1
        while text.count < minimumCharacters {
            text += "## Section \(section)\n\n"
            text += "Finding \(section): the measured value stayed within tolerance across every run, "
            text += "and the follow-up actions are listed below for the owning team to confirm.\n\n"
            text += "- Action item \(section).1 — verify the baseline\n"
            text += "- Action item \(section).2 — record the receipt\n\n"
            section += 1
        }
        return text
    }

    @Test func docxLargerThanThirtyThousandCharactersIsGenerated() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = largeMarkdown(minimumCharacters: 34_172)
        #expect(markdown.count > 30_000)
        let result = try await write(root, ["path": "report.docx", "content": markdown])
        #expect(ToolEnvelope.isSuccess(result), "large docx write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["format"] as? String == "docx")
        #expect(payload["characters"] as? Int == markdown.count)

        let bytes = try Data(contentsOf: root.appendingPathComponent("report.docx"))
        #expect(bytes.prefix(2) == Data([0x50, 0x4B]), "docx is not a ZIP package")

        let readBack = try await read(root, "report.docx", extra: ["max_chars": 60_000])
        #expect(ToolEnvelope.isSuccess(readBack), "large docx read-back failed: \(readBack)")
        let text = (EnvelopeAssertions.successPayload(readBack)?["text"] as? String) ?? ""
        #expect(text.contains("Field Report"))
        #expect(text.contains("Finding 1:"))
        #expect(text.contains("Action item 100.2"), "late sections missing from the rendered document")
    }

    @Test func pdfLargerThanThirtyThousandCharactersIsGenerated() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = largeMarkdown(minimumCharacters: 34_172)
        let result = try await write(root, ["path": "report.pdf", "content": markdown])
        #expect(ToolEnvelope.isSuccess(result), "large pdf write failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["format"] as? String == "pdf")
        #expect((payload["pages"] as? Int ?? 0) > 1, "a 34K-character PDF should span several pages")

        let bytes = try Data(contentsOf: root.appendingPathComponent("report.pdf"))
        #expect(bytes.prefix(4) == Data("%PDF".utf8), "pdf header missing")

        let readBack = try await read(root, "report.pdf", extra: ["max_chars": 60_000])
        #expect(ToolEnvelope.isSuccess(readBack), "large pdf read-back failed: \(readBack)")
        let text = (EnvelopeAssertions.successPayload(readBack)?["text"] as? String) ?? ""
        #expect(text.contains("Field Report"))
        #expect(text.contains("Finding 1"))
    }

    // MARK: - source_path

    /// The user-report shape: Markdown assembled with overwrite + append
    /// calls, then rendered to .docx from that file instead of being
    /// re-sent as `content`.
    @Test func docxFromSourcePathRendersAnAppendedMarkdownFile() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = largeMarkdown(minimumCharacters: 34_172)
        let midpoint = markdown.index(markdown.startIndex, offsetBy: markdown.count / 2)
        let first = String(markdown[..<midpoint])
        let second = String(markdown[midpoint...])
        let part1 = try await write(root, ["path": "report.md", "content": first])
        #expect(ToolEnvelope.isSuccess(part1), "\(part1)")
        let part2 = try await write(root, ["path": "report.md", "content": second, "mode": "append"])
        #expect(ToolEnvelope.isSuccess(part2), "\(part2)")
        #expect((try String(contentsOf: root.appendingPathComponent("report.md"), encoding: .utf8)) == markdown)

        let preview = try await write(root, ["path": "report.docx", "source_path": "report.md", "dry_run": true])
        #expect(ToolEnvelope.isSuccess(preview), "\(preview)")
        #expect(EnvelopeAssertions.successPayload(preview)?["characters"] as? Int == markdown.count)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.docx").path))

        let result = try await write(root, ["path": "report.docx", "source_path": "report.md"])
        #expect(ToolEnvelope.isSuccess(result), "docx from source_path failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "document_write_result")
        #expect(payload["format"] as? String == "docx")
        #expect(payload["input"] as? String == "markdown")
        #expect(payload["characters"] as? Int == markdown.count)

        let readBack = try await read(root, "report.docx", extra: ["max_chars": 60_000])
        #expect(ToolEnvelope.isSuccess(readBack), "docx read-back failed: \(readBack)")
        let text = (EnvelopeAssertions.successPayload(readBack)?["text"] as? String) ?? ""
        #expect(text.contains("Field Report"))
        #expect(text.contains("Action item 100.2"))
        // The source Markdown is untouched.
        #expect((try String(contentsOf: root.appendingPathComponent("report.md"), encoding: .utf8)) == markdown)
    }

    @Test func pdfFromSourcePathRendersWorkspaceMarkdown() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Launch Plan\n\nShip the beta on Friday.\n".write(
            to: root.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)

        let result = try await write(root, ["path": "out/plan.pdf", "source_path": "plan.md"])
        #expect(ToolEnvelope.isSuccess(result), "pdf from source_path failed: \(result)")
        let bytes = try Data(contentsOf: root.appendingPathComponent("out/plan.pdf"))
        #expect(bytes.prefix(4) == Data("%PDF".utf8))
        let readBack = try await read(root, "out/plan.pdf")
        let text = (EnvelopeAssertions.successPayload(readBack)?["text"] as? String) ?? ""
        #expect(text.contains("Launch Plan"))
    }

    // MARK: - source_path confinement (same gates as file_read)

    private func failureIsNonRetryableSourcePathRejection(_ result: String) -> Bool {
        guard ToolEnvelope.isError(result),
            let data = result.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return dict["field"] as? String == "source_path" && dict["retryable"] as? Bool == false
    }

    /// `source_path` is a read, so it is confined exactly like `file_read`'s
    /// `path` (`FolderToolHelpers.resolvePath`): an absolute path outside the
    /// working folder, a `..` escape, and an in-folder symlink whose target
    /// is outside are all rejected before any byte is read, and nothing is
    /// written. A symlink that stays inside the folder is an ordinary file.
    @Test func sourcePathIsConfinedToTheWorkingFolder() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = tmpRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("id_rsa.md")
        try "PRIVATE KEY MATERIAL".write(to: secret, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("leak.docx")

        // 1. Absolute path outside the folder.
        let absolute = try await write(root, ["path": "leak.docx", "source_path": secret.path])
        #expect(failureIsNonRetryableSourcePathRejection(absolute), "absolute escape accepted: \(absolute)")
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        // 2. `..` traversal to the same file.
        let traversal = try await write(
            root,
            ["path": "leak.docx", "source_path": "../\(outside.lastPathComponent)/id_rsa.md"]
        )
        #expect(failureIsNonRetryableSourcePathRejection(traversal), "traversal accepted: \(traversal)")
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        // 3. A benign-looking symlink INSIDE the folder pointing OUTSIDE it.
        let escapingLink = root.appendingPathComponent("notes.md")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: secret)
        let viaLink = try await write(root, ["path": "leak.docx", "source_path": "notes.md"])
        #expect(failureIsNonRetryableSourcePathRejection(viaLink), "escaping symlink accepted: \(viaLink)")
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        // 4. A symlink inside the folder pointing at a file inside it is fine.
        let real = root.appendingPathComponent("docs/real.md")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Inside\n\nStays inside the folder.\n".write(to: real, atomically: true, encoding: .utf8)
        let innerLink = root.appendingPathComponent("inside.md")
        try FileManager.default.createSymbolicLink(at: innerLink, withDestinationURL: real)
        let ok = try await write(root, ["path": "inside.docx", "source_path": "inside.md"])
        #expect(ToolEnvelope.isSuccess(ok), "in-folder symlink refused: \(ok)")
        let readBack = try await read(root, "inside.docx")
        let text = (EnvelopeAssertions.successPayload(readBack)?["text"] as? String) ?? ""
        #expect(text.contains("Stays inside the folder"))

        // 5. The output path itself is still confined (unchanged behaviour:
        //    the resolver throws and the registry boundary turns that into
        //    the standard envelope).
        await #expect(throws: FolderToolError.self) {
            _ = try await write(root, ["path": "../escape.docx", "source_path": "inside.md"])
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.docx").path))
    }

    /// In combined read-only host mode `file_read` refuses secret files;
    /// `source_path` goes through the same `shouldRefuseSecret` gate and the
    /// same `rejected` envelope, so a document cannot be used to pull `.env`
    /// into the workspace output.
    @Test func sourcePathRefusesSecretFilesLikeFileRead() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "API_KEY=sk-live-123\n".write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (writeResult, readResult) = try await ChatExecutionContext.$hostReadOnlyScope.withValue(root) {
            let w = try await write(root, ["path": "config.docx", "source_path": ".env"])
            let r = try await read(root, ".env")
            return (w, r)
        }
        #expect(ToolEnvelope.isError(writeResult), "\(writeResult)")
        #expect(EnvelopeAssertions.failureKind(writeResult) == "rejected")
        #expect(EnvelopeAssertions.failureKind(readResult) == "rejected", "file_read should refuse the same file")
        let data = try #require(writeResult.data(using: .utf8))
        let dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["retryable"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.docx").path))
    }

    /// A generated document is bytes, not text: pointing `source_path` at
    /// one is refused with the text-file pivot instead of rendering ZIP
    /// bytes as Markdown.
    @Test func sourcePathMustBeATextFile() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try await write(root, ["path": "a.docx", "content": "# A"])
        #expect(ToolEnvelope.isSuccess(seed), "\(seed)")

        let result = try await write(root, ["path": "b.pdf", "source_path": "a.docx"])
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureField(result) == "source_path")
        #expect((EnvelopeAssertions.failureMessage(result) ?? "").contains("file_read"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.pdf").path))
    }

    @Test func overwritingBinaryDocumentIsUndoableByteForByte() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("report.docx")
        // Arbitrary non-UTF-8 bytes standing in for a previous package.
        let original = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00, 0x01, 0x80])
        try original.write(to: target)
        let sessionId = "file-write-formats-\(UUID().uuidString)"

        let result = try await env.run(
            FileWriteTool(rootPath: root),
            FileHistoryTestEnv.json(["path": "report.docx", "content": "# Replaced\n\nBody."]),
            sessionId: sessionId, folder: root)
        #expect(ToolEnvelope.isSuccess(result), "overwrite failed: \(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["action"] as? String == "overwrite")
        let operationId = try #require(UUID(uuidString: payload["operation_id"] as? String ?? ""))
        #expect(try Data(contentsOf: target) != original)

        let set = try #require(await env.journal.changeSet(id: operationId, sessionId: sessionId))
        #expect(set.entries.map(\.path) == ["report.docx"])
        #expect(set.entries.first?.kind == .modified)

        let summary = await env.journal.revert(.set(operationId), sessionId: sessionId)
        #expect(summary.isClean, "\(summary)")
        #expect(try Data(contentsOf: target) == original, "undo did not restore the original bytes")
    }

    @Test func pptxIsGeneratedFromMarkdownSlides() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = "# Q3 Review\nPrepared by Ops\n\n## Revenue\n- Up 12%\n- Margin flat\n\n## Next steps\n- Hire\n"
        let result = try await write(root, ["path": "deck.pptx", "content": markdown])
        #expect(!ToolEnvelope.isError(result), "\(result)")
        let url = root.appendingPathComponent("deck.pptx")
        let document = try await PPTXAdapter().parse(url: url, sizeLimit: 50_000_000)
        let text = document.textFallback
        for expected in ["Q3 Review", "Revenue", "Up 12%", "Next steps", "Hire"] {
            #expect(text.contains(expected), "missing \(expected) in \(text)")
        }
    }

    @Test func presentationFormatsAreRefusedWithHonestPivot() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["deck.key", "deck.odp", "deck.pptm"] {
            let result = try await write(root, ["path": name, "content": "# Slide 1"])
            #expect(ToolEnvelope.isError(result))
            let message = EnvelopeAssertions.failureMessage(result) ?? ""
            #expect(!message.contains("only writes UTF-8 text"), "stale text-only claim: \(message)")
            #expect(message.contains(".pptx"), "pivot must name the supported format: \(message)")
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
