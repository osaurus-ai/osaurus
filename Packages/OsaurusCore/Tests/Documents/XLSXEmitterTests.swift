//
//  XLSXEmitterTests.swift
//  osaurusTests
//
//  Covers the write-side XLSX groundwork by emitting an in-memory workbook,
//  parsing the generated package through the stacked XLSX reader, and checking
//  that supported scalar cell types survive the round trip.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("XLSXEmitter")
struct XLSXEmitterTests {

    @Test func canEmit_requiresXLSXWorkbookRepresentation() {
        let emitter = XLSXEmitter()
        let workbook = Self.makeWorkbook()

        #expect(emitter.canEmit(Self.document(workbook: workbook)))
        #expect(emitter.canEmit(Self.document(workbook: workbook, formatId: "plaintext")) == false)
    }

    @Test func emit_roundTripsScalarWorkbookThroughXLSXAdapter() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await XLSXEmitter().emit(Self.document(workbook: Self.makeWorkbook()), to: url)

        let parsed = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        let workbook = try #require(parsed.representation.underlying as? Workbook)
        let revenue = try #require(workbook.sheets.first { $0.name == "Revenue" })
        let notes = try #require(workbook.sheets.first { $0.name == "Notes" })

        #expect(parsed.formatId == "xlsx")
        #expect(workbook.sheets.map(\.name) == ["Revenue", "Notes"])
        #expect(revenue.cell("A1")?.value == .string("Month"))
        #expect(revenue.cell("B2")?.value == .number(1200))
        #expect(revenue.cell("B3")?.value == .number(1300.5))
        #expect(revenue.cell("C2")?.value == .bool(true))
        #expect(revenue.cell("C3")?.value == .bool(false))
        #expect(notes.cell("A1")?.value == .string(" padded "))
        #expect(notes.cell("B1")?.value == .string("January"))
        #expect(notes.cell("C1")?.value == .string("5 < 7 & \"ok\""))
        #expect(revenue.mergedRanges.map(\.reference) == ["A5:B5"])
        #expect(workbook.sharedStrings.filter { $0 == "January" }.count == 1)
        #expect(parsed.textFallback.contains("January\t1200\tTRUE"))
        #expect(parsed.textFallback.contains("5 < 7 & \"ok\""))
    }

    @Test func emit_rejectsFormulaCellsWithoutFlatteningThem() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            try await XLSXEmitter().emit(
                Self.document(workbook: Self.makeWorkbook(includeFormula: true)),
                to: url
            )
        }
    }

    @Test func emit_rejectsWorkbookWithoutRenderableCells() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await Self.expectEmptyContent {
            try await XLSXEmitter().emit(
                Self.document(workbook: Self.makeEmptyWorkbook()),
                to: url
            )
        }
    }

    @Test func emit_rejectsRowsContainingOnlyEmptyOrWhitespaceCells() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        await Self.expectEmptyContent {
            try await XLSXEmitter().emit(
                Self.document(workbook: Self.makeWorkbookWithOnlyEmptyCells()),
                to: url
            )
        }
    }

    @Test func emit_keepsFormulaLookingTextInert() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await XLSXEmitter().emit(
            Self.document(
                workbook: Self.singleCellWorkbook(value: .string("=HYPERLINK(\"https://example.com\")"))
            ),
            to: url
        )

        let parsed = try await XLSXAdapter().parse(url: url, sizeLimit: 0)
        let workbook = try #require(parsed.representation.underlying as? Workbook)
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.cell("A1")?.value == .string("=HYPERLINK(\"https://example.com\")"))
        #expect(sheet.cell("A1")?.formula == nil)
    }

    @Test func emit_rejectsStringsBeyondExcelCellLimit() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let overlong = String(repeating: "a", count: 32_768)

        await #expect(throws: DocumentAdapterError.self) {
            try await XLSXEmitter().emit(
                Self.document(workbook: Self.singleCellWorkbook(value: .string(overlong))),
                to: url
            )
        }
    }

    @Test func bootstrap_registersXLSXEmitter() {
        let registry = DocumentFormatRegistry()

        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)

        let emitter = registry.emitter(for: Self.document(workbook: Self.makeWorkbook()))
        #expect(emitter?.formatId == "xlsx")
    }

    // MARK: - Fixtures

    private static func document(workbook: Workbook, formatId: String = "xlsx") -> StructuredDocument {
        StructuredDocument(
            formatId: formatId,
            filename: "workbook.\(formatId)",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: workbook
            ),
            security: .notInspected(
                formatId: formatId,
                fileExtension: formatId,
                sourceTrust: .generatedArtifact
            ),
            textFallback: ""
        )
    }

    private static func makeWorkbook(includeFormula: Bool = false) -> Workbook {
        let revenueRows = [
            row(
                number: 1,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A1", row: 1, column: 1, value: .string("Month"), sheetName: "Revenue", sheetIndex: 0),
                    cell("B1", row: 1, column: 2, value: .string("Amount"), sheetName: "Revenue", sheetIndex: 0),
                    cell("C1", row: 1, column: 3, value: .string("Approved"), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
            row(
                number: 2,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A2", row: 2, column: 1, value: .string("January"), sheetName: "Revenue", sheetIndex: 0),
                    cell("B2", row: 2, column: 2, value: .number(1200), sheetName: "Revenue", sheetIndex: 0),
                    cell("C2", row: 2, column: 3, value: .bool(true), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
            row(
                number: 3,
                sheetName: "Revenue",
                sheetIndex: 0,
                cells: [
                    cell("A3", row: 3, column: 1, value: .string("February"), sheetName: "Revenue", sheetIndex: 0),
                    cell(
                        "B3",
                        row: 3,
                        column: 2,
                        value: .number(1300.5),
                        formula: includeFormula ? "SUM(B2:B3)" : nil,
                        sheetName: "Revenue",
                        sheetIndex: 0
                    ),
                    cell("C3", row: 3, column: 3, value: .bool(false), sheetName: "Revenue", sheetIndex: 0),
                ]
            ),
        ]
        let notesRows = [
            row(
                number: 1,
                sheetName: "Notes",
                sheetIndex: 1,
                cells: [
                    cell("A1", row: 1, column: 1, value: .string(" padded "), sheetName: "Notes", sheetIndex: 1),
                    cell("B1", row: 1, column: 2, value: .string("January"), sheetName: "Notes", sheetIndex: 1),
                    cell("C1", row: 1, column: 3, value: .string("5 < 7 & \"ok\""), sheetName: "Notes", sheetIndex: 1),
                ]
            )
        ]

        return Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Revenue",
                    index: 0,
                    rows: revenueRows,
                    mergedRanges: [Workbook.CellRange(reference: "A5:B5")],
                    anchor: sheetAnchor(name: "Revenue", index: 0)
                ),
                Workbook.Sheet(
                    name: "Notes",
                    index: 1,
                    rows: notesRows,
                    anchor: sheetAnchor(name: "Notes", index: 1)
                ),
            ]
        )
    }

    private static func makeEmptyWorkbook() -> Workbook {
        Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Empty",
                    index: 0,
                    rows: [],
                    anchor: sheetAnchor(name: "Empty", index: 0)
                )
            ]
        )
    }

    private static func makeWorkbookWithOnlyEmptyCells() -> Workbook {
        let rows = [
            row(
                number: 1,
                sheetName: "Empty",
                sheetIndex: 0,
                cells: [
                    cell("A1", row: 1, column: 1, value: .empty, sheetName: "Empty", sheetIndex: 0),
                    cell("B1", row: 1, column: 2, value: .string("   "), sheetName: "Empty", sheetIndex: 0),
                ]
            )
        ]
        return Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Empty",
                    index: 0,
                    rows: rows,
                    anchor: sheetAnchor(name: "Empty", index: 0)
                )
            ]
        )
    }

    private static func singleCellWorkbook(value: Workbook.CellValue) -> Workbook {
        Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Sheet1",
                    index: 0,
                    rows: [
                        row(
                            number: 1,
                            sheetName: "Sheet1",
                            sheetIndex: 0,
                            cells: [
                                cell(
                                    "A1",
                                    row: 1,
                                    column: 1,
                                    value: value,
                                    sheetName: "Sheet1",
                                    sheetIndex: 0
                                )
                            ]
                        )
                    ],
                    anchor: sheetAnchor(name: "Sheet1", index: 0)
                )
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
        formula: String? = nil,
        sheetName: String,
        sheetIndex: Int
    ) -> Workbook.Cell {
        Workbook.Cell(
            reference: reference,
            rowNumber: row,
            columnNumber: column,
            value: value,
            formula: formula,
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

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-emitted.xlsx")
    }

    private static func expectEmptyContent(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected XLSX emitter to reject workbook with no renderable content")
        } catch DocumentAdapterError.emptyContent {
            return
        } catch {
            Issue.record("Expected emptyContent, received \(error)")
        }
    }
}

private extension Workbook.Sheet {
    func cell(_ reference: String) -> Workbook.Cell? {
        rows.flatMap(\.cells).first { $0.reference == reference }
    }
}
