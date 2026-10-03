//
//  DOCXEmitter.swift
//  osaurus
//
//  Writes a `RichTextSourceDocument` as a Word `.docx` package through
//  AppKit's Office Open XML writer. Roundtrip-readable by
//  `RichDocumentAdapter`, which is how `file_read` verifies the output.
//

import AppKit
import Foundation

public struct DOCXEmitter: DocumentFormatEmitter {
    public let formatId = "docx"

    public init() {}

    public func canEmit(_ document: StructuredDocument) -> Bool {
        document.representation.underlying is RichTextSourceDocument
            && (document.formatId == formatId || document.representation.formatId == formatId)
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        guard let source = document.representation.underlying as? RichTextSourceDocument else {
            throw DocumentAdapterError.unsupportedFormat(formatId: document.formatId)
        }
        let attributed = try await RichTextRendering.attributedString(for: source)
        let data = try Self.docxData(from: attributed, title: source.title)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }

    /// OOXML bytes for an attributed string. Exposed so the write tool's
    /// dry run can size the output without touching disk.
    static func docxData(from attributed: NSAttributedString, title: String?) throws -> Data {
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        if let title, !title.isEmpty { attributes[.title] = title }
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: attributes
            )
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: "OOXML export failed: \(error.localizedDescription)")
        }
    }
}

/// Shared render entry for the DOCX and PDF emitters: Markdown renders
/// anywhere; HTML hops to the main actor because AppKit's HTML importer
/// is main-thread-only.
enum RichTextRendering {
    static func attributedString(for source: RichTextSourceDocument) async throws -> NSAttributedString {
        switch source.syntax {
        case .markdown:
            return try MarkdownRichTextRenderer.attributedString(fromMarkdown: source.markup)
        case .html:
            let markup = source.markup
            // NSAttributedString is not Sendable; hand the (immutable)
            // result across the actor hop as archived RTFD bytes.
            let archived: Data = try await MainActor.run {
                let attributed = try MarkdownRichTextRenderer.attributedStringForHTMLOnMain(markup)
                guard
                    let data = attributed.rtfd(
                        from: NSRange(location: 0, length: attributed.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
                    )
                else {
                    throw MarkdownRichTextRenderer.RenderError.htmlImportFailed
                }
                return data
            }
            guard let restored = NSAttributedString(rtfd: archived, documentAttributes: nil) else {
                throw MarkdownRichTextRenderer.RenderError.htmlImportFailed
            }
            return restored
        }
    }
}
