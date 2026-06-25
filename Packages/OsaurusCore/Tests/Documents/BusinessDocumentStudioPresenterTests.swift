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
        #expect(presentation.importRows.contains { $0.label == "Source" && $0.value == source.path })
        #expect(presentation.importRows.contains(.init(label: "Document kind", value: "Table")))
        #expect(presentation.importRows.contains(.init(label: "Extraction", value: "Structured table preview")))
        #expect(presentation.businessRows.contains(.init(label: "Fields", value: "3")))
        #expect(presentation.businessRows.contains(.init(label: "Tables", value: "1")))
        #expect(presentation.fieldRows.contains { $0.label == "age" && $0.value.contains("integer") })
        #expect(presentation.tableRows.contains { $0.label.hasSuffix("people.csv") && $0.value.contains("3x3") })
        #expect(presentation.handoffRows.contains(.init(label: "Status", value: "Available")))
        #expect(presentation.previewRows.contains(.init(label: "Preview", value: "Delimited table")))
        #expect(presentation.previewRows.contains(.init(label: "Columns", value: "3")))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("csv"))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("tsv"))
        #expect(presentation.availableExportOptions.map(\.targetFormatId).contains("txt"))
        #expect(presentation.unavailableExportOptions.isEmpty)
    }

    @Test func unsupportedFormatLoadUsesExplicitUnsupportedState() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: registry)
        )
        let source = try Self.write("not a supported business document", filename: "scan.bmp")
        defer { try? FileManager.default.removeItem(at: source) }

        await presenter.load(url: source)

        guard case .failed(let failure) = presenter.loadState else {
            Issue.record("Expected failed load state, got \(presenter.loadState)")
            return
        }
        #expect(failure.kind == .unsupportedFormat)
        #expect(failure.title == "Unsupported format")
        #expect(failure.path == source.path)
        #expect(presenter.artifactStatuses.isEmpty)
    }

    @Test func malformedWorkbookLoadUsesExtractionFailureState() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: registry)
        )
        let source = try Self.writeData(Data("not a zip package".utf8), filename: "broken.xlsx")
        defer { try? FileManager.default.removeItem(at: source) }

        await presenter.load(url: source)

        guard case .failed(let failure) = presenter.loadState else {
            Issue.record("Expected failed load state, got \(presenter.loadState)")
            return
        }
        #expect(failure.kind == .malformedFile)
        #expect(failure.title == "Document could not be extracted")
        #expect(failure.message.contains("Document read failed"))
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
        #expect(presentation.fieldRows.isEmpty)
        #expect(presentation.businessRows.contains(.init(label: "Fields", value: "0")))
        #expect(presentation.tableRows.contains { $0.label == "Revenue" && $0.value.contains("2x2") })
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
        #expect(pdf.statusLabel == "Missing emitter")

        await presenter.export(optionID: "pdf", to: target, allowedDirectory: outputDirectory)

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .unavailableOption)
        #expect(block.optionID == "pdf")
        #expect(block.reason == .missingEmitter)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let status = try #require(presenter.artifactStatuses.first)
        #expect(status.state == .blocked)
        #expect(status.optionID == "pdf")
        #expect(status.reason == .missingEmitter)
        #expect(status.safetyLabel == "No artifact written")
    }

    @Test func workspaceAttachmentHandoffProducesStructuredDocumentAttachment() throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )

        try presenter.load(document: Self.pdfDocument())

        let attachment = try presenter.makeWorkspaceAttachment()

        #expect(attachment.filename == "report.pdf")
        #expect(attachment.structuredDocumentMetadata?.formatId == "pdf")
        #expect(attachment.businessDocumentSummary?.kind == .pdf)
        #expect(attachment.businessDocumentSummary?.chipDetailLabel.contains("PDF") == true)
    }

    @Test func emptyTextFallbackShowsUnavailableHandoffAndBlocksAttachmentCreation() throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )

        try presenter.load(document: Self.plainTextDocument(text: ""))

        let presentation = try Self.loadedPresentation(from: presenter)
        #expect(presentation.businessRows.contains(.init(label: "Workspace handoff", value: "Unavailable")))
        #expect(presentation.handoffRows.contains(.init(label: "Status", value: "Unavailable")))
        let fallbackRow = try #require(presentation.handoffRows.first { $0.label == "Text fallback" })
        #expect(fallbackRow.value.contains("0") || fallbackRow.value.lowercased().contains("zero"))

        do {
            _ = try presenter.makeWorkspaceAttachment()
            Issue.record("Expected empty text fallback to block workspace attachment creation")
        } catch BusinessDocumentStudioPresenterError.attachmentHandoffUnavailable(let message) {
            #expect(message.contains("non-empty text fallback"))
        } catch {
            Issue.record("Expected attachmentHandoffUnavailable, got \(error)")
        }
    }

    @Test func presentationPreviewSurfacesSlideExtractionAndMissingEmitter() throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )

        try presenter.load(document: Self.presentationDocument())

        let presentation = try Self.loadedPresentation(from: presenter)
        #expect(presentation.importRows.contains(.init(label: "Document kind", value: "Slides")))
        #expect(presentation.importRows.contains(.init(label: "Extraction", value: "Presentation slide preview")))
        #expect(presentation.previewRows.contains(.init(label: "Preview", value: "Presentation")))
        #expect(presentation.previewRows.contains(.init(label: "Slides", value: "1")))
        #expect(presentation.previewSections.first?.rows.contains(.init(label: "Text", value: "Roadmap\nNext steps")) == true)

        let pptx = try #require(presentation.exportOptions.first { $0.targetFormatId == "pptx" })
        #expect(pptx.canExport == false)
        #expect(pptx.reason == .missingEmitter)
        #expect(pptx.statusLabel == "Missing emitter")
    }

    @Test func pdfAndSlideTableExtractionSummariesSurfaceSampledTables() throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )

        try presenter.load(document: Self.pdfDocumentWithTable())

        var presentation = try Self.loadedPresentation(from: presenter)
        #expect(presentation.businessRows.contains(.init(label: "Tables", value: "1")))
        #expect(presentation.tableRows.contains { row in
            row.label == "Page 1 table 1"
                && row.value.contains("2x2")
                && row.value.contains("Region | Revenue")
        })
        #expect(presentation.previewSections.first?.rows.contains { row in
            row.label == "Table row 1" && row.value == "Region | Revenue"
        } == true)

        try presenter.load(document: Self.presentationDocument(includeTable: true))

        presentation = try Self.loadedPresentation(from: presenter)
        #expect(presentation.businessRows.contains(.init(label: "Tables", value: "1")))
        #expect(presentation.fieldRows.contains { $0.label == "Slide 1" && $0.value.contains("slide text") })
        #expect(presentation.tableRows.contains { row in
            row.label == "Slide 1 table 1"
                && row.value.contains("2x2")
                && row.value.contains("Quarter | Status")
        })
        #expect(presentation.previewSections.first?.rows.contains { row in
            row.label == "Table row 1" && row.value == "Quarter | Status"
        } == true)
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
        let status = try #require(presenter.artifactStatuses.first)
        #expect(status.state == .created)
        #expect(status.optionID == "txt")
        #expect(status.path == target.path)
        #expect(status.bytesWritten == receipt.bytesWritten)
        #expect(status.safetyLabel == "Written by a registered document workflow")
    }

    @Test func existingDestinationRequiresOverwriteConsentAndCancelPreservesTarget() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("existing.txt")
        try "private".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .awaitingOverwriteConsent(let request) = presenter.exportState else {
            Issue.record("Expected overwrite consent state, got \(presenter.exportState)")
            return
        }
        #expect(request.optionID == "txt")
        #expect(request.destination == target)
        let pending = try #require(presenter.artifactStatuses.first)
        #expect(pending.state == .needsConsent)
        #expect(pending.safetyLabel == "No artifact written until replacement is confirmed")

        presenter.cancelPendingOverwrite()

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state after cancel, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .overwriteDeclined)
        #expect(try String(contentsOf: target, encoding: .utf8) == "private")
        #expect(presenter.artifactStatuses.first?.state == .blocked)
        #expect(!presenter.artifactStatuses.contains { $0.state == .needsConsent })
    }

    @Test func overwriteConsentConfirmationWritesArtifact() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("existing.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .awaitingOverwriteConsent = presenter.exportState else {
            Issue.record("Expected overwrite consent state, got \(presenter.exportState)")
            return
        }

        await presenter.confirmPendingOverwrite()

        guard case .succeeded(let receipt) = presenter.exportState else {
            Issue.record("Expected succeeded export state, got \(presenter.exportState)")
            return
        }
        #expect(receipt.targetFormatId == "txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
        #expect(presenter.artifactStatuses.first?.state == .created)
        #expect(!presenter.artifactStatuses.contains { $0.state == .needsConsent })
    }

    @Test func outsideAllowedDirectoryIsBlockedByService() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let allowedDirectory = try Self.temporaryDirectory()
        let outsideDirectory = try Self.temporaryDirectory()
        let target = outsideDirectory.appendingPathComponent("outside.txt")
        try "outside".write(to: target, atomically: true, encoding: .utf8)
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
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(presenter.artifactStatuses.first?.state == .blocked)
    }

    @Test func textFallbackExportCannotWritePackageShapedArtifact() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("fake.pdf")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .unsafePackageTarget)
        #expect(block.path == "pdf")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let status = try #require(presenter.artifactStatuses.first)
        #expect(status.state == .blocked)
        #expect(status.title == "Unsafe package target blocked")
        #expect(status.safetyLabel == "No artifact written")
    }

    @Test func overwriteConsentCannotBypassUnsafePackageTarget() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("fake.pdf")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        guard case .awaitingOverwriteConsent = presenter.exportState else {
            Issue.record("Expected overwrite consent state, got \(presenter.exportState)")
            return
        }

        await presenter.confirmPendingOverwrite()

        guard case .blocked(let block) = presenter.exportState else {
            Issue.record("Expected blocked export state, got \(presenter.exportState)")
            return
        }
        #expect(block.kind == .unsafePackageTarget)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(presenter.artifactStatuses.first?.state == .blocked)
        #expect(!presenter.artifactStatuses.contains { $0.state == .needsConsent })
    }

    @Test func repeatedIdenticalBlocksDoNotDuplicateArtifactStatusIDs() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("fake.pdf")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)
        await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)

        #expect(presenter.artifactStatuses.count == 1)
        #expect(Set(presenter.artifactStatuses.map(\.id)).count == presenter.artifactStatuses.count)
        #expect(presenter.artifactStatuses.first?.state == .blocked)
    }

    @Test func artifactStatusesTrimToMostRecentTenRows() async throws {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )
        let outputDirectory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try presenter.load(document: Self.plainTextDocument())
        for index in 0..<12 {
            let target = outputDirectory.appendingPathComponent("artifact-\(index).txt")
            await presenter.export(optionID: "txt", to: target, allowedDirectory: outputDirectory)
        }

        #expect(presenter.artifactStatuses.count == 10)
        #expect(Set(presenter.artifactStatuses.map(\.id)).count == presenter.artifactStatuses.count)
        #expect(presenter.artifactStatuses.first?.path?.hasSuffix("artifact-11.txt") == true)
        #expect(presenter.artifactStatuses.last?.path?.hasSuffix("artifact-2.txt") == true)
    }

    @Test func confirmOverwriteWithoutPendingRequestReportsFailure() async {
        let presenter = BusinessDocumentStudioPresenter(
            service: BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        )

        await presenter.confirmPendingOverwrite()

        guard case .failed(let message) = presenter.exportState else {
            Issue.record("Expected failed export state, got \(presenter.exportState)")
            return
        }
        #expect(message == "No overwrite is waiting for confirmation.")
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

    private static func writeData(_ data: Data, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("business-document-studio-presenter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func plainTextDocument(text: String = "hello world") -> StructuredDocument {
        StructuredDocument(
            formatId: "plaintext",
            filename: "notes.txt",
            fileSize: Int64(text.utf8.count),
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: text)
            ),
            security: .notInspected(
                formatId: "plaintext",
                fileExtension: "txt",
                sourceTrust: .generatedArtifact
            ),
            textFallback: text
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

    private static func pdfDocumentWithTable() -> StructuredDocument {
        let table = PDFTable(
            pageIndex: 0,
            index: 0,
            rows: [
                pdfTableRow(index: 0, values: ["Region", "Revenue"]),
                pdfTableRow(index: 1, values: ["North", "$1200"]),
            ],
            bounds: bounds(),
            anchor: DocumentAnchor(
                kind: .table,
                path: [.init(kind: .page, index: 0), .init(kind: .table, index: 0)]
            )
        )
        let page = PDFPageRepresentation(
            pageIndex: 0,
            text: "Quarterly report",
            tables: [table],
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
            textFallback: "Quarterly report\nRegion\tRevenue\nNorth\t$1200"
        )
    }

    private static func presentationDocument(includeTable: Bool = false) -> StructuredDocument {
        let sourcePart = "ppt/slides/slide1.xml"
        let table = PresentationTable(
            index: 0,
            sourcePart: sourcePart,
            anchorId: "slide1/table0",
            rows: [
                PresentationTableRow(
                    index: 0,
                    anchorId: "slide1/table0/row0",
                    cells: [
                        PresentationTableCell(
                            rowIndex: 0,
                            columnIndex: 0,
                            text: "Quarter",
                            paragraphIndexes: [2],
                            anchorId: "slide1/table0/r0c0"
                        ),
                        PresentationTableCell(
                            rowIndex: 0,
                            columnIndex: 1,
                            text: "Status",
                            paragraphIndexes: [2],
                            anchorId: "slide1/table0/r0c1"
                        ),
                    ]
                ),
                PresentationTableRow(
                    index: 1,
                    anchorId: "slide1/table0/row1",
                    cells: [
                        PresentationTableCell(
                            rowIndex: 1,
                            columnIndex: 0,
                            text: "Q1",
                            paragraphIndexes: [3],
                            anchorId: "slide1/table0/r1c0"
                        ),
                        PresentationTableCell(
                            rowIndex: 1,
                            columnIndex: 1,
                            text: "Green",
                            paragraphIndexes: [3],
                            anchorId: "slide1/table0/r1c1"
                        ),
                    ]
                ),
            ]
        )
        let slide = PresentationSlide(
            index: 0,
            number: 1,
            sourcePart: sourcePart,
            label: "Slide 1",
            textRuns: [
                PresentationTextRun(
                    text: "Roadmap",
                    paragraphIndex: 0,
                    runIndex: 0,
                    sourcePart: sourcePart,
                    anchorId: "slide1/p0/r0"
                ),
                PresentationTextRun(
                    text: "Next steps",
                    paragraphIndex: 1,
                    runIndex: 0,
                    sourcePart: sourcePart,
                    anchorId: "slide1/p1/r0"
                ),
            ],
            tables: includeTable ? [table] : []
        )
        let deck = PresentationDocument(
            kind: .presentation,
            sourceName: "roadmap.pptx",
            slides: [slide]
        )

        return StructuredDocument(
            formatId: "pptx",
            filename: "roadmap.pptx",
            fileSize: 512,
            representation: AnyStructuredRepresentation(
                formatId: "pptx",
                underlying: deck
            ),
            security: .notInspected(
                formatId: "pptx",
                fileExtension: "pptx",
                sourceTrust: .generatedArtifact
            ),
            textFallback: slide.text
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

    private static func pdfTableRow(index: Int, values: [String]) -> PDFTableRow {
        PDFTableRow(
            index: index,
            cells: values.enumerated().map { columnIndex, value in
                PDFTableCell(
                    rowIndex: index,
                    columnIndex: columnIndex,
                    text: value,
                    bounds: bounds(x: Double(columnIndex) * 10, y: Double(index) * 10),
                    anchor: DocumentAnchor(
                        kind: .cell,
                        path: [
                            .init(kind: .page, index: 0),
                            .init(kind: .table, index: 0),
                            .init(kind: .row, index: index),
                            .init(kind: .cell, index: columnIndex),
                        ]
                    )
                )
            },
            bounds: bounds(y: Double(index) * 10),
            anchor: DocumentAnchor(
                kind: .row,
                path: [
                    .init(kind: .page, index: 0),
                    .init(kind: .table, index: 0),
                    .init(kind: .row, index: index),
                ]
            )
        )
    }

    private static func bounds(
        x: Double = 0,
        y: Double = 0,
        width: Double = 10,
        height: Double = 10
    ) -> DocumentBoundingBox {
        DocumentBoundingBox(x: x, y: y, width: width, height: height, coordinateSpace: .page)
    }
}
