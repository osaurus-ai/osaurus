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
        #expect((EnvelopeAssertions.failureMessage(missing) ?? "").contains("Nothing was changed"))

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

        // Newlines in the replacement become soft line breaks in Word, and
        // control characters never reach the XML.
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
        #expect(xml.contains("<w:t>Line one.</w:t><w:br></w:br><w:t>Line two.</w:t>") || xml.contains("<w:t>Line one.</w:t><w:br/><w:t>Line two.</w:t>"), "\(xml)")
        #expect(!xml.unicodeScalars.contains("\u{0}"))
        #expect(xml.contains("coffee menu"), "\(xml)")
        // Tab and break still present, untouched.
        #expect(xml.contains("<w:t>Name</w:t><w:tab/><w:t>Score</w:t>") || xml.contains("<w:t>Name</w:t><w:tab></w:tab><w:t>Score</w:t>"), "\(xml)")
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
