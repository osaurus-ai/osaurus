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

    // MARK: - Fixtures

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("business-document-studio-\(UUID().uuidString)", isDirectory: true)
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
