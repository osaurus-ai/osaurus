//
//  BusinessDocumentStudioService.swift
//  osaurus
//
//  Format-neutral orchestration for business-file workflows. The existing
//  adapters and format-specific workflow services keep owning parse/export
//  fidelity; this layer gives UI, plugins, and attachment surfaces one bounded
//  entry point for inspect, preview, and explicit export checks.
//

import Foundation
import UniformTypeIdentifiers

public struct BusinessDocumentStudioPolicy: Equatable, Sendable {
    public let csvPreview: CSVTablePreviewPolicy
    public let workbookPreview: BusinessDocumentWorkbookPreviewPolicy
    public let workbookExport: WorkbookExportPolicy
    public let pdfPPTXPreview: PDFPPTXPreviewPolicy
    public let textPreview: BusinessDocumentTextPreviewPolicy

    public init(
        csvPreview: CSVTablePreviewPolicy = .standard,
        workbookPreview: BusinessDocumentWorkbookPreviewPolicy = .standard,
        workbookExport: WorkbookExportPolicy = .xlsxExport,
        pdfPPTXPreview: PDFPPTXPreviewPolicy = .standard,
        textPreview: BusinessDocumentTextPreviewPolicy = .standard
    ) {
        self.csvPreview = csvPreview
        self.workbookPreview = workbookPreview
        self.workbookExport = workbookExport
        self.pdfPPTXPreview = pdfPPTXPreview
        self.textPreview = textPreview
    }

    public static let standard = BusinessDocumentStudioPolicy()
}

public struct BusinessDocumentWorkbookPreviewPolicy: Codable, Equatable, Sendable {
    public let maxSheets: Int
    public let maxRowsPerSheet: Int
    public let maxColumnsPerSheet: Int
    public let maxCellTextUTF16Units: Int

    public init(
        maxSheets: Int = 3,
        maxRowsPerSheet: Int = 20,
        maxColumnsPerSheet: Int = 12,
        maxCellTextUTF16Units: Int = 256
    ) {
        self.maxSheets = max(1, maxSheets)
        self.maxRowsPerSheet = max(1, maxRowsPerSheet)
        self.maxColumnsPerSheet = max(1, maxColumnsPerSheet)
        self.maxCellTextUTF16Units = max(1, maxCellTextUTF16Units)
    }

    public static let standard = BusinessDocumentWorkbookPreviewPolicy()
}

public struct BusinessDocumentTextPreviewPolicy: Codable, Equatable, Sendable {
    public let maxTextUTF16Units: Int
    public let maxRichBlocks: Int
    public let maxBlockTextUTF16Units: Int

    public init(
        maxTextUTF16Units: Int = 4_000,
        maxRichBlocks: Int = 20,
        maxBlockTextUTF16Units: Int = 500
    ) {
        self.maxTextUTF16Units = max(1, maxTextUTF16Units)
        self.maxRichBlocks = max(1, maxRichBlocks)
        self.maxBlockTextUTF16Units = max(1, maxBlockTextUTF16Units)
    }

    public static let standard = BusinessDocumentTextPreviewPolicy()
}

public struct BusinessDocumentStudioExportPolicy: Equatable, Sendable {
    public let allowedDirectory: URL?
    public let allowOverwrite: Bool
    public let maxTextExportUTF8Bytes: Int

    public init(
        allowedDirectory: URL? = nil,
        allowOverwrite: Bool = false,
        maxTextExportUTF8Bytes: Int = 5 * 1024 * 1024
    ) {
        self.allowedDirectory = allowedDirectory
        self.allowOverwrite = allowOverwrite
        self.maxTextExportUTF8Bytes = max(1, maxTextExportUTF8Bytes)
    }

    public static let standard = BusinessDocumentStudioExportPolicy()
}

public struct BusinessDocumentStudioInspection: Codable, Equatable, Sendable {
    public let summary: BusinessDocumentStudioSummary
    public let registryRoles: [DocumentFormatRegistrationRole]
    public let parseLimitBytes: Int64
    public let security: DocumentSecurityMetadata
    public let preview: BusinessDocumentStudioPreview
    public let exportOptions: [BusinessDocumentStudioExportOption]
}

public struct BusinessDocumentStudioSummary: Codable, Equatable, Sendable {
    public let filename: String
    public let formatId: String
    public let representationFormatId: String
    public let fileExtension: String?
    public let kind: BusinessDocumentKind
    public let fileSize: Int64
    public let structureSummary: DocumentStructureSummary
    public let textFallbackUTF16Length: Int
    public let createdAt: Date

    public init(document: StructuredDocument) {
        let fileExtension =
            document.security.fileExtension
            ?? URL(fileURLWithPath: document.filename).pathExtension.lowercasedNonEmpty
        self.filename = document.filename
        self.formatId = document.formatId
        self.representationFormatId = document.representation.formatId
        self.fileExtension = fileExtension
        self.kind = BusinessDocumentKind.infer(formatId: document.formatId, fileExtension: fileExtension)
        self.fileSize = document.fileSize
        self.structureSummary = document.structure.businessSummary
        self.textFallbackUTF16Length = document.textFallback.utf16.count
        self.createdAt = document.createdAt
    }
}

public enum BusinessDocumentStudioPreview: Codable, Equatable, Sendable {
    case table(CSVTablePreview)
    case workbook(BusinessDocumentWorkbookPreview)
    case pdf(BusinessDocumentPDFPreview)
    case presentation(BusinessDocumentPresentationPreview)
    case richText(BusinessDocumentRichTextPreview)
    case text(BusinessDocumentTextPreview)
}

public struct BusinessDocumentWorkbookPreview: Codable, Equatable, Sendable {
    public let inspection: WorkbookWorkflowInspection
    public let sheets: [BusinessDocumentWorkbookSheetPreview]
    public let isSheetSampleTruncated: Bool
}

public struct BusinessDocumentWorkbookSheetPreview: Codable, Equatable, Sendable {
    public let name: String
    public let index: Int
    public let rowCount: Int
    public let cellCount: Int
    public let formulaCellCount: Int
    public let mergedRangeCount: Int
    public let maxColumn: Int
    public let sampleRows: [BusinessDocumentWorkbookRowPreview]
    public let isRowSampleTruncated: Bool
    public let isColumnSampleTruncated: Bool
}

public struct BusinessDocumentWorkbookRowPreview: Codable, Equatable, Sendable {
    public let number: Int
    public let cells: [BusinessDocumentWorkbookCellPreview]
    public let isCellSampleTruncated: Bool
}

public struct BusinessDocumentWorkbookCellPreview: Codable, Equatable, Sendable {
    public let reference: String
    public let rowNumber: Int
    public let columnNumber: Int
    public let text: BusinessDocumentTextPreview
    public let hasFormula: Bool
    public let anchorId: String
}

public struct BusinessDocumentPDFPreview: Codable, Equatable, Sendable {
    public let filename: String
    public let pageCount: Int
    public let sampledPageCount: Int
    public let totalTextUTF16Units: Int
    public let tableCount: Int
    public let tableCellCount: Int
    public let pages: [BusinessDocumentPDFPagePreview]
    public let isPageSampleTruncated: Bool
    public let creationAvailability: BusinessDocumentCreationAvailability
}

public struct BusinessDocumentPDFPagePreview: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let anchorId: String
    public let bounds: DocumentBoundingBox?
    public let text: BusinessDocumentTextPreview
    public let tableCount: Int
    public let tables: [BusinessDocumentTablePreview]
    public let isTableSampleTruncated: Bool
}

public struct BusinessDocumentPresentationPreview: Codable, Equatable, Sendable {
    public let filename: String
    public let kind: PresentationDocumentKind
    public let slideCount: Int
    public let sampledSlideCount: Int
    public let hiddenSlideCount: Int
    public let speakerNotesCount: Int
    public let totalTextUTF16Units: Int
    public let tableCount: Int
    public let tableCellCount: Int
    public let slides: [BusinessDocumentPresentationSlidePreview]
    public let isSlideSampleTruncated: Bool
    public let creationAvailability: BusinessDocumentCreationAvailability
}

public struct BusinessDocumentPresentationSlidePreview: Codable, Equatable, Sendable {
    public let slideIndex: Int
    public let slideNumber: Int
    public let label: String
    public let sourcePart: String
    public let isHidden: Bool
    public let text: BusinessDocumentTextPreview
    public let speakerNotes: BusinessDocumentTextPreview?
    public let tableCount: Int
    public let tables: [BusinessDocumentTablePreview]
    public let isTableSampleTruncated: Bool
}

public struct BusinessDocumentTablePreview: Codable, Equatable, Sendable {
    public let sourceKind: BusinessDocumentTableSourceKind
    public let sourceIndex: Int
    public let index: Int
    public let anchorId: String
    public let rowCount: Int
    public let columnCount: Int
    public let cellCount: Int
    public let bounds: DocumentBoundingBox?
    public let sampleRows: [BusinessDocumentTableRowPreview]
    public let isRowSampleTruncated: Bool
    public let isColumnSampleTruncated: Bool
}

public enum BusinessDocumentTableSourceKind: String, Codable, Equatable, Sendable {
    case pdfPage
    case presentationSlide
}

public struct BusinessDocumentTableRowPreview: Codable, Equatable, Sendable {
    public let index: Int
    public let cells: [BusinessDocumentTableCellPreview]
    public let isCellSampleTruncated: Bool
}

public struct BusinessDocumentTableCellPreview: Codable, Equatable, Sendable {
    public let rowIndex: Int
    public let columnIndex: Int
    public let text: BusinessDocumentTextPreview
    public let anchorId: String
}

public struct BusinessDocumentRichTextPreview: Codable, Equatable, Sendable {
    public let sourceFormat: RichDocumentSourceFormat
    public let sourceLabel: String
    public let text: BusinessDocumentTextPreview
    public let sampledBlocks: [BusinessDocumentRichTextBlockPreview]
    public let blockCount: Int
    public let isBlockSampleTruncated: Bool
}

public struct BusinessDocumentRichTextBlockPreview: Codable, Equatable, Sendable {
    public let kind: RichDocumentBlock.Kind
    public let text: BusinessDocumentTextPreview
    public let sourceIndex: Int
    public let headingLevel: Int?
    public let listDepth: Int?
    public let anchorId: String
}

public struct BusinessDocumentTextPreview: Codable, Equatable, Sendable {
    public let text: String
    public let fullUTF16Length: Int
    public let isTruncated: Bool
}

public struct BusinessDocumentCreationAvailability: Codable, Equatable, Sendable {
    public let formatId: String
    public let reasonCode: BusinessDocumentCreationReasonCode
    public let emitterFormatId: String?
    public let message: String

    public var isAvailable: Bool { reasonCode == .available }
}

public enum BusinessDocumentCreationReasonCode: String, Codable, Equatable, Sendable {
    case available
    case missingEmitter
    case unsupportedFormat
}

public struct BusinessDocumentStudioExportOption: Codable, Equatable, Sendable {
    public let targetFormatId: String
    public let fileExtension: String
    public let label: String
    public let canExport: Bool
    public let reason: BusinessDocumentStudioExportReason
    public let message: String
}

public enum BusinessDocumentStudioExportReason: String, Codable, Equatable, Sendable {
    case available
    case missingEmitter
    case validationFailed
    case unsupportedFormat
    case textFallbackAvailable
    case textFallbackTooLarge
}

public struct BusinessDocumentStudioExportResult: Codable, Equatable, Sendable {
    public let url: URL
    public let sourceFormatId: String
    public let targetFormatId: String
    public let bytesWritten: Int64
    public let message: String
}

public enum BusinessDocumentStudioError: LocalizedError, Sendable {
    case unsupportedFormat(fileExtension: String)
    case adapterReturnedUnexpectedFormat(expected: String, actual: String)
    case unsupportedExport(sourceFormatId: String, targetFormatId: String)
    case destinationOutsideAllowedDirectory(URL)
    case destinationAlreadyExists(URL)
    case destinationIsNotFileURL(URL)
    case unsafeTextPackageTarget(fileExtension: String)
    case packageTargetExtensionMismatch(targetFormatId: String, fileExtension: String)
    case textExportTooLarge(actual: Int, limit: Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension):
            return "No document adapter is registered for .\(fileExtension)."
        case .adapterReturnedUnexpectedFormat(let expected, let actual):
            return "Document adapter '\(expected)' returned unexpected format '\(actual)'."
        case .unsupportedExport(let sourceFormatId, let targetFormatId):
            return "Cannot export document format '\(sourceFormatId)' as '\(targetFormatId)'."
        case .destinationOutsideAllowedDirectory(let url):
            return "Export destination is outside the allowed directory: \(url.path)"
        case .destinationAlreadyExists(let url):
            return "Export destination already exists: \(url.path)"
        case .destinationIsNotFileURL(let url):
            return "Export destination must be a local file URL: \(url.absoluteString)"
        case .unsafeTextPackageTarget(let fileExtension):
            return "Text fallback export cannot write structured package target .\(fileExtension)."
        case .packageTargetExtensionMismatch(let targetFormatId, let fileExtension):
            return "Export target '\(targetFormatId)' cannot write package extension .\(fileExtension)."
        case .textExportTooLarge(let actual, let limit):
            return "Text fallback export is \(actual) bytes, limit is \(limit) bytes."
        case .writeFailed(let message):
            return "Business document export failed: \(message)"
        }
    }
}

public struct BusinessDocumentStudioService: Sendable {
    private let registry: DocumentFormatRegistry

    public init(registry: DocumentFormatRegistry = .shared) {
        self.registry = registry
    }

    public func parse(url: URL) async throws -> StructuredDocument {
        let (adapter, limit) = try adapterAndLimit(for: url)
        return try await parse(url: url, adapter: adapter, limit: limit)
    }

    private func parse(
        url: URL,
        adapter: any DocumentFormatAdapter,
        limit: Int64
    ) async throws -> StructuredDocument {
        let document = try await adapter.parse(url: url, sizeLimit: limit)
        if document.formatId.lowercased() != adapter.formatId.lowercased() {
            throw BusinessDocumentStudioError.adapterReturnedUnexpectedFormat(
                expected: adapter.formatId,
                actual: document.formatId
            )
        }
        return document
    }

    public func inspect(
        url: URL,
        policy: BusinessDocumentStudioPolicy = .standard
    ) async throws -> BusinessDocumentStudioInspection {
        let (adapter, limit) = try adapterAndLimit(for: url)
        let document = try await parse(url: url, adapter: adapter, limit: limit)
        return try inspect(document, parseLimitBytes: limit, policy: policy)
    }

    private func adapterAndLimit(for url: URL) throws -> (adapter: any DocumentFormatAdapter, limit: Int64) {
        if registry === DocumentFormatRegistry.shared {
            DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        }

        let uti = UTType(filenameExtension: url.pathExtension.lowercased())?.identifier
        guard let adapter = registry.adapter(for: url, uti: uti) else {
            throw BusinessDocumentStudioError.unsupportedFormat(fileExtension: url.pathExtension.lowercased())
        }

        let limit = DocumentLimits.limit(forFormatId: adapter.formatId)
        return (adapter, limit)
    }

    public func inspect(
        _ document: StructuredDocument,
        parseLimitBytes: Int64? = nil,
        policy: BusinessDocumentStudioPolicy = .standard
    ) throws -> BusinessDocumentStudioInspection {
        let roles = registry.registrationRoles(forFormatId: document.formatId)
            .sorted { $0.rawValue < $1.rawValue }
        return BusinessDocumentStudioInspection(
            summary: BusinessDocumentStudioSummary(document: document),
            registryRoles: roles,
            parseLimitBytes: parseLimitBytes ?? DocumentLimits.limit(forFormatId: document.formatId),
            security: document.security,
            preview: try preview(for: document, policy: policy),
            exportOptions: exportOptions(for: document, policy: policy)
        )
    }

    public func export(
        _ document: StructuredDocument,
        as targetFormatId: String,
        to url: URL,
        policy: BusinessDocumentStudioExportPolicy = .standard
    ) async throws -> BusinessDocumentStudioExportResult {
        let normalizedTarget = targetFormatId.trimmedLowercased
        try validateDestination(url, policy: policy)

        switch normalizedTarget {
        case "csv", "tsv":
            try rejectTextExportPackageTarget(url)
            let delimiter: CSVDelimiter = normalizedTarget == "tsv" ? .tab : .comma
            let result = try await CSVTableWorkflowService.export(document, to: url, delimiter: delimiter)
            return BusinessDocumentStudioExportResult(
                url: result.url,
                sourceFormatId: document.formatId,
                targetFormatId: result.formatId,
                bytesWritten: result.bytesWritten,
                message: "Exported \(result.rowCount) row(s) and \(result.columnCount) column(s)."
            )

        case "xlsx":
            try validateStructuredPackageTarget(url, targetFormatId: normalizedTarget)
            let result = try await WorkbookWorkflowService.export(document, to: url, registry: registry)
            return BusinessDocumentStudioExportResult(
                url: result.url,
                sourceFormatId: document.formatId,
                targetFormatId: result.formatId,
                bytesWritten: result.bytesWritten,
                message: "Exported workbook through the registered '\(result.formatId)' emitter."
            )

        case "txt", "text", "plaintext":
            return try exportTextFallback(document, to: url, policy: policy)

        default:
            guard let emitter = registry.emitter(for: document),
                emitter.formatId.lowercased() == normalizedTarget
            else {
                throw BusinessDocumentStudioError.unsupportedExport(
                    sourceFormatId: document.formatId,
                    targetFormatId: normalizedTarget
                )
            }
            try validateEmitterPackageTarget(url, targetFormatId: emitter.formatId.trimmedLowercased)
            do {
                try await emitter.emit(document, to: url)
                return BusinessDocumentStudioExportResult(
                    url: url,
                    sourceFormatId: document.formatId,
                    targetFormatId: emitter.formatId,
                    bytesWritten: Self.fileSize(url),
                    message: "Exported document through the registered '\(emitter.formatId)' emitter."
                )
            } catch {
                throw BusinessDocumentStudioError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func preview(
        for document: StructuredDocument,
        policy: BusinessDocumentStudioPolicy
    ) throws -> BusinessDocumentStudioPreview {
        if document.representation.underlying is CSVDocument {
            return .table(try CSVTableWorkflowService.preview(document, policy: policy.csvPreview))
        }

        if let workbook = document.representation.underlying as? Workbook {
            let inspection = try WorkbookWorkflowService.inspect(
                document,
                registry: registry,
                policy: policy.workbookExport
            )
            return .workbook(
                workbookPreview(
                    workbook,
                    inspection: inspection,
                    policy: policy.workbookPreview
                )
            )
        }

        if let pdfPPTX = try? PDFPPTXWorkflowService(registry: registry)
            .preview(document, policy: policy.pdfPPTXPreview)
        {
            switch pdfPPTX {
            case .pdf(let preview):
                return .pdf(Self.pdfPreview(preview))
            case .presentation(let preview):
                return .presentation(Self.presentationPreview(preview))
            }
        }

        if let richText = document.representation.underlying as? RichDocumentRepresentation {
            return .richText(Self.richTextPreview(richText, policy: policy.textPreview))
        }

        return .text(Self.textPreview(document.textFallback, maxUTF16Units: policy.textPreview.maxTextUTF16Units))
    }

    private func exportOptions(
        for document: StructuredDocument,
        policy: BusinessDocumentStudioPolicy
    ) -> [BusinessDocumentStudioExportOption] {
        var options: [BusinessDocumentStudioExportOption] = []

        if let csv = document.representation.underlying as? CSVDocument {
            let issues = CSVTableWorkflowService.validationIssues(for: csv)
            let canExport = issues.isEmpty
            let reason: BusinessDocumentStudioExportReason = canExport ? .available : .validationFailed
            let message =
                canExport
                ? "CSV/TSV table can be exported through the delimited-text emitter."
                : "CSV/TSV export is blocked by \(issues.count) validation issue(s)."
            options.append(
                BusinessDocumentStudioExportOption(
                    targetFormatId: "csv",
                    fileExtension: "csv",
                    label: "CSV",
                    canExport: canExport,
                    reason: reason,
                    message: message
                )
            )
            options.append(
                BusinessDocumentStudioExportOption(
                    targetFormatId: "tsv",
                    fileExtension: "tsv",
                    label: "TSV",
                    canExport: canExport,
                    reason: reason,
                    message: message
                )
            )
        }

        if document.representation.underlying is Workbook {
            let availability =
                (try? WorkbookWorkflowService.inspect(
                    document,
                    registry: registry,
                    policy: policy.workbookExport
                ).exportAvailability)
                ?? WorkbookExportAvailability(
                    reason: .missingEmitter,
                    formatId: document.formatId,
                    message: "Workbook export availability could not be inspected."
                )
            options.append(
                BusinessDocumentStudioExportOption(
                    targetFormatId: "xlsx",
                    fileExtension: "xlsx",
                    label: "XLSX workbook",
                    canExport: availability.canExport,
                    reason: Self.workbookReason(availability.reason),
                    message: availability.message
                )
            )
        }

        let pdfPPTXAvailability = PDFPPTXWorkflowService(registry: registry).creationAvailability(for: document)
        if pdfPPTXAvailability.reasonCode != .unsupportedFormat {
            options.append(
                BusinessDocumentStudioExportOption(
                    targetFormatId: pdfPPTXAvailability.formatId,
                    fileExtension: pdfPPTXAvailability.formatId,
                    label: pdfPPTXAvailability.formatId.uppercased(),
                    canExport: pdfPPTXAvailability.isAvailable,
                    reason: Self.exportReason(pdfPPTXAvailability.reasonCode),
                    message: pdfPPTXAvailability.message
                )
            )
        }

        let fallbackSize = document.textFallback.utf8.count
        options.append(
            BusinessDocumentStudioExportOption(
                targetFormatId: "txt",
                fileExtension: "txt",
                label: "Text fallback",
                canExport: fallbackSize <= BusinessDocumentStudioExportPolicy.standard.maxTextExportUTF8Bytes,
                reason: fallbackSize <= BusinessDocumentStudioExportPolicy.standard.maxTextExportUTF8Bytes
                    ? .textFallbackAvailable
                    : .textFallbackTooLarge,
                message: "Exports the bounded text fallback carried by the parsed document."
            )
        )

        return options
    }

    private func workbookPreview(
        _ workbook: Workbook,
        inspection: WorkbookWorkflowInspection,
        policy: BusinessDocumentWorkbookPreviewPolicy
    ) -> BusinessDocumentWorkbookPreview {
        let sheets = workbook.sheets.prefix(policy.maxSheets).map { sheet in
            let sampledRows = sheet.rows.prefix(policy.maxRowsPerSheet).map { row in
                let cells = row.cells.prefix(policy.maxColumnsPerSheet).map { cell in
                    BusinessDocumentWorkbookCellPreview(
                        reference: cell.reference,
                        rowNumber: cell.rowNumber,
                        columnNumber: cell.columnNumber,
                        text: Self.textPreview(cell.value.fallbackText, maxUTF16Units: policy.maxCellTextUTF16Units),
                        hasFormula: cell.formula != nil,
                        anchorId: cell.anchor.id
                    )
                }
                return BusinessDocumentWorkbookRowPreview(
                    number: row.number,
                    cells: Array(cells),
                    isCellSampleTruncated: row.cells.count > policy.maxColumnsPerSheet
                )
            }
            let allCells = sheet.rows.flatMap(\.cells)
            return BusinessDocumentWorkbookSheetPreview(
                name: sheet.name,
                index: sheet.index,
                rowCount: sheet.rows.count,
                cellCount: allCells.count,
                formulaCellCount: allCells.filter { $0.formula != nil }.count,
                mergedRangeCount: sheet.mergedRanges.count,
                maxColumn: allCells.map(\.columnNumber).max() ?? 0,
                sampleRows: Array(sampledRows),
                isRowSampleTruncated: sheet.rows.count > policy.maxRowsPerSheet,
                isColumnSampleTruncated: sheet.rows.contains { $0.cells.count > policy.maxColumnsPerSheet }
            )
        }

        return BusinessDocumentWorkbookPreview(
            inspection: inspection,
            sheets: Array(sheets),
            isSheetSampleTruncated: workbook.sheets.count > policy.maxSheets
        )
    }

    private func validateDestination(
        _ url: URL,
        policy: BusinessDocumentStudioExportPolicy
    ) throws {
        guard url.isFileURL else {
            throw BusinessDocumentStudioError.destinationIsNotFileURL(url)
        }
        if let allowedDirectory = policy.allowedDirectory {
            let root = allowedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            guard parent == root || parent.hasPrefix(root + "/") else {
                throw BusinessDocumentStudioError.destinationOutsideAllowedDirectory(url)
            }
        }
        if !policy.allowOverwrite, FileManager.default.fileExists(atPath: url.path) {
            throw BusinessDocumentStudioError.destinationAlreadyExists(url)
        }
    }

    private func rejectTextExportPackageTarget(_ url: URL) throws {
        let extensionName = url.pathExtension.lowercased()
        guard Self.structuredPackageExtensions.contains(extensionName) else {
            return
        }
        throw BusinessDocumentStudioError.unsafeTextPackageTarget(fileExtension: extensionName)
    }

    private func validateStructuredPackageTarget(
        _ url: URL,
        targetFormatId: String
    ) throws {
        let extensionName = url.pathExtension.lowercased()
        guard Self.structuredPackageExtensions.contains(extensionName) else { return }
        guard let allowedExtensions = Self.structuredTargetExtensions[targetFormatId] else {
            throw BusinessDocumentStudioError.unsafeTextPackageTarget(fileExtension: extensionName)
        }
        guard allowedExtensions.contains(extensionName) else {
            throw BusinessDocumentStudioError.packageTargetExtensionMismatch(
                targetFormatId: targetFormatId,
                fileExtension: extensionName
            )
        }
    }

    private func validateEmitterPackageTarget(
        _ url: URL,
        targetFormatId: String
    ) throws {
        guard Self.structuredTargetExtensions[targetFormatId] != nil else {
            return
        }
        try validateStructuredPackageTarget(url, targetFormatId: targetFormatId)
    }

    private func exportTextFallback(
        _ document: StructuredDocument,
        to url: URL,
        policy: BusinessDocumentStudioExportPolicy
    ) throws -> BusinessDocumentStudioExportResult {
        try rejectTextExportPackageTarget(url)
        let data = Data(document.textFallback.utf8)
        guard data.count <= policy.maxTextExportUTF8Bytes else {
            throw BusinessDocumentStudioError.textExportTooLarge(
                actual: data.count,
                limit: policy.maxTextExportUTF8Bytes
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return BusinessDocumentStudioExportResult(
                url: url,
                sourceFormatId: document.formatId,
                targetFormatId: "txt",
                bytesWritten: Int64(data.count),
                message: "Exported document text fallback."
            )
        } catch {
            throw BusinessDocumentStudioError.writeFailed(error.localizedDescription)
        }
    }

    private static func pdfPreview(_ preview: PDFWorkflowPreview) -> BusinessDocumentPDFPreview {
        BusinessDocumentPDFPreview(
            filename: preview.filename,
            pageCount: preview.pageCount,
            sampledPageCount: preview.sampledPageCount,
            totalTextUTF16Units: preview.totalTextUTF16Units,
            tableCount: preview.tableCount,
            tableCellCount: preview.tableCellCount,
            pages: preview.pages.map { page in
                BusinessDocumentPDFPagePreview(
                    pageIndex: page.pageIndex,
                    anchorId: page.anchorId,
                    bounds: page.bounds,
                    text: textPreview(page.text),
                    tableCount: page.tableCount,
                    tables: page.tables.map(tablePreview),
                    isTableSampleTruncated: page.isTableSampleTruncated
                )
            },
            isPageSampleTruncated: preview.isPageSampleTruncated,
            creationAvailability: creationAvailability(preview.creationAvailability)
        )
    }

    private static func presentationPreview(
        _ preview: PresentationWorkflowPreview
    ) -> BusinessDocumentPresentationPreview {
        BusinessDocumentPresentationPreview(
            filename: preview.filename,
            kind: preview.kind,
            slideCount: preview.slideCount,
            sampledSlideCount: preview.sampledSlideCount,
            hiddenSlideCount: preview.hiddenSlideCount,
            speakerNotesCount: preview.speakerNotesCount,
            totalTextUTF16Units: preview.totalTextUTF16Units,
            tableCount: preview.tableCount,
            tableCellCount: preview.tableCellCount,
            slides: preview.slides.map { slide in
                BusinessDocumentPresentationSlidePreview(
                    slideIndex: slide.slideIndex,
                    slideNumber: slide.slideNumber,
                    label: slide.label,
                    sourcePart: slide.sourcePart,
                    isHidden: slide.isHidden,
                    text: textPreview(slide.text),
                    speakerNotes: slide.speakerNotes.map(textPreview),
                    tableCount: slide.tableCount,
                    tables: slide.tables.map(tablePreview),
                    isTableSampleTruncated: slide.isTableSampleTruncated
                )
            },
            isSlideSampleTruncated: preview.isSlideSampleTruncated,
            creationAvailability: creationAvailability(preview.creationAvailability)
        )
    }

    private static func tablePreview(_ preview: PDFPPTXTablePreview) -> BusinessDocumentTablePreview {
        BusinessDocumentTablePreview(
            sourceKind: preview.sourceKind == .pdfPage ? .pdfPage : .presentationSlide,
            sourceIndex: preview.sourceIndex,
            index: preview.index,
            anchorId: preview.anchorId,
            rowCount: preview.rowCount,
            columnCount: preview.columnCount,
            cellCount: preview.cellCount,
            bounds: preview.bounds,
            sampleRows: preview.sampleRows.map { row in
                BusinessDocumentTableRowPreview(
                    index: row.index,
                    cells: row.cells.map { cell in
                        BusinessDocumentTableCellPreview(
                            rowIndex: cell.rowIndex,
                            columnIndex: cell.columnIndex,
                            text: textPreview(cell.text),
                            anchorId: cell.anchorId
                        )
                    },
                    isCellSampleTruncated: row.isCellSampleTruncated
                )
            },
            isRowSampleTruncated: preview.isRowSampleTruncated,
            isColumnSampleTruncated: preview.isColumnSampleTruncated
        )
    }

    private static func richTextPreview(
        _ richText: RichDocumentRepresentation,
        policy: BusinessDocumentTextPreviewPolicy
    ) -> BusinessDocumentRichTextPreview {
        let blocks = richText.blocks.prefix(policy.maxRichBlocks).map { block in
            BusinessDocumentRichTextBlockPreview(
                kind: block.kind,
                text: textPreview(block.text, maxUTF16Units: policy.maxBlockTextUTF16Units),
                sourceIndex: block.sourceIndex,
                headingLevel: block.headingLevel,
                listDepth: block.listDepth,
                anchorId: block.anchorId
            )
        }
        return BusinessDocumentRichTextPreview(
            sourceFormat: richText.sourceFormat,
            sourceLabel: richText.sourceLabel,
            text: textPreview(richText.text, maxUTF16Units: policy.maxTextUTF16Units),
            sampledBlocks: Array(blocks),
            blockCount: richText.blocks.count,
            isBlockSampleTruncated: richText.blocks.count > policy.maxRichBlocks
        )
    }

    private static func textPreview(_ preview: PDFPPTXTextPreview) -> BusinessDocumentTextPreview {
        BusinessDocumentTextPreview(
            text: preview.text,
            fullUTF16Length: preview.fullUTF16Length,
            isTruncated: preview.isTruncated
        )
    }

    private static func textPreview(_ text: String, maxUTF16Units: Int) -> BusinessDocumentTextPreview {
        let fullLength = text.utf16.count
        guard fullLength > maxUTF16Units else {
            return BusinessDocumentTextPreview(text: text, fullUTF16Length: fullLength, isTruncated: false)
        }

        var clipped = ""
        var units = 0
        for character in text {
            let nextUnits = String(character).utf16.count
            guard units + nextUnits <= maxUTF16Units else { break }
            clipped.append(character)
            units += nextUnits
        }
        return BusinessDocumentTextPreview(text: clipped, fullUTF16Length: fullLength, isTruncated: true)
    }

    private static func creationAvailability(
        _ availability: PDFPPTXCreationAvailability
    ) -> BusinessDocumentCreationAvailability {
        BusinessDocumentCreationAvailability(
            formatId: availability.formatId,
            reasonCode: Self.creationReason(availability.reasonCode),
            emitterFormatId: availability.emitterFormatId,
            message: availability.message
        )
    }

    private static func creationReason(
        _ reason: PDFPPTXCreationReasonCode
    ) -> BusinessDocumentCreationReasonCode {
        switch reason {
        case .available: return .available
        case .missingEmitter: return .missingEmitter
        case .unsupportedFormat: return .unsupportedFormat
        }
    }

    private static func exportReason(
        _ reason: PDFPPTXCreationReasonCode
    ) -> BusinessDocumentStudioExportReason {
        switch reason {
        case .available: return .available
        case .missingEmitter: return .missingEmitter
        case .unsupportedFormat: return .unsupportedFormat
        }
    }

    private static func workbookReason(
        _ reason: WorkbookExportAvailability.Reason
    ) -> BusinessDocumentStudioExportReason {
        switch reason {
        case .available: return .available
        case .missingEmitter, .notChecked: return .missingEmitter
        case .invalidWorkbook: return .validationFailed
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static let structuredPackageExtensions: Set<String> = [
        "xlsx", "xlsm", "xltx", "xltm", "pdf", "pptx", "pptm", "potx", "potm", "ppsx", "ppsm",
    ]

    private static let structuredTargetExtensions: [String: Set<String>] = [
        "xlsx": ["xlsx"],
        "pdf": ["pdf"],
        "pptx": ["pptx", "pptm", "potx", "potm", "ppsx", "ppsm"],
        "potx": ["pptx", "potx"],
    ]
}

private extension String {
    var trimmedLowercased: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var lowercasedNonEmpty: String? {
        let value = trimmedLowercased
        return value.isEmpty ? nil : value
    }
}
