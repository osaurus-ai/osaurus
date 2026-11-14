//
//  RichTextSourceDocument.swift
//  osaurus
//
//  Write-side representation for documents authored as Markdown or HTML
//  (the shape `file_write` produces for `.docx` / `.pdf`). The emitters
//  render it through `MarkdownRichTextRenderer`; readers never produce it.
//

import Foundation

public struct RichTextSourceDocument: StructuredRepresentation, Codable, Equatable, Sendable {
    public enum Syntax: String, Codable, Sendable {
        case markdown
        case html
    }

    public let markup: String
    public let syntax: Syntax
    /// Optional document title (PDF metadata / DOCX core properties).
    public let title: String?

    public init(markup: String, syntax: Syntax, title: String? = nil) {
        self.markup = markup
        self.syntax = syntax
        self.title = title
    }
}
