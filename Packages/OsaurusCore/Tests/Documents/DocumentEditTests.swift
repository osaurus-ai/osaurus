//
//  DocumentEditTests.swift
//
//  `file_edit` `operations` edit .docx/.xlsx/.pptx/.pdf in place. Every
//  edit must re-open through the same adapters `file_read` uses, leave
//  untouched package parts byte-identical, refuse bad operations without
//  touching the file, and stay undoable through the change journal.
//

import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DocumentEditTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-document-edit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func json(_ args: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func write(_ root: URL, _ path: String, _ content: String) async throws {
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: try json(["path": path, "content": content]))
        #expect(ToolEnvelope.isSuccess(result), "setup write failed: \(result)")
    }

    private func edit(_ root: URL, _ args: [String: Any]) async throws -> String {
        try await FileEditTool(rootPath: root).execute(argumentsJSON: try json(args))
    }

    private func text(of url: URL) async throws -> String {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let adapter = try #require(DocumentFormatRegistry.shared.adapter(for: url))
        return try await adapter.parse(url: url, sizeLimit: 50_000_000).textFallback
    }

    /// Raw (still-compressed) payload per zip entry, for byte-identity checks.
    private func rawEntries(_ data: Data) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for entry in try ZipArchive.entries(in: data) {
            out[entry.name] = try ZipArchive.rawPayload(entry, from: data)
        }
        return out
    }

    private func part(_ name: String, in url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let entry = try #require(try ZipArchive.entries(in: data).first { $0.name == name })
        return String(decoding: try ZipArchive.extract(entry, from: data, verifyChecksum: true), as: UTF8.self)
    }

    /// Elements that serialized outside any namespace — Office ignores or
    /// rejects them, so an editor must never produce one.
    private func elementsWithoutNamespace(_ name: String, in url: URL) throws -> [String] {
        let document = try XMLDocument(xmlString: try part(name, in: url))
        var out: [String] = []
        var stack: [XMLElement] = document.rootElement().map { [$0] } ?? []
        while let element = stack.popLast() {
            if (element.uri ?? "").isEmpty { out.append(element.name ?? "?") }
            stack.append(contentsOf: element.children?.compactMap { $0 as? XMLElement } ?? [])
        }
        return out
    }

    // MARK: - DOCX

    /// Hand-built package: a split-run paragraph, a real `w:tbl`, a style
    /// part, and a media blob that no edit should ever touch.
    private func makeDOCX(_ url: URL) throws {
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let cell = { (text: String) in "<w:tc><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:tc>" }
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(w)"><w:body>\
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Memo</w:t></w:r></w:p>\
            <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Hello world, this is </w:t></w:r><w:r><w:t>the draft.</w:t></w:r></w:p>\
            <w:tbl><w:tr>\(cell("Name"))\(cell("Score"))</w:tr><w:tr>\(cell("Ada"))\(cell("1"))</w:tr></w:tbl>\
            <w:sectPr/></w:body></w:document>
            """
        var zip = ZipArchiveWriter()
        try zip.add(
            path: "[Content_Types].xml",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Default Extension="png" ContentType="image/png"/>\
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
                <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
                </Types>
                """.utf8))
        try zip.add(
            path: "_rels/.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
                </Relationships>
                """.utf8))
        try zip.add(path: "word/document.xml", data: Data(document.utf8))
        try zip.add(
            path: "word/_rels/document.xml.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
                </Relationships>
                """.utf8))
        try zip.add(
            path: "word/styles.xml",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:styles xmlns:w="\(w)"><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style></w:styles>
                """.utf8))
        try zip.add(path: "word/media/image1.png", data: Data((0..<4096).map { UInt8($0 % 251) }))
        try zip.finalize().write(to: url)
    }

    @Test func docxOperationsEditInPlaceAndKeepOtherPartsByteIdentical() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memo.docx")
        try makeDOCX(url)
        let before = try rawEntries(try Data(contentsOf: url))

        let result = try await edit(
            root,
            [
                "path": "memo.docx",
                "operations": [
                    // Spans both runs of the paragraph.
                    ["op": "replace_text", "old_string": "is the draft", "new_string": "is final"],
                    ["op": "insert_paragraph", "text": "Signed, Ops.", "after": 2],
                    ["op": "set_table_cell", "table": 1, "row": 2, "column": 2, "text": "99"],
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["format"] as? String == "docx")
        #expect((payload["operations_applied"] as? [String])?.count == 3)
        #expect((payload["diff"] as? String)?.contains("final") == true)

        let text = try await text(of: url)
        #expect(text.contains("Hello world, this is final."))
        #expect(!text.contains("the draft"))
        #expect(text.contains("Signed, Ops."))
        #expect(text.contains("99"))
        #expect(try elementsWithoutNamespace("word/document.xml", in: url).isEmpty)
        let xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:b/></w:rPr><w:t xml:space=\"preserve\">Hello world, this is final</w:t>"), "\(xml)")

        let after = try rawEntries(try Data(contentsOf: url))
        #expect(Set(after.keys) == Set(before.keys))
        for (name, bytes) in before where name != "word/document.xml" {
            #expect(after[name] == bytes, "\(name) changed but was not edited")
        }
    }

    @Test func invalidOperationChangesNothing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "memo.docx", "# Memo\n\nBody text.\n")
        let url = root.appendingPathComponent("memo.docx")
        let original = try Data(contentsOf: url)

        let missing = try await edit(
            root,
            [
                "path": "memo.docx",
                "operations": [
                    ["op": "replace_text", "old_string": "Body", "new_string": "Main"],
                    ["op": "replace_text", "old_string": "not present", "new_string": "x"],
                ],
            ])
        #expect(EnvelopeAssertions.failureKind(missing) == "invalid_args")
        #expect(ToolEnvelope.failureMessage(missing).contains("Nothing was changed"))

        let unknown = try await edit(root, ["path": "memo.docx", "operations": [["op": "explode"]]])
        #expect(ToolEnvelope.isError(unknown))

        let inferred = try await edit(
            root,
            ["path": "memo.docx", "dry_run": true, "operations": [["old_string": "Body", "new_string": "Main"]]])
        #expect(ToolEnvelope.isSuccess(inferred), "\(inferred)")

        let unnamedDelete = try await edit(root, ["path": "memo.docx", "operations": [["index": 1]]])
        let guidance = EnvelopeAssertions.failureMessage(unnamedDelete) ?? ""
        #expect(guidance.contains("needs an `op` name"))
        #expect(guidance.contains("delete_paragraph"))

        let lastParagraph = try await edit(
            root, ["path": "memo.docx", "operations": [["op": "delete_paragraph", "indices": [1, 2]]]])
        #expect(ToolEnvelope.isError(lastParagraph))

        #expect(try Data(contentsOf: url) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "temp files left behind: \(leftovers)")
    }

    @Test func dryRunPreviewsWithoutWriting() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "memo.docx", "# Memo\n\nBody text.\n")
        let url = root.appendingPathComponent("memo.docx")
        let original = try Data(contentsOf: url)

        let result = try await edit(
            root, ["path": "memo.docx", "old_string": "Body text", "new_string": "New body", "dry_run": true])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["dry_run"] as? Bool == true)
        #expect((payload["diff"] as? String)?.contains("New body") == true)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func structureModeListsAddressableParts() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "memo.docx", "# Memo\n\nFirst.\n\nSecond.\n")
        let result = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: try json(["path": "memo.docx", "mode": "structure"]))
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let paragraphs = try #require(payload["paragraphs"] as? [[String: Any]])
        #expect(paragraphs.map { $0["text"] as? String } == ["Memo", "First.", "Second."])
        #expect(paragraphs.first?["index"] as? Int == 1)
        #expect((payload["operations"] as? [String])?.contains("insert_paragraph") == true)
    }

    @Test func documentEditIsJournaledAndUndoable() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "memo.docx", "# Memo\n\nBody text.\n")
        let url = root.appendingPathComponent("memo.docx")
        let original = try Data(contentsOf: url)
        let sessionId = "document-edit-\(UUID().uuidString)"

        let result = try await env.run(
            FileEditTool(rootPath: root),
            FileHistoryTestEnv.json([
                "path": "memo.docx", "operations": [["op": "replace_text", "old_string": "Body", "new_string": "Main"]],
            ]),
            sessionId: sessionId, folder: root)
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let operationId = try #require(UUID(uuidString: payload["operation_id"] as? String ?? ""))
        #expect(try Data(contentsOf: url) != original)

        let set = try #require(await env.journal.changeSet(id: operationId, sessionId: sessionId))
        #expect(set.entries.map(\.path) == ["memo.docx"])
        #expect(set.entries.first?.kind == .modified)

        let summary = await env.journal.revert(.set(operationId), sessionId: sessionId)
        #expect(summary.isClean, "\(summary)")
        #expect(try Data(contentsOf: url) == original)
    }

    // MARK: - XLSX

    @Test func xlsxCellsFormulasAndRowShifts() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "budget.xlsx", "Item,Qty\nApples,3\nPears,4\n")
        let url = root.appendingPathComponent("budget.xlsx")

        let result = try await edit(
            root,
            [
                "path": "budget.xlsx",
                "operations": [
                    ["op": "set_cells", "cells": ["A4": "Total", "B4": "=SUM(B2:B3)", "C1": true]],
                    ["op": "insert_rows", "at": 2, "count": 1],
                    ["cells": ["A2": "Plums", "B2": 5]],
                    ["op": "rename_sheet", "sheet": 1, "name": "Fruit Stock"],
                    ["op": "add_sheet", "name": "Summary"],
                    ["op": "set_cells", "sheet": "Summary", "cells": ["A1": "='Fruit Stock'!B5"]],
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")

        let sheet = try part("xl/worksheets/sheet1.xml", in: url)
        #expect(sheet.contains("<f>SUM(B3:B4)</f>"), "formula did not follow the inserted row: \(sheet)")
        #expect(try elementsWithoutNamespace("xl/workbook.xml", in: url).isEmpty)
        #expect(try elementsWithoutNamespace("xl/worksheets/sheet1.xml", in: url).isEmpty)
        let workbook = try part("xl/workbook.xml", in: url)
        #expect(workbook.contains("Fruit Stock"))
        #expect(workbook.contains("fullCalcOnLoad=\"1\""))

        let text = try await text(of: url)
        for expected in ["Plums", "Apples", "Pears", "Total", "Summary"] {
            #expect(text.contains(expected), "missing \(expected)")
        }

        let bad = try await edit(root, ["path": "budget.xlsx", "old_string": "Apples", "new_string": "Figs"])
        #expect(EnvelopeAssertions.failureField(bad) == "old_string")
        #expect((EnvelopeAssertions.failureMessage(bad) ?? "").contains("set_cells"))
    }

    @Test func formulaShiftAndRenameRespectSheetsAndLiterals() {
        let insert = XLSXFormula.RowShift(at: 3, delta: 2)
        let formula = "SUM(A1:B5)+Other!A3+'My Sheet'!$B$4+LEN(\"A3\")+C3"
        #expect(
            XLSXFormula.shift(formula, formulaSheet: "Data", targetSheet: "Data", by: insert)
                == "SUM(A1:B7)+Other!A3+'My Sheet'!$B$4+LEN(\"A3\")+C5")
        #expect(
            XLSXFormula.shift(formula, formulaSheet: "Other", targetSheet: "My Sheet", by: insert)
                == "SUM(A1:B5)+Other!A3+'My Sheet'!$B$6+LEN(\"A3\")+C3")

        let delete = XLSXFormula.RowShift(at: 2, delta: -2)
        #expect(XLSXFormula.shift("A1+A2+A5+SUM(A1:A4)", formulaSheet: "S", targetSheet: "S", by: delete)
            == "A1+#REF!+A3+SUM(A1:A2)")

        #expect(XLSXFormula.renameSheet("Sheet1!A1+'Sheet1'!B2+A3", from: "Sheet1", to: "Q3 Data")
            == "'Q3 Data'!A1+'Q3 Data'!B2+A3")
        #expect(XLSXFormula.quotedSheetName("Plain") == "Plain")
        #expect(XLSXFormula.quotedSheetName("A1") == "'A1'")
        #expect(XLSXFormula.quotedSheetName("It's") == "'It''s'")
    }

    /// A workbook with the structures a generated file never has: a shared
    /// formula block, a table with an autoFilter, conditional formatting and
    /// data validation with formulas, an array formula, and a cell comment.
    private func makeStructuredXLSX(_ url: URL) throws {
        let s = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        func row(_ n: Int, _ cells: String) -> String { "<row r=\"\(n)\">\(cells)</row>" }
        let sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="\(s)" xmlns:r="\(r)"><dimension ref="A1:E7"/><sheetData>\
            \(row(1, "<c r=\"A1\" t=\"inlineStr\"><is><t>Qty</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Price</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Total</t></is></c>"))\
            \(row(2, "<c r=\"A2\"><v>1</v></c><c r=\"B2\"><v>10</v></c><c r=\"C2\"><f t=\"shared\" ref=\"C2:C5\" si=\"0\">A2*B2</f><v>10</v></c>"))\
            \(row(3, "<c r=\"A3\"><v>2</v></c><c r=\"B3\"><v>10</v></c><c r=\"C3\"><f t=\"shared\" si=\"0\"/><v>20</v></c>"))\
            \(row(4, "<c r=\"A4\"><v>3</v></c><c r=\"B4\"><v>10</v></c><c r=\"C4\"><f t=\"shared\" si=\"0\"/><v>30</v></c>"))\
            \(row(5, "<c r=\"A5\"><v>4</v></c><c r=\"B5\"><v>10</v></c><c r=\"C5\"><f t=\"shared\" si=\"0\"/><v>40</v></c>"))\
            \(row(6, "<c r=\"E6\"><f t=\"array\" ref=\"E6:E7\">A2:A3*2</f><v>2</v></c>"))\
            \(row(7, "<c r=\"E7\"><v>4</v></c>"))\
            </sheetData>\
            <conditionalFormatting sqref="C2:C5"><cfRule type="expression" priority="1"><formula>$C5&gt;10</formula></cfRule></conditionalFormatting>\
            <dataValidations count="1"><dataValidation type="whole" sqref="A2:A5"><formula1>$B$5</formula1></dataValidation></dataValidations>\
            <tableParts count="1"><tablePart r:id="rId1"/></tableParts>\
            </worksheet>
            """
        let table = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <table xmlns="\(s)" id="1" name="Sales" displayName="Sales" ref="A1:C5" headerRowCount="1"><autoFilter ref="A1:C5"/>\
            <tableColumns count="3"><tableColumn id="1" name="Qty"/><tableColumn id="2" name="Price"/>\
            <tableColumn id="3" name="Total"><calculatedColumnFormula>A2*B2</calculatedColumnFormula></tableColumn></tableColumns></table>
            """
        let comments = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <comments xmlns="\(s)"><authors><author>QA</author></authors>\
            <commentList><comment ref="A3" authorId="0"><text><t>check</t></text></comment></commentList></comments>
            """
        var zip = ZipArchiveWriter()
        try zip.add(
            path: "[Content_Types].xml",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>\
                <Override PartName="/xl/comments1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"/>\
                </Types>
                """.utf8))
        try zip.add(
            path: "_rels/.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relBase)officeDocument" Target="xl/workbook.xml"/></Relationships>
                """.utf8))
        try zip.add(
            path: "xl/workbook.xml",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="\(s)" xmlns:r="\(r)"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
                """.utf8))
        try zip.add(
            path: "xl/_rels/workbook.xml.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relBase)worksheet" Target="worksheets/sheet1.xml"/></Relationships>
                """.utf8))
        try zip.add(path: "xl/worksheets/sheet1.xml", data: Data(sheet.utf8))
        try zip.add(
            path: "xl/worksheets/_rels/sheet1.xml.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relBase)table" Target="../tables/table1.xml"/>\
                <Relationship Id="rId2" Type="\(relBase)comments" Target="../comments1.xml"/></Relationships>
                """.utf8))
        try zip.add(path: "xl/tables/table1.xml", data: Data(table.utf8))
        try zip.add(path: "xl/comments1.xml", data: Data(comments.utf8))
        try zip.finalize().write(to: url)
    }

    @Test func xlsxRowInsertKeepsSharedFormulasTablesRulesAndComments() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sales.xlsx")
        try makeStructuredXLSX(url)

        let result = try await edit(
            root, ["path": "sales.xlsx", "operations": [["op": "insert_rows", "at": 3, "count": 1]]])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")

        let sheet = try part("xl/worksheets/sheet1.xml", in: url)
        // The straddling shared block became explicit formulas, each
        // derived from the master by its own offset and then shifted.
        #expect(sheet.contains("<c r=\"C2\"><f>A2*B2</f>"), "\(sheet)")
        #expect(sheet.contains("<c r=\"C4\"><f>A4*B4</f>"), "\(sheet)")
        #expect(sheet.contains("<c r=\"C6\"><f>A6*B6</f>"), "\(sheet)")
        #expect(!sheet.contains("t=\"shared\""), "\(sheet)")
        // Array block below the insert moved as a unit.
        #expect(sheet.contains("<f t=\"array\" ref=\"E7:E8\">A2:A4*2</f>"), "\(sheet)")
        #expect(sheet.contains("sqref=\"C2:C6\""), "\(sheet)")
        #expect(sheet.contains("<formula>$C6&gt;10</formula>"), "\(sheet)")
        #expect(sheet.contains("sqref=\"A2:A6\""), "\(sheet)")
        #expect(sheet.contains("<formula1>$B$6</formula1>"), "\(sheet)")

        let table = try part("xl/tables/table1.xml", in: url)
        #expect(table.contains("ref=\"A1:C6\""), "\(table)")
        #expect(table.contains("<autoFilter ref=\"A1:C6\"/>"), "\(table)")
        let comments = try part("xl/comments1.xml", in: url)
        #expect(comments.contains("ref=\"A4\""), "\(comments)")
        // Structured parts were shifted, not just warned about.
        #expect(!result.contains("weren't shifted"), "\(result)")
    }

    @Test func xlsxStructuralRefusalsLeaveTheFileUntouched() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sales.xlsx")
        try makeStructuredXLSX(url)
        let before = try Data(contentsOf: url)

        // Deleting the table's header row.
        let header = try await edit(root, ["path": "sales.xlsx", "operations": [["op": "delete_rows", "at": 1]]])
        #expect(ToolEnvelope.isError(header))
        #expect((EnvelopeAssertions.failureMessage(header) ?? "").contains("header row"), "\(header)")
        // Inserting inside an array formula.
        let array = try await edit(root, ["path": "sales.xlsx", "operations": [["op": "insert_rows", "at": 7]]])
        #expect(ToolEnvelope.isError(array))
        #expect((EnvelopeAssertions.failureMessage(array) ?? "").contains("array formula"), "\(array)")
        // rename/delete without naming the sheet.
        let rename = try await edit(root, ["path": "sales.xlsx", "operations": [["op": "rename_sheet", "name": "Q3"]]])
        #expect(ToolEnvelope.isError(rename))
        #expect((EnvelopeAssertions.failureMessage(rename) ?? "").contains("`sheet` is required"), "\(rename)")
        let delete = try await edit(root, ["path": "sales.xlsx", "operations": [["op": "delete_sheet"]]])
        #expect(ToolEnvelope.isError(delete))
        #expect((EnvelopeAssertions.failureMessage(delete) ?? "").contains("`sheet` is required"), "\(delete)")

        #expect(try Data(contentsOf: url) == before)
    }

    @Test func sharedFormulaTranslationMovesOnlyRelativeParts() {
        #expect(XLSXFormula.translate("A2*$B$2+Sheet2!C$3", rows: 2, columns: 1) == "B4*$B$2+Sheet2!D$3")
        #expect(XLSXFormula.translate("SUM(A1:A3)", rows: -1, columns: 0) == "SUM(#REF!)")
        #expect(XLSXFormula.translate("\"A1\"&A1", rows: 1, columns: 0) == "\"A1\"&A2")
    }

    // MARK: - PPTX

    @Test func pptxSlideOperations() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "deck.pptx", "# Alpha\n- one\n\n# Beta\n- two\n\n# Gamma\n- three\n")
        let url = root.appendingPathComponent("deck.pptx")

        let result = try await edit(
            root,
            [
                "path": "deck.pptx",
                "operations": [
                    ["op": "set_slide_text", "slide": 2, "shape": "body", "text": "- revised\n  - nested"],
                    ["op": "replace_text", "old_string": "three", "new_string": "3", "slide": 3],
                    ["op": "duplicate_slide", "slide": 1],
                    // After the duplicate: Alpha, Alpha copy, Beta, Gamma.
                    ["op": "reorder_slides", "order": [4, 3, 1, 2]],
                    ["op": "delete_slide", "slide": 4],
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")

        let structure = try await DocumentEditService.structure(of: url)
        let slides = try #require(structure["slides"] as? [[String: Any]])
        let titles = slides.map { slide in
            ((slide["shapes"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        #expect(titles == ["Gamma", "Beta", "Alpha"], "\(titles)")

        let text = try await text(of: url)
        for slide in 1...3 {
            #expect(try elementsWithoutNamespace("ppt/slides/slide\(slide).xml", in: url).isEmpty)
        }
        #expect(try elementsWithoutNamespace("ppt/presentation.xml", in: url).isEmpty)
        #expect(text.contains("revised"))
        #expect(text.contains("nested"))
        #expect(!text.contains("two"))
        #expect(text.contains("3"))
    }

    /// Word text with a `w:tab` and a `w:br` inside runs, plus a precomposed
    /// "café" — the cases where counting and replacing used to disagree.
    private func makeTabbedDOCX(_ url: URL) throws {
        try makeDOCX(url)
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(w)"><w:body>\
            <w:p><w:r><w:t>Name</w:t><w:tab/><w:t>Score</w:t></w:r></w:p>\
            <w:p><w:r><w:t>first</w:t><w:br/><w:t>second</w:t></w:r></w:p>\
            <w:p><w:r><w:t>caf\u{E9} menu</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Line one.</w:t></w:r></w:p>\
            <w:sectPr/></w:body></w:document>
            """
        let rewritten = try ZipArchive.rewrite(try Data(contentsOf: url), replacing: ["word/document.xml": Data(document.utf8)])
        try rewritten.write(to: url)
    }

    @Test func docxReplaceRespectsTabsBreaksNormalizationAndNewlines() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tabs.docx")
        try makeTabbedDOCX(url)

        // A match that would swallow the tab / line break is refused, not
        // silently applied to the wrong run.
        let tab = try await edit(
            root, ["path": "tabs.docx", "operations": [["op": "replace_text", "old_string": "Name\tScore", "new_string": "x"]]])
        #expect(ToolEnvelope.isError(tab), "\(tab)")
        #expect((EnvelopeAssertions.failureMessage(tab) ?? "").contains("tab or line break"), "\(tab)")

        // Decomposed é doesn't match the precomposed text: reported as not
        // found rather than "Replaced 0 occurrences".
        let decomposed = try await edit(
            root, ["path": "tabs.docx", "operations": [["op": "replace_text", "old_string": "cafe\u{301}", "new_string": "bar"]]])
        #expect(ToolEnvelope.isError(decomposed), "\(decomposed)")
        #expect((EnvelopeAssertions.failureMessage(decomposed) ?? "").contains("wasn't found"), "\(decomposed)")

        // Newlines in the replacement are paragraph boundaries (never soft
        // line breaks, which read back as one run-on line), and control
        // characters never reach the XML.
        let ok = try await edit(
            root,
            [
                "path": "tabs.docx",
                "operations": [
                    ["op": "replace_text", "old_string": "Line one.", "new_string": "Line one.\nLine two.\u{0}"],
                    ["op": "replace_text", "old_string": "caf\u{E9}", "new_string": "coffee"],
                ],
            ])
        #expect(ToolEnvelope.isSuccess(ok), "\(ok)")
        let xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:t>Line one.</w:t></w:r></w:p><w:p><w:r><w:t>Line two.</w:t>"), "\(xml)")
        #expect(!xml.contains("<w:br></w:br><w:t>Line two"), "\(xml)")
        #expect(!xml.unicodeScalars.contains("\u{0}"))
        #expect(xml.contains("coffee menu"), "\(xml)")
        // Tab and break still present, untouched.
        #expect(xml.contains("<w:t>Name</w:t><w:tab/><w:t>Score</w:t>") || xml.contains("<w:t>Name</w:t><w:tab></w:tab><w:t>Score</w:t>"), "\(xml)")
    }

    /// Body with Word-autocorrected punctuation (curly quotes, em dash,
    /// non-breaking space), a three-paragraph run to match across, and a
    /// header part that repeats a body word.
    private func makeToleranceDOCX(_ url: URL) throws {
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="\(w)" xmlns:r="\(r)"><w:body>\
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Draft agreement</w:t></w:r></w:p>\
            <w:p><w:r><w:t>She said \u{201C}we\u{2019}ll ship\u{201D}\u{00A0}\u{2014} by Friday.</w:t></w:r></w:p>\
            <w:p><w:r><w:rPr><w:i/></w:rPr><w:t>Intro: </w:t></w:r><w:r><w:t>first clause here.</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="ListParagraph"/></w:pPr><w:r><w:t>Second clause.</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Third clause</w:t></w:r><w:r><w:t xml:space="preserve"> and a tail.</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Closing remarks about the whole agreement.</w:t></w:r></w:p>\
            <w:sectPr><w:headerReference w:type="default" r:id="rId2"/></w:sectPr></w:body></w:document>
            """
        let header = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:hdr xmlns:w="\(w)"><w:p><w:r><w:t>Draft \u{2013} confidential</w:t></w:r></w:p></w:hdr>
            """
        var zip = ZipArchiveWriter()
        try zip.add(
            path: "[Content_Types].xml",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
                <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>\
                </Types>
                """.utf8))
        try zip.add(
            path: "_rels/.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
                </Relationships>
                """.utf8))
        try zip.add(path: "word/document.xml", data: Data(document.utf8))
        try zip.add(path: "word/header1.xml", data: Data(header.utf8))
        try zip.add(
            path: "word/_rels/document.xml.rels",
            data: Data(
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>\
                </Relationships>
                """.utf8))
        try zip.finalize().write(to: url)
    }

    @Test func docxReplaceToleratesAutocorrectedPunctuationAndSaysSo() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tolerant.docx")
        try makeToleranceDOCX(url)

        // Straight quotes, ASCII apostrophe, hyphen, plain spaces: the model's
        // rendering of what Word autocorrected.
        let result = try await edit(
            root,
            [
                "path": "tolerant.docx",
                "operations": [
                    ["op": "replace_text", "old_string": "\"we'll ship\" - by Friday", "new_string": "\"we'll ship\" by Thursday"]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let applied = (payload["operations_applied"] as? [String]) ?? []
        #expect(applied.joined(separator: "\n").contains("normalized"), "\(applied)")
        let xml = try part("word/document.xml", in: url)
        #expect(xml.contains("She said \"we'll ship\" by Thursday."), "\(xml)")
        #expect(!xml.contains("\u{2014}"), "\(xml)")

        // Identical old/new is a no-op error, not a silent success.
        let same = try await edit(
            root, ["path": "tolerant.docx", "operations": [["op": "replace_text", "old_string": "Second clause.", "new_string": "Second clause."]]])
        #expect(ToolEnvelope.isError(same), "\(same)")
        #expect((EnvelopeAssertions.failureMessage(same) ?? "").contains("identical"), "\(same)")
    }

    /// Bullets are list formatting in Word. `file_read` renders a list
    /// paragraph as "•\tSecond clause." and a model that drafted the file as
    /// Markdown types "- Second clause."; both must edit the paragraph
    /// without writing a literal marker, and the result must say so.
    @Test func docxReplaceTreatsLeadingListMarkersAsFormatting() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("list.docx")
        try makeToleranceDOCX(url)

        let bulletTab = try await edit(
            root,
            ["path": "list.docx", "operations": [["op": "replace_text", "old_string": "•\tSecond clause.", "new_string": "•\tSecond clause, revised."]]])
        #expect(ToolEnvelope.isSuccess(bulletTab), "\(bulletTab)")
        let applied = ((try #require(EnvelopeAssertions.successPayload(bulletTab)))["operations_applied"] as? [String]) ?? []
        #expect(applied.joined(separator: "\n").contains("treated as formatting"), "\(applied)")
        var xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/></w:pPr><w:r><w:t>Second clause, revised.</w:t>"), "\(xml)")
        #expect(!xml.contains("•"), "\(xml)")

        let markdownDash = try await edit(
            root,
            ["path": "list.docx", "operations": [["op": "replace_text", "old_string": "- Second clause, revised.", "new_string": "- Second clause, final."]]])
        #expect(ToolEnvelope.isSuccess(markdownDash), "\(markdownDash)")
        xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:t>Second clause, final.</w:t>"), "\(xml)")
        #expect(!xml.contains("<w:t>- Second"), "\(xml)")

        // Heading hashes and inline emphasis are formatting too: the model
        // that drafted "## Draft agreement" / "- **Second clause, final.**"
        // addresses the styled paragraphs without the syntax being text.
        let headingHashes = try await edit(
            root, ["path": "list.docx", "operations": [["op": "replace_text", "old_string": "## Draft agreement", "new_string": "## Final agreement"]]])
        #expect(ToolEnvelope.isSuccess(headingHashes), "\(headingHashes)")
        let emphasis = try await edit(
            root,
            ["path": "list.docx", "operations": [["op": "replace_text", "old_string": "- **Second clause, final.**", "new_string": "- **Second clause, signed.**"]]])
        #expect(ToolEnvelope.isSuccess(emphasis), "\(emphasis)")
        xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t>Final agreement</w:t>"), "\(xml)")
        #expect(xml.contains("<w:t>Second clause, signed.</w:t>") && !xml.contains("**") && !xml.contains("## "), "\(xml)")

        // A genuine miss still reports the closest paragraph, not a marker note.
        let miss = try await edit(
            root, ["path": "list.docx", "operations": [["op": "replace_text", "old_string": "- Third clause.", "new_string": "x"]]])
        #expect(ToolEnvelope.isError(miss), "\(miss)")
        let message = EnvelopeAssertions.failureMessage(miss) ?? ""
        #expect(message.contains("wasn't found"), "\(message)")
        #expect(!message.contains("treated as formatting"), "\(message)")

        #expect(DOCXEditor.strippingListMarkers("1. First\n  2) Second\n• Third\nplain").text == "First\n  Second\nThird\nplain")
        #expect(DOCXEditor.strippingListMarkers("-5 degrees").stripped == false)
        #expect(DOCXEditor.strippingListMarkers("1.5 litres").stripped == false)
        #expect(DOCXEditor.strippingMarkdownSyntax("### Title **bold** and `code`, _it_ file_name a*b").text == "Title bold and code, it file_name a*b")
        #expect(DOCXEditor.strippingMarkdownSyntax("plain 2 * 3 = 6").stripped == false)
    }

    /// On a `file_write`-rendered draft (bullets are literal "•\t" text), the
    /// Raptor no-think flow: `- **Kickoff: April 7**` matches the bold
    /// bulleted line, `## Scope` matches the heading, and appending a section
    /// through a whole-line match keeps the line's bullet and adds sibling
    /// bullets in the same literal shape.
    @Test func renderedDraftAcceptsMarkdownSyntaxAndKeepsLiteralBullets() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(
            root, "brief.docx",
            "# Atlas Brief\n\n## Scope\n- **Kickoff: April 7**\n- Full rollout in Q3\n")
        let url = root.appendingPathComponent("brief.docx")

        let date = try await edit(
            root, ["path": "brief.docx", "old_string": "- **Kickoff: April 7**", "new_string": "- **Kickoff: May 5**"])
        #expect(ToolEnvelope.isSuccess(date), "\(date)")
        let heading = try await edit(root, ["path": "brief.docx", "old_string": "## Scope", "new_string": "## Scope and Timeline"])
        #expect(ToolEnvelope.isSuccess(heading), "\(heading)")
        let section = try await edit(
            root,
            [
                "path": "brief.docx", "old_string": "•\tFull rollout in Q3",
                "new_string": "- Full rollout in Q3\n\n## Risks\n- Vendor delays\n- Data loss",
            ])
        #expect(ToolEnvelope.isSuccess(section), "\(section)")

        let editor = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: url)))
        let texts = try editor.paragraphs().map { OOXMLText.text(of: $0) }
        #expect(
            texts == ["Atlas Brief", "Scope and Timeline", "•\tKickoff: May 5", "•\tFull rollout in Q3", "Risks", "•\tVendor delays", "•\tData loss"],
            "\(texts)")
        let xml = try part("word/document.xml", in: url)
        #expect(!xml.contains("**") && !xml.contains("## ") && !xml.contains("- Vendor"), "\(xml)")
    }

    /// Raptor-0.6-4B (`document-drafting-revisions`, post-change run): a
    /// multi-line `old_string` written with `- ` markers against a rendered
    /// draft whose list items read "•\tKickoff: April 7". The Markdown
    /// rescue strips the markers, so the middle/last lines must still
    /// address whole items whose text starts with the literal bullet; the
    /// bullets stay in place and the appended section is styled.
    @Test func renderedDraftMultiLineOldStringWithListMarkersMatchesLiteralBullets() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(
            root, "brief.docx",
            "# Atlas Migration Brief\n\n## Goal\n- Define the objectives\n\n## Timeline\n- Kickoff: April 7\n- Phase 1 complete in June\n- Set the schedule for each phase\n")
        let url = root.appendingPathComponent("brief.docx")

        let section = try await edit(
            root,
            [
                "path": "brief.docx",
                "old_string": "- Kickoff: April 7\n- Phase 1 complete in June\n- Set the schedule for each phase",
                "new_string":
                    "- Kickoff: May 5\n- Phase 1 complete in June\n- Set the schedule for each phase\n\n## Risks\n- Identify potential risks and mitigation strategies\n- Define monitoring and response protocols",
            ])
        #expect(ToolEnvelope.isSuccess(section), "\(section)")

        let editor = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: url)))
        let texts = try editor.paragraphs().map { OOXMLText.text(of: $0) }
        #expect(
            texts == [
                "Atlas Migration Brief", "Goal", "•\tDefine the objectives", "Timeline", "•\tKickoff: May 5", "•\tPhase 1 complete in June",
                "•\tSet the schedule for each phase", "Risks", "•\tIdentify potential risks and mitigation strategies",
                "•\tDefine monitoring and response protocols",
            ], "\(texts)")
        let xml = try part("word/document.xml", in: url)
        #expect(!xml.contains("- Kickoff") && !xml.contains("## Risks") && !xml.contains("April 7"), "\(xml)")

        // Collapsing two bulleted items into one keeps a single bullet.
        let merged = try await edit(
            root,
            [
                "path": "brief.docx",
                "old_string": "- Identify potential risks and mitigation strategies\n- Define monitoring and response protocols",
                "new_string": "- Identify risks and define monitoring",
            ])
        #expect(ToolEnvelope.isSuccess(merged), "\(merged)")
        let mergedTexts = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: url))).paragraphs().map { OOXMLText.text(of: $0) }
        #expect(Array(mergedTexts.suffix(2)) == ["Risks", "•\tIdentify risks and define monitoring"], "\(mergedTexts)")

        #expect(DOCXEditor.literalBulletPrefix("•\tItem") == "•\t")
        #expect(DOCXEditor.literalBulletPrefix("12) Item") == "12) ")
        #expect(DOCXEditor.literalBulletPrefix("1.\tItem") == "1.\t")
        #expect(DOCXEditor.literalBulletPrefix("2024 was a year") == nil)
        #expect(DOCXEditor.literalBulletPrefix("Plain") == nil)
        // The leading-side tolerance only covers a literal list prefix.
        #expect(DOCXEditor.edgeRange(of: "Kickoff", in: "•\tKickoff", edge: .whole, mode: .exact) == 2..<9)
        #expect(DOCXEditor.edgeRange(of: "Kickoff", in: "Re: Kickoff", edge: .prefix, mode: .exact) == nil)
    }

    /// An empty `old_string` with a `new_string` is an insert; the
    /// rejection names the operations that add text (Raptor-0.6-4B tried
    /// this twice while appending a section).
    @Test func docxEmptyOldStringNamesInsertOperations() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "brief.docx", "# Brief\n\nBody.\n")

        let single = try await edit(root, ["path": "brief.docx", "old_string": "", "new_string": "## Risks\n- Vendor delays"])
        #expect(!ToolEnvelope.isSuccess(single))
        #expect(ToolEnvelope.failureMessage(single).contains("append_markdown"), "\(single)")
        #expect(ToolEnvelope.failureMessage(single).contains("insert_paragraph"), "\(single)")

        let batch = try await edit(root, ["path": "brief.docx", "edits": [["old_string": "", "new_string": "## Risks"]]])
        #expect(ToolEnvelope.failureMessage(batch).contains("append_markdown"), "\(batch)")

        // A missing new_string is not an insert; no operations advice.
        let missing = try await edit(root, ["path": "brief.docx", "old_string": "Body."])
        #expect(!ToolEnvelope.failureMessage(missing).contains("append_markdown"), "\(missing)")
    }

    /// Document operations sent under `edits` (`{"edits": [{"op":
    /// "set_cells", …}]}`, Raptor-0.6-4B 2/2 rows) are moved to
    /// `operations` before schema validation, which would otherwise reject
    /// them for the missing `old_string`. Text-file batches never carry an
    /// `op`, so they are untouched; a real `operations` array wins.
    @Test func operationsSentAsEditsArePromotedBeforeValidation() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "budget.xlsx", "Dept,Q1\nEng,10\nOps,20\n")

        let raw = #"{"edits":[{"cells":{"B4":"=SUM(B2:B3)"},"op":"set_cells"},{"cells":{"B3":25},"op":"set_cells"}],"path":"budget.xlsx"}"#
        let normalized = FileEditTool.normalizingEditShapes(raw)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any])
        #expect(object["edits"] == nil)
        #expect((object["operations"] as? [[String: Any]])?.count == 2, "\(normalized)")
        let schemaCheck = SchemaValidator.validate(arguments: object, against: try #require(FileEditTool(rootPath: root).parameters))
        #expect(schemaCheck.isValid, "\(schemaCheck.errorMessage ?? "")")

        let applied = try await FileEditTool(rootPath: root).execute(argumentsJSON: normalized)
        #expect(ToolEnvelope.isSuccess(applied), "\(applied)")
        let sheet = try part("xl/worksheets/sheet1.xml", in: root.appendingPathComponent("budget.xlsx"))
        #expect(sheet.contains("SUM(B2:B3)") && sheet.contains("<v>25</v>"), "\(sheet)")

        // Mixed: a pair beside an operation becomes replace_text and keeps replace_all.
        let mixed = FileEditTool.normalizingEditShapes(
            #"{"path":"memo.docx","replace_all":true,"edits":[{"old_string":"a","new_string":"b"},{"op":"delete_paragraph","index":3}]}"#)
        let mixedObject = try #require(try JSONSerialization.jsonObject(with: Data(mixed.utf8)) as? [String: Any])
        let ops = try #require(mixedObject["operations"] as? [[String: Any]])
        #expect(ops[0]["op"] as? String == "replace_text" && ops[0]["all"] as? Bool == true, "\(ops)")
        #expect(ops[1]["op"] as? String == "delete_paragraph", "\(ops)")

        // Untouched: text batch, unknown op, real operations present.
        for unchanged in [
            #"{"path":"a.txt","edits":[{"old_string":"a","new_string":"b"}]}"#,
            #"{"path":"a.docx","edits":[{"op":"explode"}]}"#,
            #"{"path":"a.docx","edits":[{"op":"delete_paragraph","index":1}],"operations":[{"op":"append_markdown","markdown":"x"}]}"#,
        ] {
            #expect(FileEditTool.normalizingEditShapes(unchanged) == unchanged)
        }
    }

    /// Raptor-0.6-4B (`edit-docx-in-place` ×3, `fill-pdf-form-in-place` ×2,
    /// third post-change run): `edits` as a JSON string and `path` inside
    /// every entry instead of at the top level. Both shapes are repaired
    /// before validation when unambiguous; disagreeing or absent paths are
    /// still rejected for the missing `path`.
    @Test func stringEncodedEditsAndPerEntryPathAreNormalizedBeforeValidation() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "memo.docx", "# Memo\n\nStatus: Draft\n\nGo-live remains scheduled for April 14.\n")
        let schema = try #require(FileEditTool(rootPath: root).parameters)

        let raw =
            #"{"dry_run":"false","edits":"[{\"new_string\": \"Status: Final\", \"old_string\": \"Status: Draft\", \"path\": \"memo.docx\"}, {\"new_string\": \"April 21.\", \"old_string\": \"April 14.\", \"path\": \"memo.docx\"}]"}"#
        #expect(!SchemaValidator.validate(arguments: try JSONSerialization.jsonObject(with: Data(raw.utf8)), against: schema).isValid)
        let normalized = FileEditTool.normalizingEditShapes(raw)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any])
        #expect(object["path"] as? String == "memo.docx", "\(normalized)")
        let edits = try #require(object["edits"] as? [[String: Any]])
        #expect(edits.count == 2 && edits.allSatisfy { $0["path"] == nil }, "\(edits)")
        #expect(SchemaValidator.validate(arguments: object, against: schema).isValid, "\(normalized)")
        let applied = try await FileEditTool(rootPath: root).execute(argumentsJSON: normalized)
        #expect(ToolEnvelope.isSuccess(applied), "\(applied)")
        let texts = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: root.appendingPathComponent("memo.docx")))).paragraphs()
            .map { OOXMLText.text(of: $0) }
        #expect(texts.contains("Status: Final") && texts.contains("Go-live remains scheduled for April 21."), "\(texts)")

        // Per-entry path + document op under `edits`: hoisted and promoted together.
        let form = FileEditTool.normalizingEditShapes(
            #"{"dry_run":"true","edits":[{"fields":{"Name":"Ada"},"op":"fill_form","path":"intake-form.pdf"}]}"#)
        let formObject = try #require(try JSONSerialization.jsonObject(with: Data(form.utf8)) as? [String: Any])
        #expect(formObject["path"] as? String == "intake-form.pdf", "\(form)")
        #expect((formObject["operations"] as? [[String: Any]])?.first?["op"] as? String == "fill_form", "\(form)")
        #expect(SchemaValidator.validate(arguments: formObject, against: schema).isValid, "\(form)")

        // Ambiguous or absent paths are left for the validator to reject.
        for unchanged in [
            #"{"edits":[{"old_string":"a","new_string":"b","path":"x.txt"},{"old_string":"c","new_string":"d","path":"y.txt"}]}"#,
            #"{"edits":[{"fields":{"Name":"Ada"},"op":"fill_form"}]}"#,
            #"{"edits":[{"old_string":"a","new_string":"b","path":""}]}"#,
        ] {
            let result = FileEditTool.normalizingEditShapes(unchanged)
            let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8))
            let verdict = SchemaValidator.validate(arguments: parsed, against: schema)
            #expect(!verdict.isValid && verdict.field == "path", "\(result) → \(verdict.errorMessage ?? "")")
        }
        // A top-level path always wins over entry paths.
        let kept = FileEditTool.normalizingEditShapes(#"{"path":"real.txt","edits":[{"old_string":"a","new_string":"b","path":"other.txt"}]}"#)
        #expect(kept == #"{"path":"real.txt","edits":[{"old_string":"a","new_string":"b","path":"other.txt"}]}"#)
    }

    /// The drafting workflow: a model appends a section by replacing the
    /// last paragraph of the previous one with itself plus Markdown lines.
    /// Every line becomes a paragraph (headings/bullets pick styles, never
    /// literal `##`/`-` text), a tail after the match keeps its runs, and the
    /// new paragraphs are addressable by a later multi-line `old_string`.
    @Test func docxMultiLineReplacementExpandsIntoStyledParagraphs() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.docx")
        try makeToleranceDOCX(url)

        let appended = try await edit(
            root,
            [
                "path": "draft.docx",
                "operations": [
                    [
                        "op": "replace_text", "old_string": "- first clause here.",
                        "new_string": "- first clause here.\n\n## Risks\n- Vendor delays\n- Resource contention\nMitigation is tracked weekly.",
                    ]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(appended), "\(appended)")
        let applied = ((try #require(EnvelopeAssertions.successPayload(appended)))["operations_applied"] as? [String]) ?? []
        #expect(applied.joined(separator: "\n").contains("5 paragraphs"), "\(applied)")
        var xml = try part("word/document.xml", in: url)
        // The matched paragraph keeps its head run and takes the first line.
        #expect(xml.contains("<w:t>Intro: </w:t></w:r><w:r><w:t>first clause here.</w:t></w:r></w:p>"), "\(xml)")
        // No styles.xml in this fixture → the heading is bold text, not "## Risks".
        #expect(xml.contains("<w:rPr><w:b></w:b></w:rPr><w:t>Risks</w:t>") || xml.contains("<w:rPr><w:b/></w:rPr><w:t>Risks</w:t>"), "\(xml)")
        #expect(!xml.contains("## Risks"), "\(xml)")
        // Bullets clone the nearest list paragraph's formatting; no literal markers.
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/></w:pPr><w:r><w:t>Vendor delays</w:t>"), "\(xml)")
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/></w:pPr><w:r><w:t>Resource contention</w:t>"), "\(xml)")
        #expect(!xml.contains("- Vendor") && !xml.contains("•"), "\(xml)")
        #expect(!xml.contains("<w:br"), "\(xml)")
        let editor = try DOCXEditor(package: OOXMLPackage(data: Data(contentsOf: url)))
        let texts = try editor.paragraphs().map { OOXMLText.text(of: $0) }
        #expect(
            Array(texts[2...7]) == [
                "Intro: first clause here.", "Risks", "Vendor delays", "Resource contention", "Mitigation is tracked weekly.", "Second clause.",
            ], "\(texts)")

        // The new paragraphs are real paragraphs: a later multi-line
        // old_string (as `file_read` would render them) addresses them.
        let revised = try await edit(
            root,
            [
                "path": "draft.docx",
                "operations": [
                    [
                        "op": "replace_text", "old_string": "Risks\n•\tVendor delays\n•\tResource contention",
                        "new_string": "Risks\n- Vendor delays (mitigated)\n- Resource contention",
                    ]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(revised), "\(revised)")
        xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/></w:pPr><w:r><w:t>Vendor delays (mitigated)</w:t>"), "\(xml)")

        // A partial match with a tail: the tail moves to the last new
        // paragraph and keeps its own run.
        let split = try await edit(
            root,
            ["path": "draft.docx", "operations": [["op": "replace_text", "old_string": "Third clause", "new_string": "Third clause\nFourth clause"]]])
        #expect(ToolEnvelope.isSuccess(split), "\(split)")
        xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:t>Third clause</w:t></w:r></w:p><w:p><w:r><w:t>Fourth clause</w:t></w:r><w:r><w:t xml:space=\"preserve\"> and a tail.</w:t>"), "\(xml)")

        #expect(DOCXEditor.blockMarkdown("## Risks ").kind == .heading(2))
        #expect(DOCXEditor.blockMarkdown("•\tItem").text == "Item")
        #expect(DOCXEditor.blockMarkdown("#hashtag").kind == .plain)
    }

    @Test func docxMultiMatchNamesPartsAndNotFoundQuotesClosestParagraph() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("parts.docx")
        try makeToleranceDOCX(url)
        let before = try Data(contentsOf: url)

        // "Draft" appears in the body heading and the header.
        let ambiguous = try await edit(
            root, ["path": "parts.docx", "operations": [["op": "replace_text", "old_string": "Draft", "new_string": "Final"]]])
        #expect(ToolEnvelope.isError(ambiguous), "\(ambiguous)")
        let message = EnvelopeAssertions.failureMessage(ambiguous) ?? ""
        #expect(message.contains("appears 2 times"), "\(message)")
        #expect(message.contains("1 in body"), "\(message)")
        #expect(message.contains("1 in header1"), "\(message)")
        #expect(try Data(contentsOf: url) == before)

        // replace_all takes both, header included.
        let all = try await edit(
            root,
            ["path": "parts.docx", "operations": [["op": "replace_text", "old_string": "Draft", "new_string": "Final", "replace_all": true]]])
        #expect(ToolEnvelope.isSuccess(all), "\(all)")
        #expect(try part("word/header1.xml", in: url).contains("Final \u{2013} confidential"))
        #expect(try part("word/document.xml", in: url).contains("Final agreement"))

        // A near miss quotes the document's own paragraph.
        let miss = try await edit(
            root,
            ["path": "parts.docx", "operations": [["op": "replace_text", "old_string": "Closing remarks about the entire agreement.", "new_string": "x"]]])
        #expect(ToolEnvelope.isError(miss), "\(miss)")
        let missMessage = EnvelopeAssertions.failureMessage(miss) ?? ""
        #expect(missMessage.contains("wasn't found"), "\(missMessage)")
        #expect(missMessage.contains("closest paragraph"), "\(missMessage)")
        #expect(missMessage.contains("Closing remarks about the whole agreement."), "\(missMessage)")
    }

    @Test func docxReplaceAcrossParagraphsKeepsStylesAndRuns() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("multi.docx")
        try makeToleranceDOCX(url)

        // Three paragraphs → three paragraphs: the first keeps its italic
        // "Intro: " run and the last keeps its tail; the middle keeps its
        // list style.
        let three = try await edit(
            root,
            [
                "path": "multi.docx",
                "operations": [
                    [
                        "op": "replace_text",
                        "old_string": "first clause here.\nSecond clause.\nThird clause",
                        "new_string": "FIRST.\n\nSECOND.\nTHIRD",
                    ]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(three), "\(three)")
        var xml = try part("word/document.xml", in: url)
        #expect(xml.contains("<w:i/></w:rPr><w:t xml:space=\"preserve\">Intro: </w:t></w:r><w:r><w:t>FIRST.</w:t>") || xml.contains("<w:i/></w:rPr><w:t>Intro: </w:t></w:r><w:r><w:t>FIRST.</w:t>"), "\(xml)")
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/></w:pPr><w:r><w:t>SECOND.</w:t>"), "\(xml)")
        #expect(xml.contains("<w:t>THIRD</w:t></w:r><w:r><w:t xml:space=\"preserve\"> and a tail.</w:t>"), "\(xml)")
        #expect(!xml.contains("clause"), "\(xml)")
        #expect(try elementsWithoutNamespace("word/document.xml", in: url).isEmpty)

        // Three paragraphs → one: the run collapses into the first
        // paragraph and the extra paragraphs are gone.
        let one = try await edit(
            root,
            [
                "path": "multi.docx",
                "operations": [
                    ["op": "replace_text", "old_string": "FIRST.\nSECOND.\nTHIRD and a tail.", "new_string": "Everything, merged."]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(one), "\(one)")
        xml = try part("word/document.xml", in: url)
        #expect(xml.contains("Intro: "), "\(xml)")
        #expect(xml.contains("Everything, merged."), "\(xml)")
        #expect(!xml.contains("SECOND"), "\(xml)")
        #expect(!xml.contains("ListParagraph"), "\(xml)")
        let merged = try await text(of: url)
        #expect(merged.contains("Intro: Everything, merged."), "\(merged)")

        // One paragraph → three: the extra lines become new paragraphs.
        let grow = try await edit(
            root,
            [
                "path": "multi.docx",
                "operations": [
                    ["op": "replace_text", "old_string": "Everything, merged.\nClosing remarks", "new_string": "Alpha.\nBeta.\nGamma. Closing remarks"]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(grow), "\(grow)")
        let grown = try await text(of: url)
        #expect(grown.contains("Intro: Alpha."), "\(grown)")
        #expect(grown.contains("Beta."), "\(grown)")
        #expect(grown.contains("Gamma. Closing remarks about the whole agreement."), "\(grown)")

        // Wrong second line: the error shows what actually follows.
        let wrong = try await edit(
            root,
            ["path": "multi.docx", "operations": [["op": "replace_text", "old_string": "Alpha.\nNot here.", "new_string": "x"]]])
        #expect(ToolEnvelope.isError(wrong), "\(wrong)")
        let wrongMessage = EnvelopeAssertions.failureMessage(wrong) ?? ""
        #expect(wrongMessage.contains("consecutive paragraphs"), "\(wrongMessage)")
        #expect(wrongMessage.contains("Beta."), "\(wrongMessage)")
    }

    /// Deck from the emitter plus a chart hanging off slide 1 (with an
    /// embedded workbook) and a p14 section list naming every slide.
    private func makeChartedPPTX(_ root: URL) async throws -> URL {
        try await write(root, "deck.pptx", "# Alpha\n- one\n\n# Beta\n- two\n\n# Gamma\n- three\n")
        let url = root.appendingPathComponent("deck.pptx")
        let data = try Data(contentsOf: url)
        let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let relsNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let presentation = try part("ppt/presentation.xml", in: url)
            .replacingOccurrences(
                of: "</p:presentation>",
                with:
                    "<p:extLst><p:ext uri=\"{521415D9-36F7-43E2-AB2F-B90AF26B5E84}\"><p14:sectionLst xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\">"
                    + "<p14:section name=\"Intro\" id=\"{1}\"><p14:sldIdLst><p14:sldId id=\"256\"/><p14:sldId id=\"257\"/></p14:sldIdLst></p14:section>"
                    + "<p14:section name=\"End\" id=\"{2}\"><p14:sldIdLst><p14:sldId id=\"258\"/></p14:sldIdLst></p14:section>"
                    + "</p14:sectionLst></p:ext></p:extLst></p:presentation>")
        let slideRels = try part("ppt/slides/_rels/slide1.xml.rels", in: url)
            .replacingOccurrences(
                of: "</Relationships>",
                with: "<Relationship Id=\"rIdChart\" Type=\"\(relBase)chart\" Target=\"../charts/chart1.xml\"/></Relationships>")
        let contentTypes = try part("[Content_Types].xml", in: url)
            .replacingOccurrences(
                of: "</Types>",
                with:
                    "<Override PartName=\"/ppt/charts/chart1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"
                    + "<Default Extension=\"xlsx\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\"/></Types>")
        let chart = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <c:chart><c:plotArea><c:barChart><c:ser><c:val><c:numRef><c:f>Sheet1!$B$2:$B$4</c:f></c:numRef></c:val></c:ser></c:barChart></c:plotArea></c:chart>\
            <c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>
            """
        let chartRels =
            "<Relationships xmlns=\"\(relsNS)\"><Relationship Id=\"rId1\" Type=\"\(relBase)package\" Target=\"../embeddings/Microsoft_Excel_Worksheet1.xlsx\"/></Relationships>"
        let rewritten = try ZipArchive.rewrite(
            data,
            replacing: [
                "ppt/presentation.xml": Data(presentation.utf8),
                "ppt/slides/_rels/slide1.xml.rels": Data(slideRels.utf8),
                "[Content_Types].xml": Data(contentTypes.utf8),
                "ppt/charts/chart1.xml": Data(chart.utf8),
                "ppt/charts/_rels/chart1.xml.rels": Data(chartRels.utf8),
                "ppt/embeddings/Microsoft_Excel_Worksheet1.xlsx": Data("not-really-a-workbook".utf8),
            ])
        try rewritten.write(to: url)
        return url
    }

    @Test func pptxDuplicateClonesChartsAndDeletePrunesSections() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeChartedPPTX(root)

        let dup = try await edit(root, ["path": "deck.pptx", "operations": [["op": "duplicate_slide", "slide": 1]]])
        #expect(ToolEnvelope.isSuccess(dup), "\(dup)")
        let names = Set(try ZipArchive.entries(in: try Data(contentsOf: url)).map(\.name))
        #expect(names.contains("ppt/charts/chart2.xml"), "\(names.sorted())")
        #expect(names.contains("ppt/embeddings/Microsoft_Excel_Worksheet2.xlsx"), "\(names.sorted())")
        let copyRels = try part("ppt/slides/_rels/slide4.xml.rels", in: url)
        #expect(copyRels.contains("../charts/chart2.xml"), "\(copyRels)")
        #expect(try part("ppt/charts/_rels/chart2.xml.rels", in: url).contains("Microsoft_Excel_Worksheet2.xlsx"))
        #expect(try part("[Content_Types].xml", in: url).contains("/ppt/charts/chart2.xml"))
        // The original still points at its own chart.
        #expect(try part("ppt/slides/_rels/slide1.xml.rels", in: url).contains("../charts/chart1.xml"))

        // Deck is now Alpha, Alpha copy, Beta, Gamma; delete Beta (id 257).
        let del = try await edit(root, ["path": "deck.pptx", "operations": [["op": "delete_slide", "slide": 3]]])
        #expect(ToolEnvelope.isSuccess(del), "\(del)")
        let presentation = try part("ppt/presentation.xml", in: url)
        #expect(!presentation.contains("<p14:sldId id=\"257\""), "\(presentation)")
        #expect(presentation.contains("<p14:sldId id=\"256\""), "\(presentation)")
        #expect(presentation.contains("<p14:sldId id=\"258\""), "\(presentation)")
    }

    @Test func pptxReplaceRefusesNewlinesInsideRuns() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "deck.pptx", "# Alpha\n- one\n")
        let result = try await edit(
            root, ["path": "deck.pptx", "operations": [["op": "replace_text", "old_string": "one", "new_string": "one\ntwo"]]])
        #expect(ToolEnvelope.isError(result), "\(result)")
        #expect((EnvelopeAssertions.failureMessage(result) ?? "").contains("set_slide_text"), "\(result)")
    }

    @Test func pptxReplaceToleratesPunctuationAndLocatesMultiMatchesBySlide() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "deck.pptx", "# Q3 \u{2014} \u{201C}Plan\u{201D}\n- Ship it\n\n# Q4\n- Ship it\n")

        let tolerant = try await edit(
            root, ["path": "deck.pptx", "operations": [["op": "replace_text", "old_string": "Q3 - \"Plan\"", "new_string": "Q3 Plan"]]])
        #expect(ToolEnvelope.isSuccess(tolerant), "\(tolerant)")
        let applied = (EnvelopeAssertions.successPayload(tolerant)?["operations_applied"] as? [String]) ?? []
        #expect(applied.joined(separator: "\n").contains("normalized"), "\(applied)")
        #expect(try part("ppt/slides/slide1.xml", in: root.appendingPathComponent("deck.pptx")).contains("Q3 Plan"))

        let ambiguous = try await edit(
            root, ["path": "deck.pptx", "operations": [["op": "replace_text", "old_string": "Ship it", "new_string": "Shipped"]]])
        #expect(ToolEnvelope.isError(ambiguous), "\(ambiguous)")
        let message = EnvelopeAssertions.failureMessage(ambiguous) ?? ""
        #expect(message.contains("1 on slide 1, 1 on slide 2"), "\(message)")

        let miss = try await edit(
            root, ["path": "deck.pptx", "operations": [["op": "replace_text", "old_string": "Ship it now", "new_string": "x"]]])
        #expect(ToolEnvelope.isError(miss), "\(miss)")
        let missMessage = EnvelopeAssertions.failureMessage(miss) ?? ""
        #expect(missMessage.contains("closest slide text"), "\(missMessage)")
    }

    @Test func pptxEmitterOutputParsesAndUsesTitleSlide() async throws {
        let slides = PPTXEmitter.slides(fromMarkdown: "# Deck\nsubtitle\n\n## Point\n- a\n- b\n", fallbackTitle: "x")
        #expect(slides.map(\.title) == ["Deck", "Point"])
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await write(root, "deck.pptx", "# Deck\nsubtitle\n\n## Point\n- a\n- b\n")
        let url = root.appendingPathComponent("deck.pptx")
        let parsed = try await PPTXAdapter().parse(url: url, sizeLimit: 50_000_000)
        for expected in ["Deck", "subtitle", "Point", "a", "b"] {
            #expect(parsed.textFallback.contains(expected))
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", url.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
    }

    // MARK: - PDF

    /// Blank pages whose widths (200, 300, 400…) identify them after edits.
    private func makePDF(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pages {
            var pageBox = CGRect(x: 0, y: 0, width: 200 + index * 100, height: 400)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func pageWidths(_ url: URL) throws -> [Int] {
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount).map { Int(document.page(at: $0)!.bounds(for: .mediaBox).width) }
    }

    // MARK: PDF forms

    /// Minimal classic-xref PDF writer: objects by number, offsets computed.
    private func buildPDF(_ objects: [Int: String], root: Int = 1) -> Data {
        var out = Data("%PDF-1.6\n".utf8)
        var offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n\(objects[number]!)\nendobj\n".utf8))
        }
        let xref = out.count
        let size = (objects.keys.max() ?? 0) + 1
        out.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for number in 1..<size {
            out.append(Data(String(format: "%010d 00000 n \n", offsets[number] ?? 0).utf8))
        }
        out.append(Data("trailer\n<< /Size \(size) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    private func pdfStream(_ dict: String, _ body: String) -> String {
        "<< \(dict) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
    }

    /// AcroForm intake form: text `Name`, checkbox `Agree` (on-state
    /// /Yes), radio group `Plan` (/Basic, /Pro), combo `State`,
    /// hierarchical text `applicant.email`, push button `Submit`. `xfa`
    /// adds an /XFA entry the way LiveCycle hybrids do.
    private func makeAcroFormPDF(_ url: URL, xfa: Bool = false) throws {
        let content = """
            BT /F1 12 Tf 40 740 Td (Name:) Tj ET
            BT /F1 12 Tf 40 700 Td (I agree to the terms) Tj ET
            BT /F1 12 Tf 40 660 Td (Plan:  Basic        Pro) Tj ET
            BT /F1 12 Tf 40 620 Td (State:) Tj ET
            BT /F1 12 Tf 40 580 Td (Email:) Tj ET
            """
        var acro = "/Fields [10 0 R 11 0 R 12 0 R 15 0 R 16 0 R 18 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >>"
        if xfa { acro += " /XFA 19 0 R" }
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R /AcroForm << \(acro) >> >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> "
                + "/Annots [10 0 R 11 0 R 13 0 R 14 0 R 15 0 R 17 0 R 18 0 R] >>",
            4: pdfStream("", content),
            5: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            6: pdfStream("/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "0 g BT /ZaDb 10 Tf 2 3 Td (4) Tj ET"),
            7: pdfStream("/Type /XObject /Subtype /Form /BBox [0 0 14 14]", ""),
            8: pdfStream("/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "0 g 7 7 m 7 7 l S"),
            9: pdfStream("/Type /XObject /Subtype /Form /BBox [0 0 200 18] /Resources << /Font << /Helv 5 0 R >> >>", "/Tx BMC EMC"),
            10: "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V () /DA (/Helv 10 Tf 0 g) /Rect [90 732 290 750] /F 4 /P 3 0 R /AP << /N 9 0 R >> >>",
            11: "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Off /AS /Off /Rect [190 696 204 710] /F 4 /P 3 0 R /AP << /N << /Yes 6 0 R /Off 7 0 R >> >> >>",
            12: "<< /FT /Btn /Ff 49152 /T (Plan) /V /Off /Kids [13 0 R 14 0 R] >>",
            13: "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /AS /Off /Rect [76 656 90 670] /F 4 /P 3 0 R /AP << /N << /Basic 8 0 R /Off 7 0 R >> >> >>",
            14: "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /AS /Off /Rect [156 656 170 670] /F 4 /P 3 0 R /AP << /N << /Pro 8 0 R /Off 7 0 R >> >> >>",
            15: "<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (State) /V (CA) /Opt [(CA) (NY) (TX)] /DA (/Helv 10 Tf 0 g) /Rect [90 612 190 630] /F 4 /P 3 0 R >>",
            16: "<< /T (applicant) /Kids [17 0 R] >>",
            17: "<< /Type /Annot /Subtype /Widget /Parent 16 0 R /FT /Tx /T (email) /V () /DA (/Helv 10 Tf 0 g) /Rect [90 572 290 590] /F 4 /P 3 0 R >>",
            18: "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Submit) /Rect [400 572 480 592] /F 4 /P 3 0 R /MK << /CA (Submit) >> >>",
        ]
        if xfa {
            objects[19] = pdfStream("", "<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"><template/></xdp:xdp>")
        }
        try buildPDF(objects).write(to: url)
    }

    /// The same form printed flat: labels and underscores, no widgets.
    private func makeFlattenedFormPDF(_ url: URL) throws {
        let content = """
            BT /F1 12 Tf 40 740 Td (Name: ______________________) Tj ET
            BT /F1 12 Tf 40 700 Td (Date of birth: ____________) Tj ET
            BT /F1 12 Tf 40 660 Td (Email: _____________________) Tj ET
            """
        try buildPDF([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            4: pdfStream("", content),
            5: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]).write(to: url)
    }

    private func widgetsByName(_ url: URL) throws -> [String: [PDFAnnotation]] {
        let document = try #require(PDFDocument(url: url))
        var out: [String: [PDFAnnotation]] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                out[annotation.fieldName ?? "", default: []].append(annotation)
            }
        }
        return out
    }

    // MARK: - operations schema

    /// `operations.items` must stay a free-form object. Enumerating the
    /// per-operation keys as `properties` breaks schema-constrained decoders
    /// (xAI grok-4.3 emitted `{"op": "replace_text", "slide": 1, "text": …,
    /// "x": 0, "y": 0}` and never `old_string` — 3/3 runs — while the
    /// property-less shape produced correct arguments 3/3). The full
    /// operation shapes must still validate and coerce locally without any
    /// key being dropped or retyped.
    @Test func operationsItemSchemaIsFreeFormAndKeepsEveryEditorKey() throws {
        let schema = try #require(FileEditTool().parameters)
        guard case .object(let root) = schema,
            case .object(let props)? = root["properties"],
            case .object(let operations)? = props["operations"],
            case .object(let items)? = operations["items"]
        else {
            Issue.record("file_edit operations.items missing")
            return
        }
        #expect(items["type"] == .string("object"))
        #expect(items["properties"] == nil, "operations.items must not enumerate properties (constrained-decoder regression)")
        #expect(items["additionalProperties"] == nil)
        if case .string(let description)? = items["description"] {
            for name in DocumentEditService.allOperationNames {
                #expect(description.contains(name), "items description must name \(name)")
            }
        } else {
            Issue.record("operations.items needs a description naming the operations")
        }

        let representativeCalls: [[String: Any]] = [
            ["op": "replace_text", "old_string": "a", "new_string": "b", "replace_all": true, "slide": 2],
            ["op": "insert_paragraph", "text": "t", "after": 3, "style": "Heading 2"],
            ["op": "delete_paragraph", "indices": [2, 3]],
            ["op": "set_table_cell", "table": 1, "row": 2, "column": 3, "text": "x"],
            ["op": "set_cells", "sheet": "Q3", "cells": ["B2": 1, "C2": "=B2*2", "D2": NSNull()]],
            ["op": "insert_rows", "sheet": 1, "at": 2, "count": 3],
            ["op": "add_sheet", "name": "New", "after": "Summary"],
            ["op": "set_slide_text", "slide": 2, "shape": "title", "text": "T"],
            ["op": "reorder_slides", "order": [2, 1]],
            ["op": "rotate_pages", "pages": 1, "degrees": 90],
            ["op": "merge", "files": ["a.pdf"], "after": 0],
            ["op": "fill_form", "fields": ["Name": "Ada", "Agree": true, "Plan": "Pro"]],
            ["op": "add_text", "page": 1, "text": "hi", "x": 10, "y": 20, "size": 12],
            ["op": "highlight", "text": "term", "all": true],
        ]
        let arguments: [String: Any] = ["path": "x.docx", "operations": representativeCalls]
        let validation = SchemaValidator.validate(arguments: arguments, against: schema)
        #expect(validation.isValid, "\(validation.errorMessage ?? "")")
        let coerced = SchemaValidator.coerceArguments(arguments, against: schema) as? [String: Any]
        let coercedOps = coerced?["operations"] as? [[String: Any]]
        #expect(coercedOps?.count == representativeCalls.count)
        for (original, roundTripped) in zip(representativeCalls, coercedOps ?? []) {
            #expect(Set(original.keys) == Set(roundTripped.keys), "coercion dropped keys for \(original["op"] ?? "?")")
            #expect(
                NSDictionary(dictionary: original).isEqual(to: roundTripped),
                "coercion changed values for \(original["op"] ?? "?")"
            )
        }
    }

    @Test func pdfStructureListsFormFieldsWithKindsAndOptions() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intake.pdf")
        try makeAcroFormPDF(url)

        let structure = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: try json(["path": "intake.pdf", "mode": "structure"]))
        #expect(ToolEnvelope.isSuccess(structure), "\(structure)")
        let payload = try #require(EnvelopeAssertions.successPayload(structure))
        let fields = try #require(payload["form_fields"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0["name"] as? String ?? "", $0) })
        #expect(byName["Name"]?["type"] as? String == "text")
        #expect(byName["Agree"]?["type"] as? String == "checkbox")
        #expect(byName["Agree"]?["on_value"] as? String == "Yes")
        #expect(byName["Plan"]?["type"] as? String == "radio")
        #expect(byName["Plan"]?["options"] as? [String] == ["Basic", "Pro"])
        #expect(byName["State"]?["type"] as? String == "choice")
        #expect(byName["State"]?["options"] as? [String] == ["CA", "NY", "TX"])
        #expect(byName["State"]?["value"] as? String == "CA")
        #expect(byName["applicant.email"]?["label"] as? String == "email")
        #expect(byName["Submit"]?["type"] as? String == "button")
        #expect(byName["Submit"]?["fillable"] as? Bool == false)
        // One row per logical field: the radio group's two widgets collapse.
        #expect(fields.count == 6, "\(fields)")
    }

    @Test func pdfFillFormResolvesNamesSetsRadiosAndSurvivesReopen() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intake.pdf")
        try makeAcroFormPDF(url)

        let result = try await edit(
            root,
            [
                "path": "intake.pdf",
                "operations": [
                    [
                        "op": "fill_form",
                        "fields": [
                            "name": "Ada Lovelace",  // case-insensitive
                            "Agree": true,
                            "Plan": "pro",  // radio option, case-insensitive
                            "State": "NY",
                            "email": "ada@example.com",  // short name of applicant.email
                        ],
                    ]
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let applied = (payload["operations_applied"] as? [String]) ?? []
        #expect(applied.joined().contains("Filled 5 form fields"), "\(applied)")
        #expect(applied.joined().contains("Plan=Pro"), "\(applied)")

        // Reopen with PDFKit: values, radio selection, and the saved bytes
        // carry /NeedAppearances so viewers redraw the fields.
        let widgets = try widgetsByName(url)
        #expect(widgets["Name"]?.first?.widgetStringValue == "Ada Lovelace")
        #expect(widgets["Agree"]?.first?.buttonWidgetState == .onState)
        let plan = widgets["Plan"] ?? []
        #expect(plan.count == 2)
        #expect(plan.first { $0.buttonWidgetStateString == "Pro" }?.buttonWidgetState == .onState)
        #expect(plan.first { $0.buttonWidgetStateString == "Basic" }?.buttonWidgetState == .offState)
        #expect(widgets["State"]?.first?.widgetStringValue == "NY")
        #expect(widgets["applicant.email"]?.first?.widgetStringValue == "ada@example.com")
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("/NeedAppearances".utf8)) != nil)
        #expect(bytes.range(of: Data("/V /Pro".utf8)) != nil || bytes.range(of: Data("/V/Pro".utf8)) != nil)
        // The push button was left alone.
        #expect(widgets["Submit"]?.count == 1)

        // Second pass: clearing the radio and unchecking works too.
        let cleared = try await edit(
            root,
            ["path": "intake.pdf", "operations": [["op": "fill_form", "fields": ["Plan": false, "Agree": "no"]]]])
        #expect(ToolEnvelope.isSuccess(cleared), "\(cleared)")
        let after = try widgetsByName(url)
        #expect(after["Agree"]?.first?.buttonWidgetState == .offState)
        #expect((after["Plan"] ?? []).allSatisfy { $0.buttonWidgetState == .offState })
        #expect(after["Name"]?.first?.widgetStringValue == "Ada Lovelace")
    }

    @Test func pdfFillFormRefusalsAreSpecificAndLeaveTheFileUntouched() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intake.pdf")
        try makeAcroFormPDF(url)
        let original = try Data(contentsOf: url)

        func failure(_ fields: [String: Any]) async throws -> String {
            let result = try await edit(root, ["path": "intake.pdf", "operations": [["op": "fill_form", "fields": fields]]])
            #expect(ToolEnvelope.isError(result), "\(result)")
            return EnvelopeAssertions.failureMessage(result) ?? ""
        }

        // Typo: suggestion plus the real field list; nothing else applied
        // even though "Name" was valid.
        let typo = try await failure(["Name": "Ada", "Nmae": "x"])
        #expect(typo.contains("no field named \"Nmae\""), "\(typo)")
        #expect(typo.contains("Did you mean \"Name\""), "\(typo)")
        #expect(try Data(contentsOf: url) == original)

        let badRadio = try await failure(["Plan": "Enterprise"])
        #expect(badRadio.contains("Options: Basic, Pro"), "\(badRadio)")

        let badChoice = try await failure(["State": "ZZ"])
        #expect(badChoice.contains("Options: CA, NY, TX"), "\(badChoice)")

        let button = try await failure(["Submit": true])
        #expect(button.contains("push button"), "\(button)")

        let badBool = try await failure(["Agree": "maybe"])
        #expect(badBool.contains("true/false"), "\(badBool)")
        #expect(badBool.contains("\"Yes\""), "\(badBool)")

        #expect(try Data(contentsOf: url) == original)
    }

    @Test func pdfFormsWithoutWidgetsExplainXFAOrFlattenedLayout() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flat = root.appendingPathComponent("flat.pdf")
        try makeFlattenedFormPDF(flat)

        let flatResult = try await edit(
            root, ["path": "flat.pdf", "operations": [["op": "fill_form", "fields": ["Name": "Ada"]]]])
        #expect(ToolEnvelope.isError(flatResult), "\(flatResult)")
        let flatMessage = EnvelopeAssertions.failureMessage(flatResult) ?? ""
        #expect(flatMessage.contains("no fillable form fields"), "\(flatMessage)")
        #expect(flatMessage.contains("add_text"), "\(flatMessage)")
        #expect(flatMessage.contains("\"Name:\""), "\(flatMessage)")
        #expect(flatMessage.contains("\"Date of birth:\""), "\(flatMessage)")
        // The label baseline is at 740pt; the reported y is the label's
        // bottom edge (baseline minus descent), a few points below it.
        let ys = flatMessage.components(separatedBy: "y=").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        #expect(ys.contains { (730...741).contains($0) }, "\(flatMessage)")

        // The suggested pivot works: add_text lands the value on the page.
        let placed = try await edit(
            root, ["path": "flat.pdf", "operations": [["op": "add_text", "page": 1, "text": "Ada Lovelace", "x": 80, "y": 752]]])
        #expect(ToolEnvelope.isSuccess(placed), "\(placed)")
        let document = try #require(PDFDocument(url: flat))
        #expect(document.page(at: 0)?.annotations.contains { $0.contents == "Ada Lovelace" } == true)

        // Structure mode for a flat PDF has no form_fields key at all.
        let structure = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: try json(["path": "flat.pdf", "mode": "structure"]))
        let payload = try #require(EnvelopeAssertions.successPayload(structure))
        #expect(payload["form_fields"] == nil)

        // XFA-only: PDFKit sees no widgets; say so instead of "no fields".
        let xfaURL = root.appendingPathComponent("xfa.pdf")
        try makeAcroFormPDF(xfaURL, xfa: true)
        // Strip the AcroForm widgets so only the XFA packet remains.
        var raw = String(decoding: try Data(contentsOf: xfaURL), as: UTF8.self)
        raw = raw.replacingOccurrences(of: "/Annots [10 0 R 11 0 R 13 0 R 14 0 R 15 0 R 17 0 R 18 0 R]", with: "/Annots []")
        try Data(raw.utf8).write(to: xfaURL)
        let xfaResult = try await edit(
            root, ["path": "xfa.pdf", "operations": [["op": "fill_form", "fields": ["Name": "Ada"]]]])
        #expect(ToolEnvelope.isError(xfaResult), "\(xfaResult)")
        #expect((EnvelopeAssertions.failureMessage(xfaResult) ?? "").contains("XFA form"), "\(xfaResult)")
    }

    @Test func pdfPageOperationsAndHonestTextRefusal() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scan.pdf")
        try makePDF(url, pages: 3)
        try makePDF(root.appendingPathComponent("extra.pdf"), pages: 1)
        #expect(try pageWidths(url) == [200, 300, 400])

        let result = try await edit(
            root,
            [
                "path": "scan.pdf",
                "operations": [
                    ["op": "reorder_pages", "order": [3, 1, 2]],
                    ["op": "delete_pages", "pages": [2]],
                    ["op": "rotate_pages", "pages": [1], "degrees": 90],
                    ["op": "merge", "files": ["extra.pdf"]],
                    ["op": "add_text", "page": 1, "text": "APPROVED"],
                ],
            ])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        #expect(try pageWidths(url) == [400, 300, 200])
        let document = try #require(PDFDocument(url: url))
        #expect(document.page(at: 0)?.rotation == 90)
        #expect(document.page(at: 0)?.annotations.contains { $0.contents == "APPROVED" } == true)
        // Every PDF save is a whole-file rewrite; the result says so.
        #expect(result.contains("re-saved"), "\(result)")

        let original = try Data(contentsOf: url)
        let refused = try await edit(
            root, ["path": "scan.pdf", "operations": [["op": "replace_text", "old_string": "a", "new_string": "b"]]])
        #expect(ToolEnvelope.isError(refused))
        let textEdit = try await edit(root, ["path": "scan.pdf", "old_string": "a", "new_string": "b"])
        #expect((EnvelopeAssertions.failureMessage(textEdit) ?? "").contains("can't be rewritten"))
        let deleteAll = try await edit(
            root, ["path": "scan.pdf", "operations": [["op": "delete_pages", "pages": [1, 2, 3]]]])
        #expect(ToolEnvelope.isError(deleteAll))
        #expect(try Data(contentsOf: url) == original)
    }
}
