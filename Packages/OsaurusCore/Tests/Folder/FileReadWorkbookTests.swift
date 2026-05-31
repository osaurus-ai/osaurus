//
//  FileReadWorkbookTests.swift
//
//  Verifies workbook visibility stays on the existing folder read tool.
//  The maintainer concern for this lane is prompt/tool-surface size, so
//  these tests pin XLSX introspection without registering workbook-specific
//  default tools.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("File read workbook previews")
struct FileReadWorkbookTests {

    @Test func fileReadReturnsBoundedWorkbookPreview() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let tool = FileReadTool(rootPath: fixture.root, documentRegistry: fixture.registry)
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"workbook.xlsx","max_rows":2,"max_columns":2}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let text = try Self.text(from: result)
        #expect(text.contains("Workbook: workbook.xlsx"))
        #expect(text.contains("Sheets: 2"))
        #expect(text.contains("Sheet 1: Revenue"))
        #expect(text.contains("A1=Month"))
        #expect(text.contains("B2=1200"))
        #expect(text.contains("... 1 more cell(s)"))
        #expect(text.contains("Sheet 2: Notes"))
    }

    @Test func fileReadCanFocusWorkbookSheetAndRowRange() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let tool = FileReadTool(rootPath: fixture.root, documentRegistry: fixture.registry)
        let result = try await tool.execute(
            argumentsJSON:
                #"{"path":"workbook.xlsx","sheet_name":"Notes","start_line":2,"end_line":2,"max_rows":5,"max_columns":3}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let text = try Self.text(from: result)
        #expect(text.contains("Sheet 2: Notes"))
        #expect(text.contains("Preview rows 2-2"))
        #expect(text.contains("row 2: A2=Owner | B2=Finance"))
        #expect(text.contains("Sheet 1: Revenue") == false)
    }

    @Test func fileReadSurfacesWorkbookFormulaRangeAndSecuritySummary() async throws {
        let fixture = try Self.formulaFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let tool = FileReadTool(rootPath: fixture.root, documentRegistry: fixture.registry)
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"formulas.xlsx","max_rows":5,"max_columns":3}"#
        )

        #expect(ToolEnvelope.isSuccess(result))
        let text = try Self.text(from: result)
        #expect(text.contains("Formula cells: 1"))
        #expect(text.contains("Security: inspection=partiallyInspected"))
        #expect(text.contains("active=formula"))
        #expect(text.contains("findings=formula(1)"))
        #expect(text.contains("Merged ranges: A3:B3"))
        #expect(text.contains("B2=2500 [=SUM(B1:B1)]"))
    }

    @Test func fileReadRejectsUnknownWorkbookSheet() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let tool = FileReadTool(rootPath: fixture.root, documentRegistry: fixture.registry)

        await #expect(throws: FolderToolError.self) {
            _ = try await tool.execute(argumentsJSON: #"{"path":"workbook.xlsx","sheet_name":"Missing"}"#)
        }
    }

    @Test func folderCoreToolsDoNotAddWorkbookSpecificDefaults() {
        let names = FolderToolFactory.buildCoreTools(rootPath: Self.tmpRoot()).map(\.name)

        #expect(names.contains("file_read"))
        #expect(names.contains("read_workbook") == false)
        #expect(names.contains("read_workbook_cell") == false)
        #expect(names.contains("write_workbook") == false)
    }

    private struct Fixture {
        let root: URL
        let registry: DocumentFormatRegistry
    }

    private static func fixture() async throws -> Fixture {
        let root = tmpRoot()
        let registry = DocumentFormatRegistry()
        registry.register(adapter: XLSXAdapter())

        try await XLSXEmitter().emit(
            document(workbook: workbook()),
            to: root.appendingPathComponent("workbook.xlsx")
        )
        return Fixture(root: root, registry: registry)
    }

    private static func formulaFixture() throws -> Fixture {
        let root = tmpRoot()
        let registry = DocumentFormatRegistry()
        registry.register(adapter: XLSXAdapter())

        try OpenXMLZipFixture.write(
            entries: formulaWorkbookEntries(),
            to: root.appendingPathComponent("formulas.xlsx")
        )
        return Fixture(root: root, registry: registry)
    }

    private static func formulaWorkbookEntries() -> [(String, Data)] {
        [
            (
                "[Content_Types].xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                      <Default Extension="xml" ContentType="application/xml"/>
                      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                      <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
                      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                    </Types>
                    """.utf8
                )
            ),
            (
                "_rels/.rels",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
                    </Relationships>
                    """.utf8
                )
            ),
            (
                "xl/workbook.xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                      <sheets>
                        <sheet name="Formulas" sheetId="1" r:id="rId1"/>
                      </sheets>
                    </workbook>
                    """.utf8
                )
            ),
            (
                "xl/_rels/workbook.xml.rels",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                    </Relationships>
                    """.utf8
                )
            ),
            (
                "xl/sharedStrings.xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
                      <si><t>Metric</t></si>
                      <si><t>Total</t></si>
                    </sst>
                    """.utf8
                )
            ),
            (
                "xl/worksheets/sheet1.xml",
                Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                      <sheetData>
                        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>2500</v></c></row>
                        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><f>SUM(B1:B1)</f><v>2500</v></c></row>
                      </sheetData>
                      <mergeCells count="1"><mergeCell ref="A3:B3"/></mergeCells>
                    </worksheet>
                    """.utf8
                )
            ),
        ]
    }

    private static func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-read-workbook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func text(from result: String) throws -> String {
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        return try #require(payload["text"] as? String)
    }

    private static func document(workbook: Workbook) -> StructuredDocument {
        StructuredDocument(
            formatId: "xlsx",
            filename: "workbook.xlsx",
            fileSize: 0,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            security: .notInspected(
                formatId: "xlsx",
                fileExtension: "xlsx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: ""
        )
    }

    private static func workbook() -> Workbook {
        Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Revenue",
                    index: 0,
                    rows: [
                        row(
                            number: 1,
                            sheetName: "Revenue",
                            sheetIndex: 0,
                            cells: [
                                cell(
                                    "A1",
                                    row: 1,
                                    column: 1,
                                    value: .string("Month"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell(
                                    "B1",
                                    row: 1,
                                    column: 2,
                                    value: .string("Amount"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell(
                                    "C1",
                                    row: 1,
                                    column: 3,
                                    value: .string("Approved"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                            ]
                        ),
                        row(
                            number: 2,
                            sheetName: "Revenue",
                            sheetIndex: 0,
                            cells: [
                                cell(
                                    "A2",
                                    row: 2,
                                    column: 1,
                                    value: .string("January"),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell(
                                    "B2",
                                    row: 2,
                                    column: 2,
                                    value: .number(1200),
                                    sheetName: "Revenue",
                                    sheetIndex: 0
                                ),
                                cell("C2", row: 2, column: 3, value: .bool(true), sheetName: "Revenue", sheetIndex: 0),
                            ]
                        ),
                    ],
                    mergedRanges: [Workbook.CellRange(reference: "A5:B5")],
                    anchor: sheetAnchor(name: "Revenue", index: 0)
                ),
                Workbook.Sheet(
                    name: "Notes",
                    index: 1,
                    rows: [
                        row(
                            number: 1,
                            sheetName: "Notes",
                            sheetIndex: 1,
                            cells: [
                                cell(
                                    "A1",
                                    row: 1,
                                    column: 1,
                                    value: .string("Label"),
                                    sheetName: "Notes",
                                    sheetIndex: 1
                                ),
                                cell(
                                    "B1",
                                    row: 1,
                                    column: 2,
                                    value: .string("Value"),
                                    sheetName: "Notes",
                                    sheetIndex: 1
                                ),
                            ]
                        ),
                        row(
                            number: 2,
                            sheetName: "Notes",
                            sheetIndex: 1,
                            cells: [
                                cell(
                                    "A2",
                                    row: 2,
                                    column: 1,
                                    value: .string("Owner"),
                                    sheetName: "Notes",
                                    sheetIndex: 1
                                ),
                                cell(
                                    "B2",
                                    row: 2,
                                    column: 2,
                                    value: .string("Finance"),
                                    sheetName: "Notes",
                                    sheetIndex: 1
                                ),
                            ]
                        ),
                    ],
                    anchor: sheetAnchor(name: "Notes", index: 1)
                ),
            ]
        )
    }

    private static func row(
        number: Int,
        sheetName: String,
        sheetIndex: Int,
        cells: [Workbook.Cell]
    ) -> Workbook.Row {
        Workbook.Row(
            number: number,
            cells: cells,
            anchor: DocumentAnchor(
                kind: .row,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .row, index: number - 1),
                ],
                sourceRange: DocumentSourceRange(
                    start: DocumentSourceLocation(sheetIndex: sheetIndex, sheetName: sheetName, rowIndex: number - 1)
                ),
                label: "\(sheetName) row \(number)"
            )
        )
    }

    private static func cell(
        _ reference: String,
        row: Int,
        column: Int,
        value: Workbook.CellValue,
        sheetName: String,
        sheetIndex: Int
    ) -> Workbook.Cell {
        Workbook.Cell(
            reference: reference,
            rowNumber: row,
            columnNumber: column,
            value: value,
            anchor: DocumentAnchor(
                kind: .cell,
                path: [
                    .init(kind: .document),
                    .init(kind: .sheet, identifier: sheetName, index: sheetIndex),
                    .init(kind: .cell, identifier: reference),
                ],
                sourceRange: DocumentSourceRange(
                    start: .cell(sheetName: sheetName, rowIndex: row - 1, columnIndex: column - 1)
                ),
                label: "\(sheetName)!\(reference)"
            )
        )
    }

    private static func sheetAnchor(name: String, index: Int) -> DocumentAnchor {
        DocumentAnchor(
            kind: .sheet,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: name, index: index),
            ],
            sourceRange: DocumentSourceRange(
                start: DocumentSourceLocation(sheetIndex: index, sheetName: name)
            ),
            label: name,
            metadata: ["sheetIndex": "\(index)"]
        )
    }
}
