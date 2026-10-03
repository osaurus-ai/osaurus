//
//  PDFTableDetectorTests.swift
//  osaurusTests
//
//  Pins the pure geometry stages separately from PDFKit so table heuristics can
//  be tuned without needing binary PDF fixtures for every edge case.
//

import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite("PDFTableDetector")
struct PDFTableDetectorTests {
    @Test func rows_clusterGlyphsByVisualYAndSplitCellsOnWideGaps() throws {
        let glyphs = Self.gridGlyphs([
            ["Name", "Amount", "Status"],
            ["Alice", "1200", "Paid"],
        ])

        let rows = try PDFTableDetector.rows(from: glyphs)

        #expect(rows.count == 2)
        #expect(rows[0].cells.map(\.text) == ["Name", "Amount", "Status"])
        #expect(rows[1].cells.map(\.text) == ["Alice", "1200", "Paid"])
    }

    @Test func detectTables_groupsAlignedRowsIntoOneTable() throws {
        let glyphs = Self.gridGlyphs([
            ["Quarter", "Revenue"],
            ["Q1", "1200"],
            ["Q2", "1800"],
        ])

        let tables = try PDFTableDetector.detectTables(glyphs: glyphs)

        #expect(tables.count == 1)
        #expect(tables[0].rows.count == 3)
        #expect(tables[0].rows[2].cells.map(\.text) == ["Q2", "1800"])
        #expect(tables[0].rows[2].cells.map(\.rowIndex) == [2, 2])
        #expect(tables[0].rows[2].cells.map(\.columnIndex) == [0, 1])
    }

    @Test func detectTables_ignoresSingleRowCandidates() throws {
        let glyphs = Self.gridGlyphs([["Only", "One", "Row"]])

        #expect(try PDFTableDetector.detectTables(glyphs: glyphs).isEmpty)
    }

    @Test func detectTables_preservesVisualPairsForColumnOrderedSourceText() throws {
        let glyphs = Self.gridGlyphs([
            ["10", "101"],
            ["11", "202"],
        ])
        let geometric = try PDFTableDetector.detectTables(glyphs: glyphs)

        // The content stream lists the label column before the value column.
        // Matching token counts must not turn the second label into a value.
        let reconciled = try PDFTableDetector.detectTables(
            glyphs: glyphs,
            pageText: "10 11\n101 202"
        )

        #expect(reconciled == geometric)
        #expect(reconciled.first?.rows.map { $0.cells.map(\.text) } == [
            ["10", "101"],
            ["11", "202"],
        ])
    }

    @Test func detectTables_preservesVisualRowsForReversedSourceLines() throws {
        let glyphs = Self.gridGlyphs([
            ["First", "101"],
            ["Second", "202"],
        ])
        let geometric = try PDFTableDetector.detectTables(glyphs: glyphs)

        let reconciled = try PDFTableDetector.detectTables(
            glyphs: glyphs,
            pageText: "Second 202\nFirst 101"
        )

        #expect(reconciled == geometric)
    }

    @Test func detectTables_acceptsMatchingSourceWithWhitespaceSeparators() throws {
        let glyphs = Self.gridGlyphs([
            ["10", "101"],
            ["11", "202"],
        ])
        let geometric = try PDFTableDetector.detectTables(glyphs: glyphs)

        let reconciled = try PDFTableDetector.detectTables(
            glyphs: glyphs,
            pageText: " \t10\u{00A0}101\r\n\t11   202 \n"
        )

        // Includes bounds, glyphs, source character ranges and row/column IDs.
        #expect(reconciled == geometric)
    }

    @Test(arguments: [
        "ALPHA -101\nBETA 202",
        "ALPHA 1.01\nBETA 202",
        "ALPHA 102\nBETA 202",
        "alpha 101\nBETA 202",
    ])
    func detectTables_preservesWholeRowWhenAnyCellCharactersDiffer(pageText: String) throws {
        let glyphs = Self.gridGlyphs([
            ["ALPHA", "101"],
            ["BETA", "202"],
        ])
        let geometric = try PDFTableDetector.detectTables(glyphs: glyphs)

        let reconciled = try PDFTableDetector.detectTables(glyphs: glyphs, pageText: pageText)

        // Sign, punctuation, digits and case are identity, not whitespace.
        // A matching neighbor never justifies overwriting a mismatched cell.
        #expect(reconciled == geometric)
    }

    private static func gridGlyphs(_ rows: [[String]]) -> [PDFTableDetector.Glyph] {
        var glyphs: [PDFTableDetector.Glyph] = []
        var index = 0
        let rowHeight: CGFloat = 12
        let cellWidth: CGFloat = 90
        let charWidth: CGFloat = 6

        for (rowIndex, row) in rows.enumerated() {
            let baseline = CGFloat(200 - rowIndex * 24)
            for (columnIndex, cell) in row.enumerated() {
                let cellOriginX = CGFloat(40) + CGFloat(columnIndex) * cellWidth
                var x = cellOriginX
                for character in cell.map(String.init) {
                    glyphs.append(
                        PDFTableDetector.Glyph(
                            pageIndex: 0,
                            characterIndex: index,
                            text: character,
                            bounds: CGRect(
                                x: x,
                                y: baseline,
                                width: charWidth,
                                height: rowHeight
                            )
                        )
                    )
                    index += 1
                    x += charWidth + 1
                }
            }
        }
        return glyphs
    }
}
