//
//  BusinessDocumentSummary.swift
//  osaurus
//
//  Cheap, stable metadata for presenting parsed business files in chat
//  without requiring every UI surface to know each adapter's representation.
//

import Foundation

public enum BusinessDocumentKind: String, Codable, CaseIterable, Sendable {
    case workbook
    case table
    case presentation
    case pdf
    case richText
    case plainText
    case document
    case unknown

    public var displayName: String {
        switch self {
        case .workbook: return "Workbook"
        case .table: return "Table"
        case .presentation: return "Slides"
        case .pdf: return "PDF"
        case .richText: return "Document"
        case .plainText: return "Text"
        case .document: return "Document"
        case .unknown: return "File"
        }
    }

    public var systemImageName: String {
        switch self {
        case .workbook, .table: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .pdf: return "doc.richtext"
        case .richText: return "doc.text"
        case .plainText: return "text.document"
        case .document, .unknown: return "doc.plaintext"
        }
    }

    public static func infer(formatId: String?, fileExtension: String?) -> BusinessDocumentKind {
        let normalizedFormat = normalize(formatId)
        let ext = normalize(fileExtension)
        let token = normalizedFormat ?? ext ?? ""

        switch token {
        case "xlsx", "xlsm", "xltx", "xltm", "xlsb", "xls", "workbook":
            return .workbook
        case "csv", "tsv", "table":
            return .table
        case "pptx", "pptm", "potx", "potm", "ppsx", "ppsm", "ppt", "presentation":
            return .presentation
        case "pdf":
            return .pdf
        case "docx", "doc", "rtf", "rtfd", "html", "htm", "richtext":
            return .richText
        case "txt", "md", "markdown", "plain-text", "plaintext":
            return .plainText
        case "":
            return .unknown
        default:
            return .document
        }
    }

    private static func normalize(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct DocumentStructureSummary: Codable, Equatable, Hashable, Sendable {
    public let pageCount: Int
    public let slideCount: Int
    public let sheetCount: Int
    public let tableCount: Int
    public let imageCount: Int
    public let chartCount: Int
    public let textLengthUTF16: Int

    public init(
        pageCount: Int = 0,
        slideCount: Int = 0,
        sheetCount: Int = 0,
        tableCount: Int = 0,
        imageCount: Int = 0,
        chartCount: Int = 0,
        textLengthUTF16: Int = 0
    ) {
        self.pageCount = max(0, pageCount)
        self.slideCount = max(0, slideCount)
        self.sheetCount = max(0, sheetCount)
        self.tableCount = max(0, tableCount)
        self.imageCount = max(0, imageCount)
        self.chartCount = max(0, chartCount)
        self.textLengthUTF16 = max(0, textLengthUTF16)
    }

    public var primaryCountLabel: String? {
        if sheetCount > 0 { return Self.countLabel(sheetCount, singular: "sheet", plural: "sheets") }
        if slideCount > 0 { return Self.countLabel(slideCount, singular: "slide", plural: "slides") }
        if pageCount > 0 { return Self.countLabel(pageCount, singular: "page", plural: "pages") }
        if tableCount > 0 { return Self.countLabel(tableCount, singular: "table", plural: "tables") }
        return nil
    }

    private static func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

public struct BusinessDocumentSummary: Equatable, Sendable {
    public let filename: String
    public let formatId: String?
    public let representationFormatId: String?
    public let fileExtension: String?
    public let kind: BusinessDocumentKind
    public let fileSize: Int64?
    public let isStructured: Bool
    public let structureSummary: DocumentStructureSummary?
    public let inspectionStatus: DocumentSecurityMetadata.InspectionStatus?
    public let maximumSeverity: DocumentSecurityFinding.Severity?
    public let hasActiveContent: Bool

    public var displayName: String { kind.displayName }
    public var systemImageName: String { kind.systemImageName }

    public var chipDetailLabel: String {
        var pieces: [String] = [displayName]
        if let formatted = formattedFileSize {
            pieces.append(formatted)
        }
        return pieces.joined(separator: " - ")
    }

    public var contextAttributes: [(name: String, value: String)] {
        var attributes: [(String, String)] = [
            ("type", kind.rawValue),
            ("format", formatId ?? fileExtension ?? "unknown"),
            ("structured", isStructured ? "true" : "false"),
        ]
        if let inspectionStatus {
            attributes.append(("security", inspectionStatus.rawValue))
        }
        if hasActiveContent {
            attributes.append(("active_content", "true"))
        }
        if let primary = structureSummary?.primaryCountLabel {
            attributes.append(("structure", primary))
        }
        return attributes
    }

    private var formattedFileSize: String? {
        guard let fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public init?(_ attachment: Attachment) {
        guard attachment.isDocument else { return nil }

        let metadata = attachment.structuredDocumentMetadata
        let filename = attachment.filename ?? metadata?.filename ?? "Document"
        let extensionFromName = (filename as NSString).pathExtension.lowercased()
        let fileExtension = metadata?.fileExtension ?? (extensionFromName.isEmpty ? nil : extensionFromName)
        let formatId = metadata?.formatId ?? fileExtension
        let kind =
            metadata?.documentKind
            ?? BusinessDocumentKind.infer(
                formatId: formatId,
                fileExtension: fileExtension
            )

        self.filename = filename
        self.formatId = formatId
        self.representationFormatId = metadata?.representationFormatId
        self.fileExtension = fileExtension
        self.kind = kind
        self.fileSize = metadata?.fileSize ?? attachment.documentFileSize
        self.isStructured = metadata != nil
        self.structureSummary = metadata?.structureSummary
        self.inspectionStatus = metadata?.inspectionStatus
        self.maximumSeverity = metadata?.maximumSeverity
        self.hasActiveContent = metadata?.hasActiveContent ?? false
    }
}

extension DocumentStructure {
    public var businessSummary: DocumentStructureSummary {
        DocumentStructureSummary(
            pageCount: elements(kind: .page).count,
            slideCount: elements(kind: .slide).count,
            sheetCount: elements(kind: .sheet).count,
            tableCount: elements(kind: .table).count,
            imageCount: elements(kind: .image).count,
            chartCount: elements(kind: .chart).count,
            textLengthUTF16: textLengthUTF16
        )
    }
}

extension Attachment {
    public var businessDocumentSummary: BusinessDocumentSummary? {
        BusinessDocumentSummary(self)
    }

    fileprivate var documentFileSize: Int64? {
        switch kind {
        case .document(_, _, let fileSize), .documentRef(_, _, let fileSize):
            return Int64(fileSize)
        default:
            return nil
        }
    }
}
