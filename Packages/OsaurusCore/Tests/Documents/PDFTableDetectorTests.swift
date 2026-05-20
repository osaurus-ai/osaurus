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
    @Test func rows_clusterGlyphsByVisualYAndSplitCellsOnWideGaps() {
        let glyphs = Self.gridGlyphs([
            ["Name", "Amount", "Status"],
            ["Alice", "1200", "Paid"],
        ])

        let rows = PDFTableDetector.rows(from: glyphs)

        #expect(rows.count == 2)
        #expect(rows[0].cells.map(\.text) == ["Name", "Amount", "Status"])
        #expect(rows[1].cells.map(\.text) == ["Alice", "1200", "Paid"])
    }

    @Test func detectTables_groupsAlignedRowsIntoOneTable() {
        let glyphs = Self.gridGlyphs([
            ["Quarter", "Revenue"],
            ["Q1", "1200"],
            ["Q2", "1800"],
        ])

        let tables = PDFTableDetector.detectTables(glyphs: glyphs)

        #expect(tables.count == 1)
        #expect(tables[0].rows.count == 3)
        #expect(tables[0].rows[2].cells.map(\.text) == ["Q2", "1800"])
        #expect(tables[0].rows[2].cells.map(\.rowIndex) == [2, 2])
        #expect(tables[0].rows[2].cells.map(\.columnIndex) == [0, 1])
    }

    @Test func detectTables_ignoresSingleRowCandidates() {
        let glyphs = Self.gridGlyphs([["Only", "One", "Row"]])

        #expect(PDFTableDetector.detectTables(glyphs: glyphs).isEmpty)
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
