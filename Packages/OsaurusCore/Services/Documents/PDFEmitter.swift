//
//  PDFEmitter.swift
//  osaurus
//
//  Writes a `RichTextSourceDocument` (Markdown/HTML authored by
//  `file_write`) — or the text of a parsed `PDFDocumentRepresentation` —
//  as a paginated PDF via the headless CoreText renderer. Roundtrip-
//  readable by `PDFAdapter`.
//

import AppKit
import Foundation

public struct PDFEmitter: DocumentFormatEmitter {
    public let formatId = "pdf"

    public init() {}

    public func canEmit(_ document: StructuredDocument) -> Bool {
        guard document.formatId == formatId || document.representation.formatId == formatId else {
            return false
        }
        return document.representation.underlying is RichTextSourceDocument
            || document.representation.underlying is PDFDocumentRepresentation
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        let attributed: NSAttributedString
        let title: String?
        if let source = document.representation.underlying as? RichTextSourceDocument {
            attributed = try await RichTextRendering.attributedString(for: source)
            title = source.title
        } else if let pdf = document.representation.underlying as? PDFDocumentRepresentation {
            // Text-only re-render of an existing PDF's pages (one page of
            // source text per paragraph group). Layout is not preserved.
            let joined = pdf.pages.map(\.text).joined(separator: "\n\n")
            attributed = try MarkdownRichTextRenderer.attributedString(fromMarkdown: joined)
            title = document.filename
        } else {
            throw DocumentAdapterError.unsupportedFormat(formatId: document.formatId)
        }
        let rendered: RichTextPDFRenderer.Rendered
        do {
            rendered = try RichTextPDFRenderer.render(attributed, title: title)
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
        do {
            try rendered.data.write(to: url, options: .atomic)
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }
}
