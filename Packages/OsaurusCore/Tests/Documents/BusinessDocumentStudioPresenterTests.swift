//
//  BusinessDocumentStudioPresenterTests.swift
//  osaurusTests
//
//  Focused coverage for the Business Document Studio UI presenter.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Business document studio presenter")
struct BusinessDocumentStudioPresenterTests {

    @Test func csvInspectionBuildsPreviewAndAvailableExportRows() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: registry)
        )
        let source = try Self.write(
            """
            name,age,active
            Ada,37,true
            Ben,41,false
            """,
            filename: "people.csv"
        )
        defer { try? FileManager.default.removeItem(at: source) }

        await presenter.load(url: source)

        let presentation = try Self.loadedPresentation(from: presenter)
        #expect(presentation.title.hasSuffix("people.csv"))
        #expect(presentation.previewRows.contains(.init(label: "Preview", value: "Delimited table")))
        #expect(presentation.previewRows.contains(.init(label: "Columns", value: "3")))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("csv"))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("tsv"))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("txt"))
        #expect(presentation.unavailableExportOptions.isEmpty)
    }

    @Test func workbookValidationBlockedExportIsPresented() throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: registry)
        )

        try presenter.load(document: Self.workbookDocument(includeFormula: true))

        let presentation = try Self.loadedPresentation(from: presenter)
        let xlsx = try #require(presentation.exportOptions.first { $0.targetFormatId == "xlsx" })
        #expect(xlsx.canExport == false)
        #expect(xlsx.reason == .validationFailed)
        #expect(xlsx.reasonLabel == "Validation failed")
        #expect(presentation.previewRows.contains(.init(label: "Formula cells", value: "1")))
        #expect(presentation.warnings.contains { warning in
            warning.severity == .blocked
                && warning.title == "Export unavailable: XLSX workbook"
                && warning.message.contains("Validation failed")
        })
    }

    @Test func missingEmitterOptionBlocksExportBeforeDestinationWrite() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("report.pdf")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.pdfDocument())
        let presentation = try Self.loadedPresentation(from: presenter)

        let pdf = try #require(presentation.exportOptions.first { $0.targetFormatId == "pdf" })
        #expect(pdf.canExport == false)
        #expect(pdf.reason == .missingEmitter)
        #expect(pdf.reasonLabel == "Missing emitter")

        await presenter.export(optionID: "pdf", to: target, allowedDirectory: outputDirectory)

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .unavailableOption)
        #expect(block.optionID == "pdf")
        #expect(block.reason == .missingEmitter)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func availableTextFallbackExportSucceeds() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("notes.txt")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        let presentation = try Self.loadedPresentation(from: presenter)
        let text = try #require(presentation.exportOptions.first { $0.targetFormatId == "txt" })
        #expect(text.canExport)

        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .succeeded(let receipt) = presenter.exportState else {
            Issue.record("Expected succeeded export state, got \(presenter.exportState)")
            return
        }
        #expect(receipt.targetFormatId == "txt")
        #expect(receipt.bytesWritten > 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
    }

    @Test func destinationAlreadyExistsIsBlockedByService() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("existing.txt")
        try "private".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .destinationAlreadyExists)
        #expect(block.path == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "private")
    }

    @Test func destinationOverwriteSucceedsWhenInteractiveCallerAllowsIt() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("existing.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(
            optionID: "txt",
            to: target,
            allowedDirectory: outputDirectory,
            allowOverwrite: true
        )

        guard case .succeeded(let receipt) = presenter.exportState else {
            Issue.record("Expected succeeded export state, got \(presenter.exportState)")
            return
        }
        #expect(receipt.targetFormatId == "txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
    }

    @Test func outsideAllowedDirectoryIsBlockedByService() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let allowedDirectory = try Self.temporaryDirectory()
        let outsideDirectory = try Self.temporaryDirectory()
        let target = outsideDirectory.appendingPathComponent("outside.txt")
        defer {
            try? FileManager.default.removeItem(at: allowedDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: allowedDirectory)

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .destinationOutsideAllowedDirectory)
        #expect(block.path == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func presentationRowsUseStableUniqueIdentifiers() throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: registry)
        )

        try presenter.load(document: Self.workbookDocument())

        let presentation = try Self.loadedPresentation(from: presenter)
        #expect(Set(presentation.summaryRows.map(\.id)).count == presentation.summaryRows.count)
        #expect(Set(presentation.structureRows.map(\.id)).count == presentation.structureRows.count)
        #expect(Set(presentation.securityRows.map(\.id)).count == presentation.securityRows.count)
        #expect(Set(presentation.previewRows.map(\.id)).count == presentation.previewRows.count)
        #expect(Set(presentation.previewSections.map(\.id)).count == presentation.previewSections.count)
        for section in presentation.previewSections {
            #expect(Set(section.rows.map(\.id)).count == section.rows.count)
        }
    }

    // MARK: - Assertions

    private static func loadedPresentation(
        from presenter: BusinessDocumentStudioPresenter
    ) throws -> BusinessDocumentStudioPresentation {
        guard case .loaded(let presentation) = presenter.loadState else {
            Issue.record("Expected loaded presentation, got \(presenter.loadState)")
            throw TestFailure.notLoaded
        }
        return presentation
    }

    private enum TestFailure: Error {
        case notLoaded
    }

    // MARK: - Fixtures

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("business-document-studio-presenter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func plainTextDocument() -> StructuredDocument {
        StructuredDocument(
            formatId: "plaintext",
            filename: "notes.txt",
            fileSize: 11,
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: "hello world")
            ),
            security: .notInspected(
                formatId: "plaintext",
                fileExtension: "txt",
                sourceTrust: .generatedArtifact
            ),
            textFallback: "hello world"
        )
    }

    private static func pdfDocument() -> StructuredDocument {
        let page = PDFPageRepresentation(
            pageIndex: 0,
            text: "Quarterly report",
            anchor: DocumentAnchor(
                kind: .page,
                path: [.init(kind: .page, index: 0)],
                label: "Page 1"
            )
        )
        return StructuredDocument(
            formatId: "pdf",
            filename: "report.pdf",
            fileSize: 128,
            representation: AnyStructuredRepresentation(
                formatId: "pdf",
                underlying: PDFDocumentRepresentation(pages: [page])
            ),
            security: .notInspected(
                formatId: "pdf",
                fileExtension: "pdf",
                sourceTrust: .generatedArtifact
            ),
            textFallback: "Quarterly report"
        )
    }

    private static func workbookDocument(includeFormula: Bool = false) -> StructuredDocument {
        let workbook = Workbook(
            sheets: [
                Workbook.Sheet(
                    name: "Revenue",
                    index: 0,
                    rows: [
                        row(
                            number: 1,
                            cells: [
                                cell("A1", row: 1, column: 1, value: .string("Month")),
                                cell("B1", row: 1, column: 2, value: .string("Amount")),
                            ]
                        ),
                        row(
                            number: 2,
                            cells: [
                                cell("A2", row: 2, column: 1, value: .string("January")),
                                cell(
                                    "B2",
                                    row: 2,
                                    column: 2,
                                    value: .number(1200),
                                    formula: includeFormula ? "SUM(B2:B2)" : nil
                                ),
                            ]
                        ),
                    ],
                    anchor: DocumentAnchor(kind: .sheet, path: [.init(kind: .sheet, index: 0)])
                ),
            ]
        )

        return StructuredDocument(
            formatId: "xlsx",
            filename: "workbook.xlsx",
            fileSize: 256,
            representation: AnyStructuredRepresentation(formatId: "xlsx", underlying: workbook),
            security: .notInspected(
                formatId: "xlsx",
                fileExtension: "xlsx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: "Month\tAmount\nJanuary\t1200"
        )
    }

    private static func row(number: Int, cells: [Workbook.Cell]) -> Workbook.Row {
        Workbook.Row(
            number: number,
            cells: cells,
            anchor: DocumentAnchor(kind: .row, path: [.init(kind: .row, index: number - 1)])
        )
    }

    private static func cell(
        _ reference: String,
        row: Int,
        column: Int,
        value: Workbook.CellValue,
        formula: String? = nil
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
                    .init(kind: .row, index: row - 1),
                    .init(kind: .cell, index: column - 1),
                ]
            )
        )
    }
}
