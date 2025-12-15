//
//  MarkdownMessageView.swift
//  osaurus
//
//  Renders markdown text with proper typography, code blocks, images, and more
//  Optimized for streaming responses with stable block identity
//  Uses NSTextView for web-like text selection across blocks
//

import AppKit
import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    // Parse blocks and group into segments
    private var segments: [ContentSegment] {
        let blocks = parseBlocks(text)
        return groupBlocksIntoSegments(blocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                segmentView(for: segment, isFirst: index == 0)
            }
        }
    }

    @ViewBuilder
    private func segmentView(for segment: ContentSegment, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Add spacing before non-first segments
            if !isFirst {
                Spacer()
                    .frame(height: segment.spacingBefore)
            }

            switch segment.kind {
            case .textGroup(let textBlocks):
                SelectableTextView(
                    blocks: textBlocks,
                    baseWidth: baseWidth,
                    theme: theme
                )
                // Let the NSTextView self-size via intrinsicContentSize instead of doing a separate
                // height calculation pass (which duplicates layout work and can freeze the UI during streaming).
                .frame(width: baseWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            case .codeBlock(let code, let lang):
                CodeBlockView(code: code, language: lang, baseWidth: baseWidth)

            case .image(let url, let altText):
                MarkdownImageView(urlString: url, altText: altText, baseWidth: baseWidth)

            case .horizontalRule:
                HorizontalRuleView()
            }
        }
    }
}

// MARK: - Content Segment

/// Represents a segment of content - either a group of selectable text blocks or a special element
private struct ContentSegment: Identifiable {
    enum Kind {
        case textGroup([SelectableTextBlock])
        case codeBlock(code: String, language: String?)
        case image(url: String, altText: String)
        case horizontalRule
    }

    let id: String
    let kind: Kind
    let spacingBefore: CGFloat

    init(id: String, kind: Kind, spacingBefore: CGFloat = 0) {
        self.id = id
        self.kind = kind
        self.spacingBefore = spacingBefore
    }
}

// MARK: - Block Grouping

/// Groups consecutive text blocks into segments for efficient rendering with NSTextView
private func groupBlocksIntoSegments(_ blocks: [MessageBlock]) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var currentTextBlocks: [SelectableTextBlock] = []
    var segmentIndex = 0
    var previousBlockKind: MessageBlock.Kind? = nil

    func flushTextGroup() {
        if !currentTextBlocks.isEmpty {
            let spacing = segments.isEmpty ? 0 : spacingBeforeTextGroup(previousNonTextKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "text-\(segmentIndex)",
                    kind: .textGroup(currentTextBlocks),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            currentTextBlocks.removeAll()
        }
    }

    for block in blocks {
        switch block.kind {
        case .paragraph(let text):
            currentTextBlocks.append(.paragraph(text))

        case .heading(let level, let text):
            currentTextBlocks.append(.heading(level: level, text: text))

        case .blockquote(let content):
            currentTextBlocks.append(.blockquote(content))

        case .list(let items, let ordered):
            for (index, item) in items.enumerated() {
                currentTextBlocks.append(.listItem(text: item, index: index, ordered: ordered))
            }

        case .code(let code, let lang):
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.code(code, lang), previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "code-\(segmentIndex)",
                    kind: .codeBlock(code: code, language: lang),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind

        case .image(let url, let altText):
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.image(url: url, altText: altText), previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "image-\(segmentIndex)",
                    kind: .image(url: url, altText: altText),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind

        case .horizontalRule:
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.horizontalRule, previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "hr-\(segmentIndex)",
                    kind: .horizontalRule,
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind
        }

        // Track last text block kind for spacing
        if case .paragraph = block.kind {
            previousBlockKind = block.kind
        } else if case .heading = block.kind {
            previousBlockKind = block.kind
        } else if case .blockquote = block.kind {
            previousBlockKind = block.kind
        } else if case .list = block.kind {
            previousBlockKind = block.kind
        }
    }

    flushTextGroup()

    return segments
}

/// Calculate spacing before a special block (code, image, hr)
private func spacingForSpecialBlock(_ kind: MessageBlock.Kind, previousKind: MessageBlock.Kind?) -> CGFloat {
    guard previousKind != nil else { return 0 }

    switch kind {
    case .code:
        return 14
    case .image:
        return 16
    case .horizontalRule:
        return 8
    default:
        return 12
    }
}

/// Calculate spacing before a text group that follows a special block
private func spacingBeforeTextGroup(previousNonTextKind: MessageBlock.Kind?) -> CGFloat {
    guard let prev = previousNonTextKind else { return 0 }

    switch prev {
    case .code:
        return 14
    case .image:
        return 16
    case .horizontalRule:
        return 8
    default:
        return 12
    }
}

// MARK: - Message Block

private struct MessageBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph(String)
        case code(String, String?)
        case image(url: String, altText: String)
        case heading(level: Int, text: String)
        case blockquote(String)
        case horizontalRule
        case list(items: [String], ordered: Bool)

        /// Generate a stable hash for the block kind
        var contentHash: Int {
            var hasher = Hasher()
            switch self {
            case .paragraph(let text):
                hasher.combine("p")
                hasher.combine(text)
            case .code(let code, let lang):
                hasher.combine("c")
                hasher.combine(code)
                hasher.combine(lang)
            case .image(let url, let alt):
                hasher.combine("i")
                hasher.combine(url)
                hasher.combine(alt)
            case .heading(let level, let text):
                hasher.combine("h")
                hasher.combine(level)
                hasher.combine(text)
            case .blockquote(let content):
                hasher.combine("q")
                hasher.combine(content)
            case .horizontalRule:
                hasher.combine("hr")
            case .list(let items, let ordered):
                hasher.combine("l")
                hasher.combine(items)
                hasher.combine(ordered)
            }
            return hasher.finalize()
        }
    }

    let index: Int
    let kind: Kind

    /// Stable identifier combining index and content for efficient diffing
    var stableId: String {
        "\(index)-\(kind.contentHash)"
    }

    var id: String { stableId }
}

// MARK: - Parser

private func parseBlocks(_ input: String) -> [MessageBlock] {
    var blocks: [MessageBlock] = []
    var currentParagraphLines: [String] = []
    var currentBlockquoteLines: [String] = []
    var currentListItems: [String] = []
    var isOrderedList = false
    var blockIndex = 0

    let lines = input.replacingOccurrences(of: "\r\n", with: "\n").split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    func flushParagraph() {
        if !currentParagraphLines.isEmpty {
            let paragraphText = currentParagraphLines.joined(separator: "\n")
            // Check if paragraph contains standalone image
            if let imageKind = extractStandaloneImageKind(from: paragraphText) {
                blocks.append(MessageBlock(index: blockIndex, kind: imageKind))
            } else {
                blocks.append(MessageBlock(index: blockIndex, kind: .paragraph(paragraphText)))
            }
            blockIndex += 1
            currentParagraphLines.removeAll()
        }
    }

    func flushBlockquote() {
        if !currentBlockquoteLines.isEmpty {
            blocks.append(
                MessageBlock(index: blockIndex, kind: .blockquote(currentBlockquoteLines.joined(separator: "\n")))
            )
            blockIndex += 1
            currentBlockquoteLines.removeAll()
        }
    }

    func flushList() {
        if !currentListItems.isEmpty {
            blocks.append(MessageBlock(index: blockIndex, kind: .list(items: currentListItems, ordered: isOrderedList)))
            blockIndex += 1
            currentListItems.removeAll()
        }
    }

    var i = 0
    while i < lines.count {
        let line = String(lines[i])
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fenced code block
        if trimmed.hasPrefix("```") {
            flushParagraph()
            flushBlockquote()
            flushList()

            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).nilIfEmpty
            i += 1
            var codeLines: [String] = []
            while i < lines.count {
                let l = String(lines[i])
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                codeLines.append(l)
                i += 1
            }
            blocks.append(MessageBlock(index: blockIndex, kind: .code(codeLines.joined(separator: "\n"), lang)))
            blockIndex += 1
            if i < lines.count { i += 1 }
            continue
        }

        // Horizontal rule (---, ***, ___)
        if isHorizontalRule(trimmed) {
            flushParagraph()
            flushBlockquote()
            flushList()
            blocks.append(MessageBlock(index: blockIndex, kind: .horizontalRule))
            blockIndex += 1
            i += 1
            continue
        }

        // Heading (# to ######)
        if let headingMatch = parseHeading(trimmed) {
            flushParagraph()
            flushBlockquote()
            flushList()
            blocks.append(
                MessageBlock(index: blockIndex, kind: .heading(level: headingMatch.level, text: headingMatch.text))
            )
            blockIndex += 1
            i += 1
            continue
        }

        // Blockquote (> ...)
        if trimmed.hasPrefix(">") {
            flushParagraph()
            flushList()
            let quoteContent = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            currentBlockquoteLines.append(quoteContent)
            i += 1
            continue
        } else if !currentBlockquoteLines.isEmpty {
            flushBlockquote()
        }

        // Unordered list (- or * or +)
        if let listItem = parseUnorderedListItem(trimmed) {
            flushParagraph()
            flushBlockquote()
            if !currentListItems.isEmpty && isOrderedList {
                flushList()
            }
            isOrderedList = false
            currentListItems.append(listItem)
            i += 1
            continue
        }

        // Ordered list (1. 2. etc.)
        if let listItem = parseOrderedListItem(trimmed) {
            flushParagraph()
            flushBlockquote()
            if !currentListItems.isEmpty && !isOrderedList {
                flushList()
            }
            isOrderedList = true
            currentListItems.append(listItem)
            i += 1
            continue
        }

        // Flush list if we encounter non-list content
        if !currentListItems.isEmpty {
            flushList()
        }

        // Blank line separates paragraphs
        if trimmed.isEmpty {
            flushParagraph()
            flushBlockquote()
            i += 1
            continue
        }

        // Regular paragraph line
        currentParagraphLines.append(line)
        i += 1
    }

    // Final flush
    flushParagraph()
    flushBlockquote()
    flushList()

    return blocks
}

// MARK: - Parser Helpers

private func isHorizontalRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }

    // Check for ---, ***, or ___
    let chars = Array(trimmed)
    let first = chars[0]
    guard first == "-" || first == "*" || first == "_" else { return false }

    return chars.allSatisfy { $0 == first || $0 == " " } && chars.filter { $0 == first }.count >= 3
}

private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    var level = 0
    var index = line.startIndex

    while index < line.endIndex && line[index] == "#" && level < 6 {
        level += 1
        index = line.index(after: index)
    }

    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }

    let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    // Remove trailing # if present
    let cleanedText = text.replacingOccurrences(of: #"\s*#+\s*$"#, with: "", options: .regularExpression)
    return (level, cleanedText)
}

private func parseUnorderedListItem(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("- ") {
        return String(trimmed.dropFirst(2))
    } else if trimmed.hasPrefix("* ") {
        return String(trimmed.dropFirst(2))
    } else if trimmed.hasPrefix("+ ") {
        return String(trimmed.dropFirst(2))
    }
    return nil
}

private func parseOrderedListItem(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // Match patterns like "1. ", "2. ", "10. " etc.
    let pattern = #"^\d+\.\s+"#
    if let range = trimmed.range(of: pattern, options: .regularExpression) {
        return String(trimmed[range.upperBound...])
    }
    return nil
}

private func extractStandaloneImageKind(from text: String) -> MessageBlock.Kind? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Match ![alt](url) pattern for standalone images
    let pattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
        let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed))
    else { return nil }

    guard let altRange = Range(match.range(at: 1), in: trimmed),
        let urlRange = Range(match.range(at: 2), in: trimmed)
    else { return nil }

    let altText = String(trimmed[altRange])
    let url = String(trimmed[urlRange])
    return .image(url: url, altText: altText)
}

// MARK: - String Extension

extension String {
    fileprivate var nilIfEmpty: String? { self.isEmpty ? nil : self }
}

// MARK: - Preview

#if DEBUG
    struct MarkdownMessageView_Previews: PreviewProvider {
        static let sampleMarkdown = """
            # Welcome to Osaurus

            Here's a **bold** statement and some *italic* text.

            ## Code Example

            This is a code example:

            ```swift
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            ```

            ---

            ### Lists

            Unordered list:
            - First item
            - Second item
            - Third item

            Ordered list:
            1. Step one
            2. Step two
            3. Step three

            > This is a blockquote with some important information
            > that spans multiple lines.

            Here's an image:

            ![Cat Image](https://placekitten.com/400/300)

            And that's all folks!
            """

        static var previews: some View {
            ScrollView {
                MarkdownMessageView(text: sampleMarkdown, baseWidth: 600)
                    .padding()
                    .frame(width: 600, alignment: .leading)
            }
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
