//
//  PDFTableDetector.swift
//  osaurus
//
//  Recovers simple text-layer tables from PDF glyph geometry. PDFs do not
//  encode rows or columns, so this stays a deterministic heuristic pipeline:
//  cluster glyphs into visual rows, split rows on large horizontal gaps, then
//  group similarly aligned rows into tables.
//

import CoreGraphics
import Foundation

struct PDFTableDetector {
    struct Glyph: Equatable {
        let pageIndex: Int
        let characterIndex: Int
        let text: String
        let bounds: CGRect

        var midY: CGFloat { bounds.midY }
    }

    struct Row: Equatable {
        let pageIndex: Int
        let glyphs: [Glyph]
        let bounds: CGRect
        let cells: [Cell]

        var characterRange: Range<Int> {
            let indexes = glyphs.map(\.characterIndex)
            guard let min = indexes.min(), let max = indexes.max() else { return 0 ..< 0 }
            return min ..< (max + 1)
        }
    }

    struct Cell: Equatable {
        let pageIndex: Int
        let rowIndex: Int
        let columnIndex: Int
        let glyphs: [Glyph]
        let text: String
        let bounds: CGRect

        var characterRange: Range<Int> {
            let indexes = glyphs.map(\.characterIndex)
            guard let min = indexes.min(), let max = indexes.max() else { return 0 ..< 0 }
            return min ..< (max + 1)
        }
    }

    struct Table: Equatable {
        let pageIndex: Int
        let index: Int
        let rows: [Row]
        let bounds: CGRect

        var characterRange: Range<Int> {
            let indexes = rows.flatMap(\.glyphs).map(\.characterIndex)
            guard let min = indexes.min(), let max = indexes.max() else { return 0 ..< 0 }
            return min ..< (max + 1)
        }
    }

    static func detectTables(glyphs: [Glyph], pageText: String? = nil) throws -> [Table] {
        try Task.checkCancellation()
        let visualRows = try rows(from: glyphs)
        try Task.checkCancellation()
        let detectedTables = try tables(from: visualRows)
        guard let pageText else { return detectedTables }
        return try reconcileCellText(
            in: detectedTables,
            visualRows: visualRows,
            pageText: pageText
        )
    }

    static func rows(from glyphs: [Glyph]) throws -> [Row] {
        try Task.checkCancellation()
        let visibleGlyphs =
            glyphs
            .filter { !$0.text.isNewline && !$0.bounds.isNull && !$0.bounds.isEmpty }
            .sorted {
                if abs($0.midY - $1.midY) > 0.5 {
                    return $0.midY > $1.midY
                }
                return $0.bounds.minX < $1.bounds.minX
            }
        try Task.checkCancellation()
        guard !visibleGlyphs.isEmpty else { return [] }

        let tolerance = max(3, median(visibleGlyphs.map(\.bounds.height)) * 0.65)
        var buckets: [[Glyph]] = []
        var current: [Glyph] = []
        var currentMidY = visibleGlyphs[0].midY

        for glyph in visibleGlyphs {
            try Task.checkCancellation()
            if current.isEmpty || abs(glyph.midY - currentMidY) <= tolerance {
                current.append(glyph)
                currentMidY = averageMidY(current)
            } else {
                buckets.append(current)
                current = [glyph]
                currentMidY = glyph.midY
            }
        }
        if !current.isEmpty {
            buckets.append(current)
        }

        var rows: [Row] = []
        rows.reserveCapacity(buckets.count)
        for bucket in buckets {
            try Task.checkCancellation()
            let ordered = bucket.sorted {
                if abs($0.bounds.minX - $1.bounds.minX) > 0.5 {
                    return $0.bounds.minX < $1.bounds.minX
                }
                return $0.characterIndex < $1.characterIndex
            }
            try Task.checkCancellation()
            guard let pageIndex = ordered.first?.pageIndex else { continue }
            rows.append(
                Row(
                    pageIndex: pageIndex,
                    glyphs: ordered,
                    bounds: unionBounds(ordered.map(\.bounds)),
                    cells: try cells(from: ordered)
                )
            )
        }
        return rows
    }

    static func cells(from glyphs: [Glyph]) throws -> [Cell] {
        try Task.checkCancellation()
        guard let pageIndex = glyphs.first?.pageIndex else { return [] }
        let medianWidth = median(glyphs.map(\.bounds.width).filter { $0 > 0 })
        let gapThreshold = max(8, medianWidth * 2.2)
        var groups: [[Glyph]] = []
        var current: [Glyph] = []
        var previousTextGlyph: Glyph?

        for glyph in glyphs {
            try Task.checkCancellation()
            if glyph.text.isWhitespace {
                let isWideDelimiter =
                    previousTextGlyph.map { glyph.bounds.minX - $0.bounds.minX > gapThreshold } ?? false
                if isWideDelimiter, !current.isEmpty {
                    groups.append(current)
                    current = []
                    previousTextGlyph = nil
                }
                continue
            }

            if let previous = previousTextGlyph {
                let xAdvance = glyph.bounds.minX - previous.bounds.minX
                if xAdvance > gapThreshold + medianWidth, !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            }
            current.append(glyph)
            previousTextGlyph = glyph
        }
        if !current.isEmpty {
            groups.append(current)
        }

        var cells: [Cell] = []
        cells.reserveCapacity(groups.count)
        for (columnIndex, group) in groups.enumerated() {
            try Task.checkCancellation()
            let text = normalizeCellText(group.map(\.text).joined())
            guard !text.isEmpty else { continue }
            cells.append(
                Cell(
                    pageIndex: pageIndex,
                    rowIndex: 0,
                    columnIndex: columnIndex,
                    glyphs: group,
                    text: text,
                    bounds: unionBounds(group.map(\.bounds))
                )
            )
        }
        return cells
    }

    static func tables(from rows: [Row]) throws -> [Table] {
        try Task.checkCancellation()
        let candidates = rows.filter { $0.cells.count >= 2 }
        guard !candidates.isEmpty else { return [] }

        var groups: [[Row]] = []
        var current: [Row] = []

        for row in candidates {
            try Task.checkCancellation()
            if let last = current.last, canGroup(last, row) {
                current.append(row)
            } else {
                if current.count >= 2 {
                    groups.append(current)
                }
                current = [row]
            }
        }
        if current.count >= 2 {
            groups.append(current)
        }

        var tables: [Table] = []
        tables.reserveCapacity(groups.count)
        for (tableIndex, group) in groups.enumerated() {
            try Task.checkCancellation()
            var tableRows: [Row] = []
            tableRows.reserveCapacity(group.count)
            for (rowIndex, row) in group.enumerated() {
                try Task.checkCancellation()
                var cells: [Cell] = []
                cells.reserveCapacity(row.cells.count)
                for (columnIndex, cell) in row.cells.enumerated() {
                    try Task.checkCancellation()
                    cells.append(
                        Cell(
                            pageIndex: cell.pageIndex,
                            rowIndex: rowIndex,
                            columnIndex: columnIndex,
                            glyphs: cell.glyphs,
                            text: cell.text,
                            bounds: cell.bounds
                        )
                    )
                }
                tableRows.append(
                    Row(
                        pageIndex: row.pageIndex,
                        glyphs: row.glyphs,
                        bounds: row.bounds,
                        cells: cells
                    )
                )
            }
            tables.append(
                Table(
                    pageIndex: group[0].pageIndex,
                    index: tableIndex,
                    rows: tableRows,
                    bounds: unionBounds(group.map(\.bounds))
                )
            )
        }
        return tables
    }

    private static func canGroup(_ upper: Row, _ lower: Row) -> Bool {
        guard upper.pageIndex == lower.pageIndex, upper.cells.count == lower.cells.count else {
            return false
        }

        let rowHeight = max(upper.bounds.height, lower.bounds.height, 1)
        let verticalGap = max(0, upper.bounds.minY - lower.bounds.maxY)
        guard verticalGap <= max(36, rowHeight * 3.5) else { return false }

        let tolerance = max(12, median((upper.cells + lower.cells).map(\.bounds.width)) * 0.2)
        for (left, right) in zip(upper.cells, lower.cells) {
            guard abs(left.bounds.minX - right.bounds.minX) <= tolerance else {
                return false
            }
        }
        return true
    }

    private static func reconcileCellText(
        in tables: [Table],
        visualRows: [Row],
        pageText: String
    ) throws -> [Table] {
        try Task.checkCancellation()
        let lineTokens =
            pageText
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }
        guard !lineTokens.isEmpty else { return tables }

        let rowOrderByKey = Dictionary(
            uniqueKeysWithValues: visualRows.enumerated().map { order, row in
                (rowKey(row), order)
            }
        )

        var reconciledTables: [Table] = []
        reconciledTables.reserveCapacity(tables.count)
        for table in tables {
            try Task.checkCancellation()
            var rows: [Row] = []
            rows.reserveCapacity(table.rows.count)
            for row in table.rows {
                try Task.checkCancellation()
                guard let order = rowOrderByKey[rowKey(row)],
                    order < lineTokens.count,
                    lineTokens[order].count == row.cells.count
                else {
                    rows.append(row)
                    continue
                }

                let cells = zip(row.cells, lineTokens[order]).map { cell, text in
                    Cell(
                        pageIndex: cell.pageIndex,
                        rowIndex: cell.rowIndex,
                        columnIndex: cell.columnIndex,
                        glyphs: cell.glyphs,
                        text: text,
                        bounds: cell.bounds
                    )
                }
                rows.append(
                    Row(
                        pageIndex: row.pageIndex,
                        glyphs: row.glyphs,
                        bounds: row.bounds,
                        cells: cells
                    )
                )
            }
            reconciledTables.append(
                Table(
                    pageIndex: table.pageIndex,
                    index: table.index,
                    rows: rows,
                    bounds: table.bounds
                )
            )
        }
        return reconciledTables
    }

    private static func rowKey(_ row: Row) -> String {
        let range = row.characterRange
        return "\(row.pageIndex):\(range.lowerBound):\(range.upperBound)"
    }

    private static func averageMidY(_ glyphs: [Glyph]) -> CGFloat {
        guard !glyphs.isEmpty else { return 0 }
        return glyphs.reduce(CGFloat(0)) { $0 + $1.midY } / CGFloat(glyphs.count)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func normalizeCellText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func unionBounds(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { partial, rect in
            partial.isNull ? rect : partial.union(rect)
        }
    }
}

private extension String {
    var isNewline: Bool {
        self == "\n" || self == "\r" || self == "\u{2028}" || self == "\u{2029}"
    }

    var isWhitespace: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
