//
//  PDFDocumentRepresentation.swift
//  osaurus
//
//  Typed PDF representation for text-layer extraction. PDF files do not carry
//  table semantics, so tables here are deliberately provenance-heavy heuristic
//  detections: callers can cite the page, bounding box, and source character
//  span instead of treating the result as an author-declared structure.
//

import Foundation

/// PDF-native parse output carried by `StructuredDocument` while the legacy
/// attachment path keeps using the plain text fallback.
public struct PDFDocumentRepresentation: StructuredRepresentation, Codable, Equatable, Sendable {
    public let pages: [PDFPageRepresentation]

    public init(pages: [PDFPageRepresentation]) {
        self.pages = pages
    }
}

/// A page keeps its recovered text and any layout-derived tables together so
/// consumers can decide whether to trust prose order, table geometry, or both.
public struct PDFPageRepresentation: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let text: String
    public let bounds: DocumentBoundingBox?
    public let tables: [PDFTable]
    public let anchor: DocumentAnchor

    public init(
        pageIndex: Int,
        text: String,
        bounds: DocumentBoundingBox? = nil,
        tables: [PDFTable] = [],
        anchor: DocumentAnchor
    ) {
        precondition(pageIndex >= 0, "PDF page index must be non-negative")
        self.pageIndex = pageIndex
        self.text = text
        self.bounds = bounds
        self.tables = tables
        self.anchor = anchor
    }
}

/// A heuristic table extracted from glyph geometry. Row and cell anchors keep
/// enough source identity for audit/debug even when a complex PDF layout is
/// later tuned into a different detection.
public struct PDFTable: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let index: Int
    public let rows: [PDFTableRow]
    public let bounds: DocumentBoundingBox
    public let anchor: DocumentAnchor

    public var columnCount: Int {
        rows.map(\.cells.count).max() ?? 0
    }

    public init(
        pageIndex: Int,
        index: Int,
        rows: [PDFTableRow],
        bounds: DocumentBoundingBox,
        anchor: DocumentAnchor
    ) {
        precondition(pageIndex >= 0, "PDF table page index must be non-negative")
        precondition(index >= 0, "PDF table index must be non-negative")
        self.pageIndex = pageIndex
        self.index = index
        self.rows = rows
        self.bounds = bounds
        self.anchor = anchor
    }
}

public struct PDFTableRow: Codable, Equatable, Sendable {
    public let index: Int
    public let cells: [PDFTableCell]
    public let bounds: DocumentBoundingBox
    public let anchor: DocumentAnchor

    public init(
        index: Int,
        cells: [PDFTableCell],
        bounds: DocumentBoundingBox,
        anchor: DocumentAnchor
    ) {
        precondition(index >= 0, "PDF table row index must be non-negative")
        self.index = index
        self.cells = cells
        self.bounds = bounds
        self.anchor = anchor
    }
}

public struct PDFTableCell: Codable, Equatable, Sendable {
    public let rowIndex: Int
    public let columnIndex: Int
    public let text: String
    public let bounds: DocumentBoundingBox
    public let anchor: DocumentAnchor

    public init(
        rowIndex: Int,
        columnIndex: Int,
        text: String,
        bounds: DocumentBoundingBox,
        anchor: DocumentAnchor
    ) {
        precondition(rowIndex >= 0, "PDF table cell row index must be non-negative")
        precondition(columnIndex >= 0, "PDF table cell column index must be non-negative")
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.text = text
        self.bounds = bounds
        self.anchor = anchor
    }
}
