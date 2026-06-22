//
//  BusinessDocumentStudioPresenter.swift
//  osaurus
//
//  Thin presentation layer for the Business Document Studio surface.
//  BusinessDocumentStudioService remains the authority for parsing,
//  availability, and destination safety.
//

import Combine
import Foundation

@MainActor
final class BusinessDocumentStudioPresenter: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading(URL?)
        case loaded(BusinessDocumentStudioPresentation)
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case exporting(optionID: String)
        case succeeded(BusinessDocumentStudioExportReceipt)
        case blocked(BusinessDocumentStudioExportBlock)
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var exportState: ExportState = .idle

    private let service: BusinessDocumentStudioService
    private var document: StructuredDocument?
    private var inspection: BusinessDocumentStudioInspection?

    init(service: BusinessDocumentStudioService = BusinessDocumentStudioService()) {
        self.service = service
    }

    func load(
        url: URL,
        policy: BusinessDocumentStudioPolicy = .standard
    ) async {
        loadState = .loading(url)
        exportState = .idle

        do {
            let document = try await service.parse(url: url)
            try load(document: document, policy: policy)
        } catch {
            self.document = nil
            inspection = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    func load(
        document: StructuredDocument,
        policy: BusinessDocumentStudioPolicy = .standard
    ) throws {
        let inspection = try service.inspect(document, policy: policy)
        self.document = document
        self.inspection = inspection
        loadState = .loaded(BusinessDocumentStudioPresentation(inspection: inspection))
        exportState = .idle
    }

    func export(
        optionID: String,
        to destination: URL,
        allowedDirectory: URL? = nil,
        allowOverwrite: Bool = false,
        maxTextExportUTF8Bytes: Int = BusinessDocumentStudioExportPolicy.standard.maxTextExportUTF8Bytes
    ) async {
        guard let document, let inspection else {
            exportState = .failed("No document is loaded.")
            return
        }

        guard let option = inspection.exportOptions.first(where: { $0.targetFormatId == optionID }) else {
            exportState = .failed("Export option '\(optionID)' is not available for this document.")
            return
        }

        guard option.canExport else {
            exportState = .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .unavailableOption,
                    optionID: option.targetFormatId,
                    message: option.message,
                    path: nil,
                    reason: option.reason
                )
            )
            return
        }

        exportState = .exporting(optionID: option.targetFormatId)

        do {
            let result = try await service.export(
                document,
                as: option.targetFormatId,
                to: destination,
                policy: BusinessDocumentStudioExportPolicy(
                    allowedDirectory: allowedDirectory,
                    allowOverwrite: allowOverwrite,
                    maxTextExportUTF8Bytes: maxTextExportUTF8Bytes
                )
            )
            exportState = .succeeded(BusinessDocumentStudioExportReceipt(result: result))
        } catch let error as BusinessDocumentStudioError {
            exportState = mapServiceError(error, optionID: option.targetFormatId)
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    private func mapServiceError(
        _ error: BusinessDocumentStudioError,
        optionID: String
    ) -> ExportState {
        switch error {
        case .destinationAlreadyExists(let url):
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .destinationAlreadyExists,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: url.path,
                    reason: nil
                )
            )

        case .destinationOutsideAllowedDirectory(let url):
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .destinationOutsideAllowedDirectory,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: url.path,
                    reason: nil
                )
            )

        case .destinationIsNotFileURL(let url):
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .destinationIsNotFileURL,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: url.absoluteString,
                    reason: nil
                )
            )

        case .unsafeTextPackageTarget(let fileExtension):
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .unsafePackageTarget,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: fileExtension,
                    reason: nil
                )
            )

        case .packageTargetExtensionMismatch(_, let fileExtension):
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .packageExtensionMismatch,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: fileExtension,
                    reason: nil
                )
            )

        case .textExportTooLarge:
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .textFallbackTooLarge,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: nil,
                    reason: .textFallbackTooLarge
                )
            )

        case .unsupportedExport:
            return .blocked(
                BusinessDocumentStudioExportBlock(
                    kind: .unsupportedExport,
                    optionID: optionID,
                    message: error.localizedDescription,
                    path: nil,
                    reason: .unsupportedFormat
                )
            )

        case .unsupportedFormat,
             .adapterReturnedUnexpectedFormat,
             .writeFailed:
            return .failed(error.localizedDescription)
        }
    }
}

struct BusinessDocumentStudioPresentation: Equatable {
    let title: String
    let subtitle: String
    let iconSystemName: String
    let summaryRows: [BusinessDocumentStudioInfoRow]
    let structureRows: [BusinessDocumentStudioInfoRow]
    let securityRows: [BusinessDocumentStudioInfoRow]
    let previewRows: [BusinessDocumentStudioInfoRow]
    let previewSections: [BusinessDocumentStudioPreviewSection]
    let warnings: [BusinessDocumentStudioWarning]
    let exportOptions: [BusinessDocumentStudioExportOptionPresentation]
    let registryRoleLabels: [String]

    init(inspection: BusinessDocumentStudioInspection) {
        let summary = inspection.summary
        title = summary.filename
        subtitle = "\(summary.kind.displayName) - \(summary.formatId.uppercased())"
        iconSystemName = summary.kind.systemImageName
        summaryRows = Self.summaryRows(for: inspection)
        structureRows = Self.structureRows(for: summary.structureSummary)
        securityRows = Self.securityRows(for: inspection.security)
        previewRows = Self.previewRows(for: inspection.preview)
        previewSections = Self.previewSections(for: inspection.preview)
        warnings = Self.warnings(for: inspection)
        exportOptions = inspection.exportOptions.map(BusinessDocumentStudioExportOptionPresentation.init(option:))
        registryRoleLabels = inspection.registryRoles.map(Self.roleLabel)
    }

    var availableExportOptions: [BusinessDocumentStudioExportOptionPresentation] {
        exportOptions.filter(\.canExport)
    }

    var unavailableExportOptions: [BusinessDocumentStudioExportOptionPresentation] {
        exportOptions.filter { !$0.canExport }
    }

    private static func summaryRows(
        for inspection: BusinessDocumentStudioInspection
    ) -> [BusinessDocumentStudioInfoRow] {
        let summary = inspection.summary
        var pairs = [
            ("Kind", summary.kind.displayName),
            ("Source format", summary.formatId),
            ("Representation", summary.representationFormatId),
            ("File size", fileSizeLabel(summary.fileSize)),
            ("Parse limit", fileSizeLabel(inspection.parseLimitBytes)),
            ("Text fallback", countLabel(summary.textFallbackUTF16Length, "UTF-16 unit")),
        ]
        if let fileExtension = summary.fileExtension {
            pairs.insert(("Extension", ".\(fileExtension)"), at: 3)
        }
        return numberedRows(prefix: "summary", pairs)
    }

    private static func structureRows(
        for summary: DocumentStructureSummary
    ) -> [BusinessDocumentStudioInfoRow] {
        numberedRows(prefix: "structure", [
            ("Sheets", "\(summary.sheetCount)"),
            ("Slides", "\(summary.slideCount)"),
            ("Pages", "\(summary.pageCount)"),
            ("Tables", "\(summary.tableCount)"),
            ("Images", "\(summary.imageCount)"),
            ("Charts", "\(summary.chartCount)"),
            ("Text length", countLabel(summary.textLengthUTF16, "UTF-16 unit")),
        ])
    }

    private static func securityRows(
        for security: DocumentSecurityMetadata
    ) -> [BusinessDocumentStudioInfoRow] {
        var pairs = [
            ("Inspection", inspectionLabel(security.inspectionStatus)),
            ("Source trust", sourceTrustLabel(security.sourceTrust)),
            ("Active content", security.activeContentTypes.isEmpty ? "None" : activeContentLabel(security.activeContentTypes)),
            ("External references", "\(security.externalReferences.count)"),
            ("Findings", "\(security.findings.count)"),
        ]
        if let isEncrypted = security.isEncrypted {
            pairs.append(("Encrypted", isEncrypted ? "Yes" : "No"))
        }
        if let sha256 = security.sha256, !sha256.isEmpty {
            pairs.append(("SHA-256", sha256))
        }
        return numberedRows(prefix: "security", pairs)
    }

    private static func previewRows(
        for preview: BusinessDocumentStudioPreview
    ) -> [BusinessDocumentStudioInfoRow] {
        switch preview {
        case .table(let table):
            return numberedRows(prefix: "preview-table", [
                ("Preview", "Delimited table"),
                ("Delimiter", table.delimiter == .tab ? "Tab" : "Comma"),
                ("Rows scanned", "\(table.rowsScanned)"),
                ("Sampled rows", "\(table.sampledRowCount)"),
                ("Columns", "\(table.columnCount)"),
                ("Header", table.hasHeader ? "Detected" : "Not detected"),
            ])

        case .workbook(let workbook):
            return numberedRows(prefix: "preview-workbook", [
                ("Preview", "Workbook"),
                ("Sheets", "\(workbook.inspection.sheetSummaries.count)"),
                ("Rows", "\(workbook.inspection.totalRows)"),
                ("Cells", "\(workbook.inspection.totalCells)"),
                ("Formula cells", "\(workbook.inspection.formulaCellCount)"),
                ("Merged ranges", "\(workbook.inspection.mergedRangeCount)"),
            ])

        case .pdf(let pdf):
            return numberedRows(prefix: "preview-pdf", [
                ("Preview", "PDF"),
                ("Pages", "\(pdf.pageCount)"),
                ("Sampled pages", "\(pdf.sampledPageCount)"),
                ("Tables", "\(pdf.tableCount)"),
                ("Table cells", "\(pdf.tableCellCount)"),
                ("Text length", countLabel(pdf.totalTextUTF16Units, "UTF-16 unit")),
            ])

        case .presentation(let presentation):
            return numberedRows(prefix: "preview-presentation", [
                ("Preview", "Presentation"),
                ("Slides", "\(presentation.slideCount)"),
                ("Sampled slides", "\(presentation.sampledSlideCount)"),
                ("Hidden slides", "\(presentation.hiddenSlideCount)"),
                ("Speaker notes", "\(presentation.speakerNotesCount)"),
                ("Tables", "\(presentation.tableCount)"),
            ])

        case .richText(let richText):
            return numberedRows(prefix: "preview-rich-text", [
                ("Preview", "Rich text"),
                ("Source", richText.sourceLabel),
                ("Blocks", "\(richText.blockCount)"),
                ("Sampled blocks", "\(richText.sampledBlocks.count)"),
                ("Text length", countLabel(richText.text.fullUTF16Length, "UTF-16 unit")),
            ])

        case .text(let text):
            return numberedRows(prefix: "preview-text", [
                ("Preview", "Text fallback"),
                ("Text length", countLabel(text.fullUTF16Length, "UTF-16 unit")),
                ("Truncated", text.isTruncated ? "Yes" : "No"),
            ])
        }
    }

    private static func previewSections(
        for preview: BusinessDocumentStudioPreview
    ) -> [BusinessDocumentStudioPreviewSection] {
        switch preview {
        case .table(let table):
            let header = BusinessDocumentStudioPreviewSection(
                id: "table-columns",
                title: "Columns",
                rows: table.columns.enumerated().map { offset, column in
                    BusinessDocumentStudioInfoRow(
                        id: "table-column-\(offset)",
                        label: column.name,
                        value: "\(column.inferredType.rawValue) - \(column.nonEmptyCount) filled"
                    )
                }
            )
            let samples = BusinessDocumentStudioPreviewSection(
                id: "table-sample-rows",
                title: "Sample rows",
                rows: table.sampledRows.prefix(8).enumerated().map { offset, row in
                    BusinessDocumentStudioInfoRow(
                        id: "table-sample-row-\(offset)",
                        label: "Row \(row.rowIndex + 1)",
                        value: row.values.joined(separator: " | ")
                    )
                }
            )
            return [header, samples].filter { !$0.rows.isEmpty }

        case .workbook(let workbook):
            return workbook.sheets.enumerated().map { sheetOffset, sheet in
                var rows = numberedRows(prefix: "workbook-sheet-\(sheetOffset)", [
                    ("Rows", "\(sheet.rowCount)"),
                    ("Cells", "\(sheet.cellCount)"),
                    ("Formula cells", "\(sheet.formulaCellCount)"),
                    ("Merged ranges", "\(sheet.mergedRangeCount)"),
                ])
                rows.append(
                    contentsOf: sheet.sampleRows.prefix(6).enumerated().map { rowOffset, row in
                        BusinessDocumentStudioInfoRow(
                            id: "workbook-sheet-\(sheetOffset)-sample-row-\(rowOffset)",
                            label: "Row \(row.number)",
                            value: row.cells.map { cell in
                                "\(cell.reference): \(cell.text.text)"
                            }.joined(separator: " | ")
                        )
                    }
                )
                return BusinessDocumentStudioPreviewSection(
                    id: "workbook-sheet-\(sheetOffset)",
                    title: sheet.name,
                    rows: rows
                )
            }

        case .pdf(let pdf):
            return pdf.pages.enumerated().map { offset, page in
                BusinessDocumentStudioPreviewSection(
                    id: "pdf-page-\(offset)",
                    title: "Page \(page.pageIndex + 1)",
                    rows: numberedRows(prefix: "pdf-page-\(offset)", [
                        ("Text", page.text.text),
                        ("Tables", "\(page.tableCount)"),
                    ])
                )
            }

        case .presentation(let presentation):
            return presentation.slides.enumerated().map { offset, slide in
                BusinessDocumentStudioPreviewSection(
                    id: "presentation-slide-\(offset)",
                    title: slide.label,
                    rows: numberedRows(prefix: "presentation-slide-\(offset)", [
                        ("Slide", "\(slide.slideNumber)"),
                        ("Hidden", slide.isHidden ? "Yes" : "No"),
                        ("Text", slide.text.text),
                        ("Tables", "\(slide.tableCount)"),
                    ])
                )
            }

        case .richText(let richText):
            return [
                BusinessDocumentStudioPreviewSection(
                    id: "rich-text-blocks",
                    title: "Blocks",
                    rows: richText.sampledBlocks.enumerated().map { offset, block in
                        BusinessDocumentStudioInfoRow(
                            id: "rich-text-block-\(offset)",
                            label: block.kind.rawValue,
                            value: block.text.text
                        )
                    }
                ),
            ]

        case .text(let text):
            return [
                BusinessDocumentStudioPreviewSection(
                    id: "text-sample",
                    title: "Text",
                    rows: [BusinessDocumentStudioInfoRow(id: "text-sample-row", label: "Sample", value: text.text)]
                ),
            ]
        }
    }

    private static func warnings(
        for inspection: BusinessDocumentStudioInspection
    ) -> [BusinessDocumentStudioWarning] {
        var warnings: [BusinessDocumentStudioWarning] = []
        let security = inspection.security

        if security.inspectionStatus != .inspected {
            warnings.append(
                BusinessDocumentStudioWarning(
                    severity: .caution,
                    title: "Extraction inspection",
                    message: "Security inspection is \(inspectionLabel(security.inspectionStatus).lowercased())."
                )
            )
        }

        if let isEncrypted = security.isEncrypted, isEncrypted {
            warnings.append(
                BusinessDocumentStudioWarning(
                    severity: .caution,
                    title: "Encrypted content",
                    message: "The adapter reported encrypted content in this document."
                )
            )
        }

        if !security.activeContentTypes.isEmpty {
            warnings.append(
                BusinessDocumentStudioWarning(
                    severity: .caution,
                    title: "Active content",
                    message: activeContentLabel(security.activeContentTypes)
                )
            )
        }

        if !security.externalReferences.isEmpty {
            warnings.append(
                BusinessDocumentStudioWarning(
                    severity: .caution,
                    title: "External references",
                    message: "\(security.externalReferences.count) external reference(s) were recorded."
                )
            )
        }

        warnings.append(contentsOf: security.findings.map { finding in
            BusinessDocumentStudioWarning(
                severity: warningSeverity(for: finding.severity),
                title: finding.kind.rawValue,
                message: finding.message
            )
        })

        warnings.append(contentsOf: previewWarnings(for: inspection.preview))
        warnings.append(
            contentsOf: inspection.exportOptions.filter { !$0.canExport }.map { option in
                BusinessDocumentStudioWarning(
                    severity: .blocked,
                    title: "Export unavailable: \(option.label)",
                    message: "\(exportReasonLabel(option.reason)) - \(option.message)"
                )
            }
        )

        return warnings
    }

    private static func previewWarnings(
        for preview: BusinessDocumentStudioPreview
    ) -> [BusinessDocumentStudioWarning] {
        switch preview {
        case .table(let table):
            var messages: [String] = []
            if table.truncatedByByteLimit { messages.append("byte limit") }
            if table.truncatedByRowLimit { messages.append("row limit") }
            if table.truncatedByColumnLimit { messages.append("column limit") }
            return truncationWarnings(messages)

        case .workbook(let workbook):
            var messages: [String] = []
            if workbook.isSheetSampleTruncated { messages.append("sheet limit") }
            if workbook.sheets.contains(where: \.isRowSampleTruncated) { messages.append("row limit") }
            if workbook.sheets.contains(where: \.isColumnSampleTruncated) { messages.append("column limit") }
            return truncationWarnings(messages)

        case .pdf(let pdf):
            return truncationWarnings(pdf.isPageSampleTruncated ? ["page limit"] : [])

        case .presentation(let presentation):
            return truncationWarnings(presentation.isSlideSampleTruncated ? ["slide limit"] : [])

        case .richText(let richText):
            var messages: [String] = []
            if richText.isBlockSampleTruncated { messages.append("block limit") }
            if richText.text.isTruncated { messages.append("text limit") }
            return truncationWarnings(messages)

        case .text(let text):
            return truncationWarnings(text.isTruncated ? ["text limit"] : [])
        }
    }

    private static func truncationWarnings(_ reasons: [String]) -> [BusinessDocumentStudioWarning] {
        guard !reasons.isEmpty else { return [] }
        return [
            BusinessDocumentStudioWarning(
                severity: .info,
                title: "Preview truncated",
                message: "The preview sample reached the \(reasons.joined(separator: ", "))."
            ),
        ]
    }

    private static func warningSeverity(
        for severity: DocumentSecurityFinding.Severity
    ) -> BusinessDocumentStudioWarning.Severity {
        switch severity {
        case .informational, .low:
            return .info
        case .medium:
            return .caution
        case .high, .critical:
            return .blocked
        }
    }

    private static func roleLabel(_ role: DocumentFormatRegistrationRole) -> String {
        switch role {
        case .adapter: return "Adapter"
        case .emitter: return "Emitter"
        case .streamer: return "Streamer"
        }
    }

    private static func inspectionLabel(_ status: DocumentSecurityMetadata.InspectionStatus) -> String {
        switch status {
        case .inspected: return "Inspected"
        case .partiallyInspected: return "Partially inspected"
        case .notInspected: return "Not inspected"
        case .failed: return "Failed"
        }
    }

    private static func sourceTrustLabel(_ sourceTrust: DocumentSecurityMetadata.SourceTrust) -> String {
        switch sourceTrust {
        case .userSelectedLocalFile: return "User-selected local file"
        case .generatedArtifact: return "Generated artifact"
        case .pluginProvided: return "Plugin-provided"
        case .remoteDownload: return "Remote download"
        case .pastedContent: return "Pasted content"
        case .unknown: return "Unknown"
        }
    }

    private static func activeContentLabel(_ contentTypes: Set<DocumentActiveContentType>) -> String {
        contentTypes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
    }

    fileprivate static func exportReasonLabel(_ reason: BusinessDocumentStudioExportReason) -> String {
        switch reason {
        case .available: return "Ready"
        case .missingEmitter: return "Missing emitter"
        case .validationFailed: return "Validation failed"
        case .unsupportedFormat: return "Unsupported format"
        case .textFallbackAvailable: return "Text fallback"
        case .textFallbackTooLarge: return "Text fallback too large"
        }
    }

    private static func fileSizeLabel(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func numberedRows(
        prefix: String,
        _ pairs: [(label: String, value: String)]
    ) -> [BusinessDocumentStudioInfoRow] {
        pairs.enumerated().map { offset, pair in
            BusinessDocumentStudioInfoRow(
                id: "\(prefix)-\(offset)",
                label: pair.label,
                value: pair.value
            )
        }
    }
}

struct BusinessDocumentStudioInfoRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? "\(label):\(value)"
        self.label = label
        self.value = value
    }

    static func == (lhs: BusinessDocumentStudioInfoRow, rhs: BusinessDocumentStudioInfoRow) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
    }
}

struct BusinessDocumentStudioPreviewSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [BusinessDocumentStudioInfoRow]

    init(id: String? = nil, title: String, rows: [BusinessDocumentStudioInfoRow]) {
        self.id = id ?? title
        self.title = title
        self.rows = rows
    }
}

struct BusinessDocumentStudioWarning: Identifiable, Equatable {
    enum Severity: String, Equatable {
        case info
        case caution
        case blocked
    }

    let id: String
    let severity: Severity
    let title: String
    let message: String

    init(severity: Severity, title: String, message: String) {
        id = "\(severity.rawValue):\(title):\(message)"
        self.severity = severity
        self.title = title
        self.message = message
    }
}

struct BusinessDocumentStudioExportOptionPresentation: Identifiable, Equatable {
    let id: String
    let targetFormatId: String
    let fileExtension: String
    let label: String
    let canExport: Bool
    let reason: BusinessDocumentStudioExportReason
    let reasonLabel: String
    let statusLabel: String
    let message: String

    init(option: BusinessDocumentStudioExportOption) {
        id = option.targetFormatId
        targetFormatId = option.targetFormatId
        fileExtension = option.fileExtension
        label = option.label
        canExport = option.canExport
        reason = option.reason
        reasonLabel = BusinessDocumentStudioPresentation.exportReasonLabel(option.reason)
        statusLabel = option.canExport ? "Available" : "Unavailable"
        message = option.message
    }
}

struct BusinessDocumentStudioExportReceipt: Equatable {
    let url: URL
    let sourceFormatId: String
    let targetFormatId: String
    let bytesWritten: Int64
    let message: String

    init(result: BusinessDocumentStudioExportResult) {
        url = result.url
        sourceFormatId = result.sourceFormatId
        targetFormatId = result.targetFormatId
        bytesWritten = result.bytesWritten
        message = result.message
    }
}

struct BusinessDocumentStudioExportBlock: Equatable {
    enum Kind: String, Equatable {
        case unavailableOption
        case destinationAlreadyExists
        case destinationOutsideAllowedDirectory
        case destinationIsNotFileURL
        case unsafePackageTarget
        case packageExtensionMismatch
        case textFallbackTooLarge
        case unsupportedExport
    }

    let kind: Kind
    let optionID: String
    let message: String
    let path: String?
    let reason: BusinessDocumentStudioExportReason?
}
