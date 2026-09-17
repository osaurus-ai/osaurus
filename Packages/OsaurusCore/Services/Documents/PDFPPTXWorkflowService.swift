//
//  PDFPPTXWorkflowService.swift
//  osaurus
//
//  Workflow summaries for typed PDF and presentation reads. This layer keeps
//  PDF/PPTX creation honest: it can report a registered structured emitter,
//  but it does not treat text file writes as a valid binary package output.
//

import Foundation

public struct PDFPPTXWorkflowService: Sendable {
    private let registry: DocumentFormatRegistry

    public init(registry: DocumentFormatRegistry = .shared) {
        self.registry = registry
    }

    public func preview(
        _ document: StructuredDocument,
        policy: PDFPPTXPreviewPolicy = .standard
    ) throws -> PDFPPTXWorkflowPreview {
        if let pdf = document.representation.underlying as? PDFDocumentRepresentation {
            return .pdf(pdfPreview(pdf, document: document, policy: policy))
        }

        if let presentation = document.representation.underlying as? PresentationDocument {
            return .presentation(presentationPreview(presentation, document: document, policy: policy))
        }

        throw PDFPPTXWorkflowError.unsupportedRepresentation(formatId: document.formatId)
    }

    public func creationAvailability(for document: StructuredDocument) -> PDFPPTXCreationAvailability {
        guard
            document.representation.underlying is PDFDocumentRepresentation
                || document.representation.underlying is PresentationDocument
        else {
            return PDFPPTXCreationAvailability(
                formatId: document.formatId,
                reasonCode: .unsupportedFormat,
                emitterFormatId: nil,
                message: "Only typed PDF and PPTX/POTX documents are covered by this workflow."
            )
        }

        if let emitter = registry.emitter(for: document) {
            return PDFPPTXCreationAvailability(
                formatId: document.formatId,
                reasonCode: .available,
                emitterFormatId: emitter.formatId,
                message: "A structured emitter is registered for this document."
            )
        }

        return PDFPPTXCreationAvailability(
            formatId: document.formatId,
            reasonCode: .missingEmitter,
            emitterFormatId: nil,
            message:
                "No structured emitter is registered for this document. file_write generates .pdf/.docx (from Markdown or HTML) and .xlsx (from CSV/TSV/JSON rows); .pptx generation is not built in."
        )
    }

    // MARK: - PDF

    private func pdfPreview(
        _ pdf: PDFDocumentRepresentation,
        document: StructuredDocument,
        policy: PDFPPTXPreviewPolicy
    ) -> PDFWorkflowPreview {
        let sampledPages = pdf.pages.prefix(policy.maxSections).map { page in
            PDFPageWorkflowPreview(
                pageIndex: page.pageIndex,
                anchorId: page.anchor.id,
                bounds: page.bounds,
                text: Self.textPreview(page.text, maxUTF16Units: policy.maxTextPreviewUTF16Units),
                tableCount: page.tables.count,
                tables: page.tables.prefix(policy.maxTablesPerSection).map {
                    Self.pdfTablePreview($0, policy: policy)
                },
                isTableSampleTruncated: page.tables.count > policy.maxTablesPerSection
            )
        }

        let tables = pdf.pages.flatMap(\.tables)
        let tableCellCount = tables.reduce(0) { count, table in
            count + table.rows.reduce(0) { $0 + $1.cells.count }
        }

        return PDFWorkflowPreview(
            filename: document.filename,
            pageCount: pdf.pages.count,
            sampledPageCount: sampledPages.count,
            totalTextUTF16Units: pdf.pages.reduce(0) { $0 + $1.text.utf16.count },
            tableCount: tables.count,
            tableCellCount: tableCellCount,
            pages: Array(sampledPages),
            isPageSampleTruncated: pdf.pages.count > policy.maxSections,
            creationAvailability: creationAvailability(for: document)
        )
    }

    private static func pdfTablePreview(
        _ table: PDFTable,
        policy: PDFPPTXPreviewPolicy
    ) -> PDFPPTXTablePreview {
        tablePreview(
            sourceKind: .pdfPage,
            sourceIndex: table.pageIndex,
            index: table.index,
            anchorId: table.anchor.id,
            bounds: table.bounds,
            rows: table.rows,
            columnCount: table.columnCount,
            policy: policy,
            cells: { $0.cells },
            rowIndex: { $0.index },
            cellRowIndex: { $0.rowIndex },
            cellColumnIndex: { $0.columnIndex },
            cellText: { $0.text },
            cellAnchorId: { $0.anchor.id }
        )
    }

    // MARK: - Presentation

    private func presentationPreview(
        _ presentation: PresentationDocument,
        document: StructuredDocument,
        policy: PDFPPTXPreviewPolicy
    ) -> PresentationWorkflowPreview {
        let sampledSlides = presentation.slides.prefix(policy.maxSections).map { slide in
            PresentationSlideWorkflowPreview(
                slideIndex: slide.index,
                slideNumber: slide.number,
                label: slide.label,
                sourcePart: slide.sourcePart,
                isHidden: slide.isHidden,
                text: Self.textPreview(slide.text, maxUTF16Units: policy.maxTextPreviewUTF16Units),
                speakerNotes: slide.speakerNotes.map {
                    Self.textPreview($0.text, maxUTF16Units: policy.maxTextPreviewUTF16Units)
                },
                tableCount: slide.tables.count,
                tables: slide.tables.prefix(policy.maxTablesPerSection).map {
                    Self.presentationTablePreview($0, slideIndex: slide.index, policy: policy)
                },
                isTableSampleTruncated: slide.tables.count > policy.maxTablesPerSection
            )
        }

        let tables = presentation.slides.flatMap(\.tables)
        let tableCellCount = tables.reduce(0) { count, table in
            count + table.rows.reduce(0) { $0 + $1.cells.count }
        }

        return PresentationWorkflowPreview(
            filename: document.filename,
            kind: presentation.kind,
            slideCount: presentation.slides.count,
            sampledSlideCount: sampledSlides.count,
            hiddenSlideCount: presentation.slides.filter(\.isHidden).count,
            speakerNotesCount: presentation.slides.filter { $0.speakerNotes != nil }.count,
            totalTextUTF16Units: presentation.slides.reduce(0) {
                $0 + $1.text.utf16.count + ($1.speakerNotes?.text.utf16.count ?? 0)
            },
            tableCount: tables.count,
            tableCellCount: tableCellCount,
            slides: Array(sampledSlides),
            isSlideSampleTruncated: presentation.slides.count > policy.maxSections,
            creationAvailability: creationAvailability(for: document)
        )
    }

    private static func presentationTablePreview(
        _ table: PresentationTable,
        slideIndex: Int,
        policy: PDFPPTXPreviewPolicy
    ) -> PDFPPTXTablePreview {
        tablePreview(
            sourceKind: .presentationSlide,
            sourceIndex: slideIndex,
            index: table.index,
            anchorId: table.anchorId,
            bounds: nil,
            rows: table.rows,
            columnCount: table.columnCount,
            policy: policy,
            cells: { $0.cells },
            rowIndex: { $0.index },
            cellRowIndex: { $0.rowIndex },
            cellColumnIndex: { $0.columnIndex },
            cellText: { $0.text },
            cellAnchorId: { $0.anchorId }
        )
    }

    // MARK: - Shared table helpers

    private static func tablePreview<Row, Cell>(
        sourceKind: PDFPPTXTableSourceKind,
        sourceIndex: Int,
        index: Int,
        anchorId: String,
        bounds: DocumentBoundingBox?,
        rows: [Row],
        columnCount: Int,
        policy: PDFPPTXPreviewPolicy,
        cells: (Row) -> [Cell],
        rowIndex: (Row) -> Int,
        cellRowIndex: (Cell) -> Int,
        cellColumnIndex: (Cell) -> Int,
        cellText: (Cell) -> String,
        cellAnchorId: (Cell) -> String
    ) -> PDFPPTXTablePreview {
        let sampledRows = rows.prefix(policy.maxRowsPerTable).map { row in
            let rowCells = cells(row)
            return PDFPPTXTableRowPreview(
                index: rowIndex(row),
                cells: rowCells.prefix(policy.maxColumnsPerTable).map { cell in
                    PDFPPTXTableCellPreview(
                        rowIndex: cellRowIndex(cell),
                        columnIndex: cellColumnIndex(cell),
                        text: textPreview(cellText(cell), maxUTF16Units: policy.maxCellTextUTF16Units),
                        anchorId: cellAnchorId(cell)
                    )
                },
                isCellSampleTruncated: rowCells.count > policy.maxColumnsPerTable
            )
        }

        return PDFPPTXTablePreview(
            sourceKind: sourceKind,
            sourceIndex: sourceIndex,
            index: index,
            anchorId: anchorId,
            rowCount: rows.count,
            columnCount: columnCount,
            cellCount: rows.reduce(0) { $0 + cells($1).count },
            bounds: bounds,
            sampleRows: Array(sampledRows),
            isRowSampleTruncated: rows.count > policy.maxRowsPerTable,
            isColumnSampleTruncated: rows.contains { cells($0).count > policy.maxColumnsPerTable }
        )
    }

    private static func textPreview(_ text: String, maxUTF16Units: Int) -> PDFPPTXTextPreview {
        let fullLength = text.utf16.count
        guard fullLength > maxUTF16Units else {
            return PDFPPTXTextPreview(
                text: text,
                fullUTF16Length: fullLength,
                isTruncated: false
            )
        }

        var clipped = ""
        var units = 0
        for character in text {
            let nextUnits = String(character).utf16.count
            guard units + nextUnits <= maxUTF16Units else { break }
            clipped.append(character)
            units += nextUnits
        }

        return PDFPPTXTextPreview(
            text: clipped,
            fullUTF16Length: fullLength,
            isTruncated: true
        )
    }
}

public struct PDFPPTXPreviewPolicy: Equatable, Sendable {
    public static let standard = PDFPPTXPreviewPolicy()

    public let maxSections: Int
    public let maxTablesPerSection: Int
    public let maxRowsPerTable: Int
    public let maxColumnsPerTable: Int
    public let maxTextPreviewUTF16Units: Int
    public let maxCellTextUTF16Units: Int

    public init(
        maxSections: Int = 20,
        maxTablesPerSection: Int = 10,
        maxRowsPerTable: Int = 20,
        maxColumnsPerTable: Int = 12,
        maxTextPreviewUTF16Units: Int = 1_000,
        maxCellTextUTF16Units: Int = 256
    ) {
        precondition(maxSections > 0, "maxSections must be positive")
        precondition(maxTablesPerSection > 0, "maxTablesPerSection must be positive")
        precondition(maxRowsPerTable > 0, "maxRowsPerTable must be positive")
        precondition(maxColumnsPerTable > 0, "maxColumnsPerTable must be positive")
        precondition(maxTextPreviewUTF16Units > 0, "maxTextPreviewUTF16Units must be positive")
        precondition(maxCellTextUTF16Units > 0, "maxCellTextUTF16Units must be positive")

        self.maxSections = maxSections
        self.maxTablesPerSection = maxTablesPerSection
        self.maxRowsPerTable = maxRowsPerTable
        self.maxColumnsPerTable = maxColumnsPerTable
        self.maxTextPreviewUTF16Units = maxTextPreviewUTF16Units
        self.maxCellTextUTF16Units = maxCellTextUTF16Units
    }
}

public enum PDFPPTXWorkflowPreview: Equatable, Sendable {
    case pdf(PDFWorkflowPreview)
    case presentation(PresentationWorkflowPreview)
}

public struct PDFWorkflowPreview: Equatable, Sendable {
    public let filename: String
    public let pageCount: Int
    public let sampledPageCount: Int
    public let totalTextUTF16Units: Int
    public let tableCount: Int
    public let tableCellCount: Int
    public let pages: [PDFPageWorkflowPreview]
    public let isPageSampleTruncated: Bool
    public let creationAvailability: PDFPPTXCreationAvailability
}

public struct PDFPageWorkflowPreview: Equatable, Sendable {
    public let pageIndex: Int
    public let anchorId: String
    public let bounds: DocumentBoundingBox?
    public let text: PDFPPTXTextPreview
    public let tableCount: Int
    public let tables: [PDFPPTXTablePreview]
    public let isTableSampleTruncated: Bool
}

public struct PresentationWorkflowPreview: Equatable, Sendable {
    public let filename: String
    public let kind: PresentationDocumentKind
    public let slideCount: Int
    public let sampledSlideCount: Int
    public let hiddenSlideCount: Int
    public let speakerNotesCount: Int
    public let totalTextUTF16Units: Int
    public let tableCount: Int
    public let tableCellCount: Int
    public let slides: [PresentationSlideWorkflowPreview]
    public let isSlideSampleTruncated: Bool
    public let creationAvailability: PDFPPTXCreationAvailability
}

public struct PresentationSlideWorkflowPreview: Equatable, Sendable {
    public let slideIndex: Int
    public let slideNumber: Int
    public let label: String
    public let sourcePart: String
    public let isHidden: Bool
    public let text: PDFPPTXTextPreview
    public let speakerNotes: PDFPPTXTextPreview?
    public let tableCount: Int
    public let tables: [PDFPPTXTablePreview]
    public let isTableSampleTruncated: Bool
}

public struct PDFPPTXTablePreview: Equatable, Sendable {
    public let sourceKind: PDFPPTXTableSourceKind
    public let sourceIndex: Int
    public let index: Int
    public let anchorId: String
    public let rowCount: Int
    public let columnCount: Int
    public let cellCount: Int
    public let bounds: DocumentBoundingBox?
    public let sampleRows: [PDFPPTXTableRowPreview]
    public let isRowSampleTruncated: Bool
    public let isColumnSampleTruncated: Bool
}

public enum PDFPPTXTableSourceKind: String, Equatable, Sendable {
    case pdfPage
    case presentationSlide
}

public struct PDFPPTXTableRowPreview: Equatable, Sendable {
    public let index: Int
    public let cells: [PDFPPTXTableCellPreview]
    public let isCellSampleTruncated: Bool
}

public struct PDFPPTXTableCellPreview: Equatable, Sendable {
    public let rowIndex: Int
    public let columnIndex: Int
    public let text: PDFPPTXTextPreview
    public let anchorId: String
}

public struct PDFPPTXTextPreview: Equatable, Sendable {
    public let text: String
    public let fullUTF16Length: Int
    public let isTruncated: Bool
}

public struct PDFPPTXCreationAvailability: Equatable, Sendable {
    public let formatId: String
    public let reasonCode: PDFPPTXCreationReasonCode
    public let emitterFormatId: String?
    public let message: String

    public var isAvailable: Bool { reasonCode == .available }
}

public enum PDFPPTXCreationReasonCode: String, Equatable, Sendable {
    case available
    case missingEmitter
    case unsupportedFormat
}

public enum PDFPPTXWorkflowError: Error, Equatable, Sendable {
    case unsupportedRepresentation(formatId: String)
}
