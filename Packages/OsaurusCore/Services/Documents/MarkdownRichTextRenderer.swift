//
//  MarkdownRichTextRenderer.swift
//  osaurus
//
//  Turns Markdown or HTML source into a styled `NSAttributedString` that
//  the DOCX (`NSAttributedString` OOXML writer) and PDF (CoreText) emitters
//  consume. Markdown is parsed with Foundation's `AttributedString`
//  (`.full` interpreted syntax) so headings, lists, code blocks, block
//  quotes, emphasis, links, and — best effort — tables map to real
//  paragraph styles instead of literal `#`/`*` characters ending up in a
//  Word document.
//

import AppKit
import Foundation

enum MarkdownRichTextRenderer {
    enum Syntax: String, Sendable {
        case markdown
        case html
    }

    enum RenderError: LocalizedError {
        case htmlImportFailed
        case markdownParseFailed(String)

        var errorDescription: String? {
            switch self {
            case .htmlImportFailed:
                return "The HTML could not be imported as rich text."
            case .markdownParseFailed(let reason):
                return "The Markdown could not be parsed: \(reason)"
            }
        }
    }

    // MARK: - Syntax sniffing

    /// HTML when the text starts with a doctype/`<html>` or contains a
    /// handful of block tags; Markdown otherwise. Plain prose with no
    /// markup at all is Markdown (paragraphs split on blank lines).
    static func sniffSyntax(_ content: String) -> Syntax {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .html }
        let blockTags = ["<p>", "<p ", "<h1", "<h2", "<h3", "<ul>", "<ol>", "<li>", "<table", "<div", "<br", "<body"]
        let hits = blockTags.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        return hits >= 2 ? .html : .markdown
    }

    // MARK: - Rendering

    /// Render `content` as rich text. Markdown is pure Foundation and may
    /// run on any thread. HTML uses AppKit's importer, which must run on
    /// the main thread; callers pass `.html` only after hopping there
    /// (`attributedStringForHTMLOnMain`).
    static func attributedString(fromMarkdown markdown: String) throws -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: markdown, options: options)
        } catch {
            throw RenderError.markdownParseFailed(error.localizedDescription)
        }
        return layout(parsed)
    }

    @MainActor
    static func attributedStringForHTMLOnMain(_ html: String) throws -> NSAttributedString {
        guard let data = html.data(using: .utf8),
            let imported = NSAttributedString(
                html: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
        else {
            throw RenderError.htmlImportFailed
        }
        return imported
    }

    // MARK: - Typography

    struct Theme: @unchecked Sendable {
        let bodyFont: NSFont
        let monoFont: NSFont
        let bodyColor: NSColor
        let quoteColor: NSColor
        let linkColor: NSColor

        static let `default` = Theme(
            bodyFont: NSFont(name: "Helvetica", size: 11) ?? NSFont.systemFont(ofSize: 11),
            monoFont: NSFont(name: "Menlo", size: 10) ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            bodyColor: .black,
            quoteColor: NSColor(calibratedWhite: 0.35, alpha: 1),
            linkColor: NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.75, alpha: 1)
        )

        func headingFont(level: Int) -> NSFont {
            let size: CGFloat
            switch level {
            case 1: size = 22
            case 2: size = 17
            case 3: size = 14
            default: size = 12
            }
            return NSFont(name: "Helvetica-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
        }
    }

    // MARK: - Layout

    /// One Markdown block (heading, paragraph, list item, code block, …).
    private struct Block {
        var text = NSMutableAttributedString()
        var kind: BlockKind = .paragraph
        var identity: Int = 0
        var headingLevel = 1
        var listDepth = 0
        var ordinal: Int?
        var isOrdered = false
        var inQuote = false
        var codeLanguage: String?
        var tableColumn: Int?
        var tableRowIdentity: Int?
        var isTableHeader = false
    }

    private enum BlockKind {
        case paragraph, heading, listItem, codeBlock, thematicBreak, tableCell
    }

    private static func layout(_ source: AttributedString, theme: Theme = .default) -> NSAttributedString {
        var blocks: [Block] = []
        var current: Block?

        for run in source.runs {
            let text = String(source[run.range].characters)
            let intent = run.presentationIntent
            let descriptor = blockDescriptor(for: intent)

            if current == nil || current!.identity != descriptor.identity {
                if let done = current { blocks.append(done) }
                var block = Block()
                block.identity = descriptor.identity
                block.kind = descriptor.kind
                block.headingLevel = descriptor.headingLevel
                block.listDepth = descriptor.listDepth
                block.ordinal = descriptor.ordinal
                block.isOrdered = descriptor.isOrdered
                block.inQuote = descriptor.inQuote
                block.codeLanguage = descriptor.codeLanguage
                block.tableColumn = descriptor.tableColumn
                block.tableRowIdentity = descriptor.tableRowIdentity
                block.isTableHeader = descriptor.isTableHeader
                current = block
            }

            let attributes = inlineAttributes(
                for: run,
                blockKind: descriptor.kind,
                headingLevel: descriptor.headingLevel,
                inQuote: descriptor.inQuote,
                theme: theme
            )
            current?.text.append(NSAttributedString(string: text, attributes: attributes))
        }
        if let done = current { blocks.append(done) }

        return assemble(blocks, theme: theme)
    }

    private struct BlockDescriptor {
        var identity = 0
        var kind: BlockKind = .paragraph
        var headingLevel = 1
        var listDepth = 0
        var ordinal: Int?
        var isOrdered = false
        var inQuote = false
        var codeLanguage: String?
        var tableColumn: Int?
        var tableRowIdentity: Int?
        var isTableHeader = false
    }

    private static func blockDescriptor(for intent: PresentationIntent?) -> BlockDescriptor {
        var descriptor = BlockDescriptor()
        guard let intent else { return descriptor }
        // Components are ordered innermost first (e.g. paragraph → listItem → unorderedList).
        var listDepth = 0
        for component in intent.components {
            switch component.kind {
            case .paragraph:
                if descriptor.identity == 0 {
                    descriptor.identity = component.identity
                    descriptor.kind = .paragraph
                }
            case .header(let level):
                descriptor.identity = component.identity
                descriptor.kind = .heading
                descriptor.headingLevel = level
            case .codeBlock(let languageHint):
                descriptor.identity = component.identity
                descriptor.kind = .codeBlock
                descriptor.codeLanguage = languageHint
            case .thematicBreak:
                descriptor.identity = component.identity
                descriptor.kind = .thematicBreak
            case .listItem(let ordinal):
                if descriptor.kind == .paragraph || descriptor.identity == 0 {
                    descriptor.kind = .listItem
                    if descriptor.identity == 0 { descriptor.identity = component.identity }
                    // First list item component seen is the innermost.
                    if descriptor.ordinal == nil { descriptor.ordinal = ordinal }
                }
            case .orderedList:
                listDepth += 1
                if listDepth == 1 { descriptor.isOrdered = true }
            case .unorderedList:
                listDepth += 1
            case .blockQuote:
                descriptor.inQuote = true
            case .tableCell(let column):
                descriptor.identity = component.identity
                descriptor.kind = .tableCell
                descriptor.tableColumn = column
            case .tableRow(let row):
                descriptor.tableRowIdentity = component.identity
                _ = row
            case .tableHeaderRow:
                descriptor.tableRowIdentity = component.identity
                descriptor.isTableHeader = true
            case .table:
                break
            @unknown default:
                break
            }
        }
        descriptor.listDepth = listDepth
        // A paragraph inside a list item shares the list item's identity so
        // consecutive runs of the same item stay together.
        return descriptor
    }

    private static func inlineAttributes(
        for run: AttributedString.Runs.Run,
        blockKind: BlockKind,
        headingLevel: Int,
        inQuote: Bool,
        theme: Theme
    ) -> [NSAttributedString.Key: Any] {
        var font: NSFont
        switch blockKind {
        case .heading: font = theme.headingFont(level: headingLevel)
        case .codeBlock: font = theme.monoFont
        default: font = theme.bodyFont
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: inQuote ? theme.quoteColor : theme.bodyColor
        ]
        if let inline = run.inlinePresentationIntent {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if inline.contains(.emphasized) { traits.insert(.italic) }
            if inline.contains(.code) { font = theme.monoFont }
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = theme.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributes[.font] = font
        return attributes
    }

    private static func assemble(_ blocks: [Block], theme: Theme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if block.kind == .tableCell {
                // Gather the whole table (consecutive cell blocks) and lay it
                // out as tab-separated rows — best effort; OOXML tables from
                // NSAttributedString are not reliable enough to emit here.
                var cells: [Block] = []
                while index < blocks.count, blocks[index].kind == .tableCell {
                    cells.append(blocks[index])
                    index += 1
                }
                output.append(tableParagraphs(cells, theme: theme))
                continue
            }
            output.append(paragraph(for: block, theme: theme))
            index += 1
        }
        return output
    }

    private static func paragraph(for block: Block, theme: Theme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let body = NSMutableAttributedString()
        switch block.kind {
        case .heading:
            style.paragraphSpacingBefore = block.headingLevel == 1 ? 14 : 10
            style.paragraphSpacing = 6
            body.append(block.text)
        case .paragraph:
            style.paragraphSpacing = 8
            if block.inQuote {
                style.headIndent = 18
                style.firstLineHeadIndent = 18
            }
            body.append(block.text)
        case .listItem:
            let indent = CGFloat(18 * max(block.listDepth, 1))
            style.headIndent = indent
            style.firstLineHeadIndent = indent - 14
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent, options: [:])]
            style.paragraphSpacing = 3
            let marker: String
            if block.isOrdered, let ordinal = block.ordinal {
                marker = "\(ordinal).\t"
            } else {
                marker = "•\t"
            }
            body.append(
                NSAttributedString(
                    string: marker,
                    attributes: [.font: theme.bodyFont, .foregroundColor: theme.bodyColor]
                )
            )
            body.append(block.text)
        case .codeBlock:
            style.headIndent = 12
            style.firstLineHeadIndent = 12
            style.paragraphSpacing = 8
            let code = NSMutableAttributedString(attributedString: block.text)
            // Code blocks keep their internal newlines; strip one trailing
            // newline so the paragraph break below doesn't double up.
            if code.string.hasSuffix("\n") {
                code.deleteCharacters(in: NSRange(location: code.length - 1, length: 1))
            }
            code.addAttribute(.font, value: theme.monoFont, range: NSRange(location: 0, length: code.length))
            body.append(code)
        case .thematicBreak:
            style.alignment = .center
            style.paragraphSpacing = 8
            body.append(
                NSAttributedString(
                    string: "— — —",
                    attributes: [.font: theme.bodyFont, .foregroundColor: theme.quoteColor]
                )
            )
        case .tableCell:
            body.append(block.text)
        }
        body.append(NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont]))
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        return body
    }

    private static func tableParagraphs(_ cells: [Block], theme: Theme) -> NSAttributedString {
        // Group cells by row identity, preserving order.
        var rows: [(identity: Int, header: Bool, cells: [Block])] = []
        for cell in cells {
            let rowId = cell.tableRowIdentity ?? -1
            if let last = rows.last, last.identity == rowId {
                rows[rows.count - 1].cells.append(cell)
            } else {
                rows.append((identity: rowId, header: cell.isTableHeader, cells: [cell]))
            }
        }
        let columnCount = rows.map(\.cells.count).max() ?? 1
        let columnWidth: CGFloat = max(72, 468 / CGFloat(max(columnCount, 1)))
        let style = NSMutableParagraphStyle()
        style.tabStops = (1 ..< max(columnCount, 1)).map {
            NSTextTab(textAlignment: .left, location: columnWidth * CGFloat($0), options: [:])
        }
        style.defaultTabInterval = columnWidth
        style.paragraphSpacing = 2
        style.lineBreakMode = .byTruncatingTail

        let output = NSMutableAttributedString()
        for row in rows {
            let line = NSMutableAttributedString()
            for (column, cell) in row.cells.enumerated() {
                if column > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: theme.bodyFont])) }
                let text = NSMutableAttributedString(attributedString: cell.text)
                if row.header {
                    text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                        let base = (value as? NSFont) ?? theme.bodyFont
                        let bold =
                            NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.bold), size: base.pointSize)
                            ?? base
                        text.addAttribute(.font, value: bold, range: range)
                    }
                }
                line.append(text)
            }
            line.append(NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont]))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            output.append(line)
        }
        // Blank line after the table.
        let spacer = NSMutableParagraphStyle()
        spacer.paragraphSpacing = 6
        output.append(NSAttributedString(string: "\n", attributes: [.font: theme.bodyFont, .paragraphStyle: spacer]))
        return output
    }
}
