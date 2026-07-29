//
//  BusinessDocumentStudioServiceTests.swift
//  osaurusTests
//
//  Covers the format-neutral document studio orchestration layer.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Business document studio service")
struct BusinessDocumentStudioServiceTests {

    @Test func inspectCSVWrapsPreviewRolesAndSafeDelimitedExports() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let service = BusinessDocumentStudioService(registry: registry)
        let source = try Self.write(
            """
            name,age,active
            Ada,37,true
            Ben,41,false
            """,
            filename: "people.csv"
        )
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("people.tsv")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let document = try await service.parse(url: source)
        let inspection = try await service.inspect(url: source)

        #expect(document.formatId == "csv")
        #expect(inspection.summary.kind == .table)
        #expect(inspection.summary.filename.hasSuffix("people.csv"))
        #expect(inspection.registryRoles == [.adapter, .emitter])
        #expect(inspection.exportOptions.contains { $0.targetFormatId == "csv" && $0.canExport })
        #expect(inspection.exportOptions.contains { $0.targetFormatId == "tsv" && $0.canExport })
        #expect(inspection.extractionSummary.fields.map(\.name) == ["name", "age", "active"])
        #expect(inspection.extractionSummary.tables.first?.rowCount == 3)
        #expect(inspection.extractionSummary.tables.first?.columnCount == 3)
        #expect(inspection.extractionSummary.attachmentHandoff.isAvailable)

        guard case let .table(preview) = inspection.preview else {
            Issue.record("Expected table preview")
            return
        }
        #expect(preview.hasHeader)
        #expect(preview.columns.map(\.name) == ["name", "age", "active"])
        #expect(preview.columns.map(\.inferredType) == [.string, .integer, .boolean])

        let encoded = try JSONEncoder().encode(inspection)
        let decoded = try JSONDecoder().decode(BusinessDocumentStudioInspection.self, from: encoded)
        #expect(decoded.summary.filename == inspection.summary.filename)
        #expect(decoded.extractionSummary.fields.count == 3)

        let result = try await service.export(
            document,
            as: "tsv",
            to: target,
            policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
        )

        #expect(result.targetFormatId == "tsv")
        #expect(result.bytesWritten > 0)
        let parsed = try await CSVAdapter(delimiter: .tab).parse(url: target, sizeLimit: 0)
        let table = try #require(parsed.representation.underlying as? CSVDocument)
        #expect(table.delimiter == .tab)
        #expect(table.rows[1].cells.map(\.text) == ["Ada", "37", "true"])
    }

    @Test func unsupportedImportThrowsExplicitUnsupportedFormat() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let service = BusinessDocumentStudioService(registry: registry)
        let source = try Self.write("bitmap bytes", filename: "scan.bmp")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await service.inspect(url: source)
            Issue.record("Expected unsupported format error")
        } catch BusinessDocumentStudioError.unsupportedFormat(let fileExtension) {
            #expect(fileExtension == "bmp")
        } catch {
            Issue.record("Expected unsupportedFormat, got \(error)")
        }
    }

    @Test func malformedWorkbookImportThrowsReadFailure() async throws {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let service = BusinessDocumentStudioService(registry: registry)
        let source = try Self.writeData(Data("not a zip package".utf8), filename: "broken.xlsx")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await service.parse(url: source)
            Issue.record("Expected malformed workbook read failure")
        } catch DocumentAdapterError.readFailed(let underlying) {
            #expect(!underlying.isEmpty)
        } catch {
            Issue.record("Expected DocumentAdapterError.readFailed, got \(error)")
        }
    }

    @Test func inspectWorkbookSamplesCellsAndReportsValidationBlockedExport() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let service = BusinessDocumentStudioService(registry: registry)
        let document = Self.workbookDocument(includeFormula: true)
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("workbook.xlsx")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let inspection = try service.inspect(document)

        #expect(inspection.summary.kind == .workbook)
        #expect(
            inspection.exportOptions.contains { option in
                option.targetFormatId == "xlsx"
                    && option.canExport == false
                    && option.reason == .validationFailed
            }
        )
        guard case let .workbook(preview) = inspection.preview else {
            Issue.record("Expected workbook preview")
            return
        }
        #expect(preview.inspection.formulaCellCount == 1)
        #expect(preview.inspection.validationIssues.contains { $0.code == .formulaNotWritable })
        #expect(preview.sheets.first?.sampleRows[1].cells[1].hasFormula == true)
        #expect(preview.sheets.first?.sampleRows[1].cells[1].text.text == "1200")
        #expect(inspection.extractionSummary.fields.isEmpty)
        #expect(inspection.extractionSummary.tables.first?.label == "Revenue")

        do {
            _ = try await service.export(
                document,
                as: "xlsx",
                to: target,
                policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
            )
            Issue.record("Expected formula validation to block XLSX export")
        } catch WorkbookWorkflowError.validationFailed(let issues) {
            #expect(issues.map(\.code).contains(.formulaNotWritable))
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } catch {
            Issue.record("Expected WorkbookWorkflowError.validationFailed, got \(error)")
        }
    }

    @Test func exportStructuredPackageRejectsMismatchedPackageExtension() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let service = BusinessDocumentStudioService(registry: registry)
        let document = Self.workbookDocument()
        let outputDirectory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        do {
            _ = try await service.export(
                document,
                as: "xlsx",
                to: outputDirectory.appendingPathComponent("workbook.pdf"),
                policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
            )
            Issue.record("Expected package extension mismatch to be rejected")
        } catch BusinessDocumentStudioError.packageTargetExtensionMismatch(
            let targetFormatId,
            let fileExtension
        ) {
            #expect(targetFormatId == "xlsx")
            #expect(fileExtension == "pdf")
        } catch {
            Issue.record("Expected packageTargetExtensionMismatch, got \(error)")
        }
    }

    @Test func exportStructuredPackageRejectsNonPackageExtension() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: XLSXEmitter())
        let service = BusinessDocumentStudioService(registry: registry)
        let document = Self.workbookDocument()
        let outputDirectory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        for filename in ["workbook.txt", "workbook"] {
            let target = outputDirectory.appendingPathComponent(filename)
            do {
                _ = try await service.export(
                    document,
                    as: "xlsx",
                    to: target,
                    policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
                )
                Issue.record("Expected non-package extension to be rejected for \(filename)")
            } catch BusinessDocumentStudioError.packageTargetExtensionMismatch(
                let targetFormatId,
                let fileExtension
            ) {
                #expect(targetFormatId == "xlsx")
                #expect(fileExtension == target.pathExtension.lowercased())
                #expect(!FileManager.default.fileExists(atPath: target.path))
            } catch {
                Issue.record("Expected packageTargetExtensionMismatch, got \(error)")
            }
        }
    }

    @Test func exportRegisteredEmitterCanOwnStructuredPackageExtension() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: StubPackageEmitter(formatId: "pptm"))
        let service = BusinessDocumentStudioService(registry: registry)
        let document = Self.pdfDocument()
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("slides.pptm")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let result = try await service.export(
            document,
            as: "pptm",
            to: target,
            policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
        )

        #expect(result.targetFormatId == "pptm")
        #expect(result.bytesWritten > 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "emitted:pptm")
    }

    @Test func exportTextFallbackRejectsPackageTargetsAndDirectoryEscape() async throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let document = Self.plainTextDocument()
        let outputDirectory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        do {
            _ = try await service.export(
                document,
                as: "txt",
                to: outputDirectory.appendingPathComponent("fake.xlsx"),
                policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
            )
            Issue.record("Expected text fallback package target to be rejected")
        } catch BusinessDocumentStudioError.unsafeTextPackageTarget(let fileExtension) {
            #expect(fileExtension == "xlsx")
        } catch {
            Issue.record("Expected unsafeTextPackageTarget, got \(error)")
        }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-outside-\(UUID().uuidString).txt")
        do {
            _ = try await service.export(
                document,
                as: "txt",
                to: outside,
                policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
            )
            Issue.record("Expected destination containment to reject outside path")
        } catch BusinessDocumentStudioError.destinationOutsideAllowedDirectory(let url) {
            #expect(url == outside)
            #expect(!FileManager.default.fileExists(atPath: outside.path))
        } catch {
            Issue.record("Expected destinationOutsideAllowedDirectory, got \(error)")
        }
    }

    @Test func outsideAllowedDestinationDoesNotDiscloseExistingTarget() async throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let document = Self.plainTextDocument()
        let outputDirectory = try Self.temporaryDirectory()
        let outsideDirectory = try Self.temporaryDirectory()
        let existingOutside = outsideDirectory.appendingPathComponent("existing.txt")
        let missingOutside = outsideDirectory.appendingPathComponent("missing.txt")
        try "private".write(to: existingOutside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        for target in [existingOutside, missingOutside] {
            do {
                _ = try await service.export(
                    document,
                    as: "txt",
                    to: target,
                    policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
                )
                Issue.record("Expected outside destination to be rejected")
            } catch BusinessDocumentStudioError.destinationOutsideAllowedDirectory(let url) {
                #expect(url == target)
            } catch {
                Issue.record("Expected destinationOutsideAllowedDirectory, got \(error)")
            }
        }

        #expect(try String(contentsOf: existingOutside, encoding: .utf8) == "private")
        #expect(!FileManager.default.fileExists(atPath: missingOutside.path))
    }

    @Test func exportRejectsExistingSymlinkLeafEscapingAllowedDirectory() async throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let outputDirectory = try Self.temporaryDirectory()
        let outsideDirectory = try Self.temporaryDirectory()
        let outsideTarget = outsideDirectory.appendingPathComponent("private.txt")
        let symlink = outputDirectory.appendingPathComponent("report.txt")
        try "private".write(to: outsideTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        do {
            _ = try await service.export(
                Self.plainTextDocument(text: "replacement"),
                as: "txt",
                to: symlink,
                policy: BusinessDocumentStudioExportPolicy(
                    allowedDirectory: outputDirectory,
                    allowOverwrite: true
                )
            )
            Issue.record("Expected an escaping symlink leaf to be rejected")
        } catch BusinessDocumentStudioError.destinationOutsideAllowedDirectory(let url) {
            #expect(url == symlink)
        } catch {
            Issue.record("Expected destinationOutsideAllowedDirectory, got \(error)")
        }

        #expect(try String(contentsOf: outsideTarget, encoding: .utf8) == "private")
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func exportRejectsDanglingSymlinkLeafEscapingAllowedDirectory() async throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let outputDirectory = try Self.temporaryDirectory()
        let outsideDirectory = try Self.temporaryDirectory()
        let missingOutsideTarget = outsideDirectory.appendingPathComponent("missing.txt")
        let symlink = outputDirectory.appendingPathComponent("report.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: missingOutsideTarget)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        do {
            _ = try await service.export(
                Self.plainTextDocument(text: "replacement"),
                as: "txt",
                to: symlink,
                policy: BusinessDocumentStudioExportPolicy(
                    allowedDirectory: outputDirectory,
                    allowOverwrite: true
                )
            )
            Issue.record("Expected a dangling escaping symlink leaf to be rejected")
        } catch BusinessDocumentStudioError.destinationOutsideAllowedDirectory(let url) {
            #expect(url == symlink)
        } catch {
            Issue.record("Expected destinationOutsideAllowedDirectory, got \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: missingOutsideTarget.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == missingOutsideTarget.path)
    }

    @Test func exportAllowsExistingSymlinkLeafResolvingWithinAllowedDirectory() async throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let outputDirectory = try Self.temporaryDirectory()
        let inRootTarget = outputDirectory.appendingPathComponent("stored.txt")
        let symlink = outputDirectory.appendingPathComponent("report.txt")
        try "stored".write(to: inRootTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: inRootTarget)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let result = try await service.export(
            Self.plainTextDocument(text: "replacement"),
            as: "txt",
            to: symlink,
            policy: BusinessDocumentStudioExportPolicy(
                allowedDirectory: outputDirectory,
                allowOverwrite: true
            )
        )

        #expect(result.url == symlink)
        #expect(try String(contentsOf: symlink, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: inRootTarget, encoding: .utf8) == "stored")
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    }

    @Test func exportTreatsVarAndPrivateVarAsSameAllowedDirectory() async throws {
        let directoryName = "business-document-studio-firmlink-\(UUID().uuidString)"
        let privateRoot = URL(fileURLWithPath: "/private/var/tmp")
            .appendingPathComponent(directoryName, isDirectory: true)
        let varRoot = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privateRoot) }

        let target = varRoot.appendingPathComponent("report.txt")
        let result = try await BusinessDocumentStudioService(registry: DocumentFormatRegistry()).export(
            Self.plainTextDocument(text: "firmlink-safe"),
            as: "txt",
            to: target,
            policy: BusinessDocumentStudioExportPolicy(allowedDirectory: privateRoot)
        )

        #expect(result.url == target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "firmlink-safe")
    }

    @Test func destinationAppearingDuringRenderIsNotOverwrittenWithoutConsent() async throws {
        let outputDirectory = try Self.temporaryDirectory()
        let target = outputDirectory.appendingPathComponent("raced.pdf")
        let registry = DocumentFormatRegistry()
        registry.register(emitter: DestinationCreatingPDFEmitter(finalURL: target))
        let service = BusinessDocumentStudioService(registry: registry)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        do {
            _ = try await service.export(
                Self.pdfDocument(),
                as: "pdf",
                to: target,
                policy: BusinessDocumentStudioExportPolicy(allowedDirectory: outputDirectory)
            )
            Issue.record("Expected the raced destination to retain exclusive ownership")
        } catch BusinessDocumentStudioError.destinationAlreadyExists(let url) {
            #expect(url == target)
        } catch {
            Issue.record("Expected destinationAlreadyExists, got \(error)")
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == "racer")
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        #expect(!remainingNames.contains { $0.contains(".osaurus-export-") })
    }

    @Test func inspectPDFWrapsPreviewAndMissingEmitterExportOption() throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let inspection = try service.inspect(Self.pdfDocument())

        #expect(inspection.summary.kind == .pdf)
        #expect(
            inspection.exportOptions.contains { option in
                option.targetFormatId == "pdf"
                    && option.canExport == false
                    && option.reason == .missingEmitter
            }
        )
        guard case let .pdf(preview) = inspection.preview else {
            Issue.record("Expected PDF preview")
            return
        }
        #expect(preview.pageCount == 1)
        #expect(preview.pages.first?.text.text == "Quarterly report")
        #expect(preview.creationAvailability.reasonCode == .missingEmitter)
    }

    @Test func structuredAttachmentHandoffUsesExistingAttachmentAPI() throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let document = Self.pdfDocument()

        let inspection = try service.inspect(document)
        let attachment = try service.makeAttachment(for: document)

        #expect(inspection.extractionSummary.attachmentHandoff.isAvailable)
        #expect(attachment.filename == "report.pdf")
        #expect(attachment.structuredDocumentMetadata?.formatId == "pdf")
        #expect(attachment.businessDocumentSummary?.kind == .pdf)
    }

    @Test func emptyTextFallbackDisablesAndBlocksAttachmentHandoff() throws {
        let service = BusinessDocumentStudioService(registry: DocumentFormatRegistry())
        let document = Self.plainTextDocument(text: "")

        let inspection = try service.inspect(document)

        #expect(!inspection.extractionSummary.attachmentHandoff.isAvailable)
        #expect(inspection.extractionSummary.attachmentHandoff.fallbackUTF8Bytes == 0)
        do {
            _ = try service.makeAttachment(for: document)
            Issue.record("Expected empty text fallback to block attachment handoff")
        } catch BusinessDocumentStudioError.attachmentHandoffUnavailable(let message) {
            #expect(message.contains("non-empty text fallback"))
        } catch {
            Issue.record("Expected attachmentHandoffUnavailable, got \(error)")
        }
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
            .appendingPathComponent("business-document-studio-\(UUID().uuidString)", isDirectory: true)
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
                )
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

private struct StubPackageEmitter: DocumentFormatEmitter {
    let formatId: String

    func canEmit(_ document: StructuredDocument) -> Bool {
        true
    }

    func emit(_ document: StructuredDocument, to url: URL) async throws {
        try Data("emitted:\(formatId)".utf8).write(to: url, options: .atomic)
    }
}

private struct DestinationCreatingPDFEmitter: DocumentFormatEmitter {
    let finalURL: URL
    let formatId = "pdf"

    func canEmit(_ document: StructuredDocument) -> Bool {
        document.representation.underlying is PDFDocumentRepresentation
    }

    func emit(_ document: StructuredDocument, to url: URL) async throws {
        try Data("rendered".utf8).write(to: url, options: .atomic)
        try Data("racer".utf8).write(to: finalURL, options: .atomic)
    }
}
