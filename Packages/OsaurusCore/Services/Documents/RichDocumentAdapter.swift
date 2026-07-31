//
//  RichDocumentAdapter.swift
//  osaurus
//
//  Wraps the `NSAttributedString(url:documentType:)` path in
//  `DocumentParser.parseRichDocument`. A single adapter covers DOCX, DOC,
//  RTF, RTFD, and HTML today because they share the same underlying
//  framework call and produce the same plain-text output. When stage-4
//  PR 11 lands a high-fidelity DOCX reader (tables, tracked changes,
//  comments) this adapter splits along format lines and this one becomes
//  the RTF/HTML-only path.
//

import AppKit
import Foundation

public struct RichDocumentAdapter: DocumentFormatAdapter {
    public let formatId = "richdoc"

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if sizeLimit > 0, fileSize > sizeLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: sizeLimit)
        }

        let ext = url.pathExtension.lowercased()
        let sourceFormat = RichDocumentSourceFormat(fileExtension: ext)
        let documentType = Self.documentType(forExtension: ext)
        let attributed: NSAttributedString
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let documentType {
                options[.documentType] = documentType
            }
            attributed = try NSAttributedString(
                url: url,
                options: options,
                documentAttributes: nil
            )
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }

        let extracted = attributed.string
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAdapterError.emptyContent
        }

        let truncated = PlainTextAdapter.applyCharacterCap(extracted)
        let sourceLabel = sourceFormat.label
        let blocks = Self.richBlocks(
            from: attributed,
            textFallback: truncated,
            sourceWasTruncated: extracted != truncated
        )
        let structure = Self.structure(
            filename: url.lastPathComponent,
            textFallback: truncated,
            blocks: blocks,
            sourceFormat: sourceFormat,
            sourceLabel: sourceLabel
        )
        let securitySignals = Self.securitySignals(url: url)
        let findings =
            securitySignals.findings
            + Self.truncationFindings(extractedText: extracted, textFallback: truncated)
        let security = DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: formatId,
            inspectionStatus: securitySignals.inspectionStatus,
            findings: findings,
            externalReferences: securitySignals.externalReferences,
            activeContentTypes: securitySignals.activeContentTypes
        )

        return StructuredDocument(
            formatId: formatId,
            filename: url.lastPathComponent,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: RichDocumentRepresentation(
                    sourceFormat: sourceFormat,
                    sourceLabel: sourceLabel,
                    text: truncated,
                    blocks: blocks
                )
            ),
            structure: structure,
            security: security,
            textFallback: truncated
        )
    }

    // MARK: - Helpers

    static let supportedExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "html", "htm",
    ]

    private static func documentType(
        forExtension ext: String
    ) -> NSAttributedString.DocumentType? {
        switch ext {
        case "docx": return nil  // NSAttributedString auto-detects OOXML
        case "doc": return .docFormat
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "html", "htm": return .html
        default: return nil
        }
    }

    private static func securitySignals(url: URL) -> RichSecuritySignals {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            guard let rawHTML = readTextSource(url: url) else {
                return RichSecuritySignals(
                    inspectionStatus: .partiallyInspected,
                    findings: [
                        DocumentSecurityFinding(
                            kind: .integrityUnavailable,
                            severity: .low,
                            message: "Could not inspect HTML source for active content."
                        )
                    ]
                )
            }
            let signals = DocumentFileInspector.htmlSecuritySignals(rawHTML: rawHTML)
            return RichSecuritySignals(
                inspectionStatus: .inspected,
                findings: signals.findings,
                externalReferences: signals.externalReferences,
                activeContentTypes: signals.activeContentTypes
            )
        }

        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "Rich document package relationships and embedded objects are not fully inspected by the text-only adapter."
            )
        ]
        var activeContentTypes: Set<DocumentActiveContentType> = []
        if ext == "doc" {
            activeContentTypes.insert(.unknown)
            findings.append(
                DocumentSecurityFinding(
                    kind: .activeContent,
                    severity: .low,
                    message: "Legacy Word documents may contain macros or embedded active content."
                )
            )
        }

        return RichSecuritySignals(
            inspectionStatus: .partiallyInspected,
            findings: findings,
            activeContentTypes: activeContentTypes
        )
    }

    private static func readTextSource(url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func richBlocks(
        from attributed: NSAttributedString,
        textFallback: String,
        sourceWasTruncated: Bool
    ) -> [RichDocumentBlock] {
        guard !sourceWasTruncated else {
            return [
                RichDocumentBlock(
                    kind: .paragraph,
                    text: textFallback,
                    textRange: .entireText(textFallback),
                    sourceIndex: 0,
                    anchorId: "document/body"
                )
            ]
        }

        let nsText = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var blocks: [RichDocumentBlock] = []
        var paragraphIndex = 0

        nsText.enumerateSubstrings(
            in: fullRange,
            options: [.byParagraphs, .substringNotRequired]
        ) { _, paragraphRange, _, _ in
            defer { paragraphIndex += 1 }
            guard paragraphRange.length > 0 else { return }

            let text = nsText.substring(with: paragraphRange)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let style = Self.paragraphStyle(
                in: attributed,
                at: paragraphRange.location
            )
            let headingLevel = style.flatMap { $0.headerLevel > 0 ? $0.headerLevel : nil }
            let listDepth = style.flatMap { $0.textLists.isEmpty ? nil : $0.textLists.count }
            let kind: RichDocumentBlock.Kind =
                if headingLevel != nil {
                    .heading
                } else if listDepth != nil {
                    .listItem
                } else {
                    .paragraph
                }
            let anchorId = "document/block/\(blocks.count)"

            blocks.append(
                RichDocumentBlock(
                    kind: kind,
                    text: text,
                    textRange: DocumentTextRange(
                        startUTF16Offset: paragraphRange.location,
                        length: paragraphRange.length
                    ),
                    sourceIndex: paragraphIndex,
                    headingLevel: headingLevel,
                    listDepth: listDepth,
                    anchorId: anchorId
                )
            )
        }

        guard !blocks.isEmpty else {
            return [
                RichDocumentBlock(
                    kind: .paragraph,
                    text: textFallback,
                    textRange: .entireText(textFallback),
                    sourceIndex: 0,
                    anchorId: "document/body"
                )
            ]
        }
        return blocks
    }

    private static func paragraphStyle(
        in attributed: NSAttributedString,
        at location: Int
    ) -> NSParagraphStyle? {
        guard attributed.length > 0 else { return nil }
        let safeLocation = min(location, attributed.length - 1)
        return attributed.attribute(
            .paragraphStyle,
            at: safeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
    }

    private static func structure(
        filename: String,
        textFallback: String,
        blocks: [RichDocumentBlock],
        sourceFormat: RichDocumentSourceFormat,
        sourceLabel: String
    ) -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: filename)
        let elements = blocks.map { block in
            let kind = Self.elementKind(for: block.kind)
            let anchorKind = Self.anchorKind(for: block.kind)
            let sourceRange = DocumentSourceRange(
                start: DocumentSourceLocation(
                    paragraphIndex: block.sourceIndex,
                    characterOffset: block.textRange.startUTF16Offset
                ),
                end: DocumentSourceLocation(
                    paragraphIndex: block.sourceIndex,
                    characterOffset: block.textRange.endUTF16Offset
                )
            )
            let metadata = Self.blockMetadata(
                block,
                sourceFormat: sourceFormat,
                sourceLabel: sourceLabel
            )
            let anchor = DocumentAnchor(
                id: block.anchorId,
                kind: anchorKind,
                path: [
                    .init(kind: .document),
                    .init(kind: anchorKind, index: block.sourceIndex),
                ],
                textRange: block.textRange,
                sourceRange: sourceRange,
                label: Self.blockLabel(block),
                metadata: metadata
            )
            return DocumentElement(
                kind: kind,
                anchor: anchor,
                text: block.text,
                attributes: DocumentElementAttributes(
                    role: block.kind.rawValue,
                    level: block.headingLevel,
                    metadata: metadata
                )
            )
        }

        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            attributes: DocumentElementAttributes(
                metadata: [
                    "importer": "NSAttributedString",
                    "sourceFormat": sourceFormat.rawValue,
                    "sourceLabel": sourceLabel,
                ]
            ),
            children: elements
        )
        return DocumentStructure(
            root: root,
            textLengthUTF16: textFallback.utf16.count
        )
    }

    private static func elementKind(for kind: RichDocumentBlock.Kind) -> DocumentElement.Kind {
        switch kind {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .listItem: return .listItem
        }
    }

    private static func anchorKind(for kind: RichDocumentBlock.Kind) -> DocumentAnchor.Kind {
        switch kind {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .listItem: return .listItem
        }
    }

    private static func blockLabel(_ block: RichDocumentBlock) -> String {
        switch block.kind {
        case .paragraph:
            return "Paragraph \(block.sourceIndex + 1)"
        case .heading:
            let level = block.headingLevel ?? 0
            return level > 0 ? "Heading \(level)" : "Heading"
        case .listItem:
            return "List item \(block.sourceIndex + 1)"
        }
    }

    private static func blockMetadata(
        _ block: RichDocumentBlock,
        sourceFormat: RichDocumentSourceFormat,
        sourceLabel: String
    ) -> [String: String] {
        var metadata = [
            "sourceFormat": sourceFormat.rawValue,
            "sourceIndex": "\(block.sourceIndex)",
            "sourceLabel": sourceLabel,
        ]
        if let headingLevel = block.headingLevel {
            metadata["headingLevel"] = "\(headingLevel)"
        }
        if let listDepth = block.listDepth {
            metadata["listDepth"] = "\(listDepth)"
        }
        return metadata
    }

    private static func truncationFindings(
        extractedText: String,
        textFallback: String
    ) -> [DocumentSecurityFinding] {
        guard extractedText != textFallback else { return [] }
        return [
            DocumentSecurityFinding(
                kind: .truncatedContent,
                severity: .low,
                message:
                    "Rich document text fallback was character-capped; paragraph-level ranges were not preserved.",
                metadata: [
                    "extractedUTF16Length": "\(extractedText.utf16.count)",
                    "fallbackUTF16Length": "\(textFallback.utf16.count)",
                ]
            )
        ]
    }

    private struct RichSecuritySignals {
        let inspectionStatus: DocumentSecurityMetadata.InspectionStatus
        var findings: [DocumentSecurityFinding] = []
        var externalReferences: [DocumentExternalReference] = []
        var activeContentTypes: Set<DocumentActiveContentType> = []
    }
}
