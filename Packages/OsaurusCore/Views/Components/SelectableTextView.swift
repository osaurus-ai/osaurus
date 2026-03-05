//
//  SelectableTextView.swift
//  osaurus
//
//  NSTextView wrapper for web-like text selection across markdown blocks
//

import AppKit
import SwiftUI

// MARK: - Typography Spacing Constants

/// Line spacing within text blocks (space between lines of the same block)
private enum LineSpacing {
    static let paragraph: CGFloat = 7  // ~1.5 line height for body text
    static let heading: CGFloat = 2  // Tighter for headings
    static let blockquote: CGFloat = 5  // Slightly open feel
    static let listItem: CGFloat = 6  // Good for multi-line items
}

/// Block spacing between different content blocks
private enum BlockSpacing {
    static let paragraphAfterOther: CGFloat = 14
    static let headingH1H2AfterOther: CGFloat = 24
    static let headingH3PlusAfterOther: CGFloat = 20
    static let headingAfterHeading: CGFloat = 10
    static let blockquoteAfterOther: CGFloat = 12
    static let blockquoteAfterBlockquote: CGFloat = 4
    static let listItemAfterOther: CGFloat = 10
    static let listItemAfterListItem: CGFloat = 8
    static let horizontalRuleAfterOther: CGFloat = 8
    static let tableAfterOther: CGFloat = 14
}

// MARK: - Syntax Highlighting Keywords

enum SyntaxKeywords {
    static func keywords(for language: String) -> [String] {
        switch language {
        case "swift":
            return [
                "func", "let", "var", "if", "else", "guard", "return", "import", "struct", "class", "enum",
                "protocol", "extension", "switch", "case", "default", "for", "while", "in", "where",
                "self", "Self", "nil", "true", "false", "try", "catch", "throw", "throws", "async",
                "await", "static", "private", "public", "internal", "open", "fileprivate", "override",
                "init", "deinit", "typealias", "associatedtype", "some", "any", "weak", "unowned",
            ]
        case "python", "py":
            return [
                "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                "as", "try", "except", "finally", "with", "yield", "lambda", "pass", "break",
                "continue", "and", "or", "not", "in", "is", "None", "True", "False", "self",
                "raise", "async", "await", "global", "nonlocal",
            ]
        case "javascript", "js":
            return [
                "function", "const", "let", "var", "if", "else", "return", "import", "export",
                "from", "class", "extends", "new", "this", "for", "while", "switch", "case",
                "default", "break", "continue", "try", "catch", "throw", "async", "await",
                "true", "false", "null", "undefined", "typeof", "instanceof", "of", "in", "yield",
            ]
        case "typescript", "ts":
            return [
                "function", "const", "let", "var", "if", "else", "return", "import", "export",
                "from", "class", "extends", "implements", "interface", "type", "enum", "new",
                "this", "for", "while", "switch", "case", "default", "break", "continue",
                "try", "catch", "throw", "async", "await", "true", "false", "null", "undefined",
                "typeof", "instanceof", "of", "in", "as", "keyof", "readonly", "private",
                "public", "protected", "static", "abstract", "declare",
            ]
        case "rust":
            return [
                "fn", "let", "mut", "if", "else", "match", "return", "use", "mod", "pub", "struct",
                "enum", "impl", "trait", "for", "while", "loop", "in", "self", "Self", "true",
                "false", "as", "ref", "move", "async", "await", "where", "type", "const", "static",
                "unsafe", "extern", "crate", "super",
            ]
        case "go":
            return [
                "func", "var", "const", "if", "else", "for", "range", "return", "import", "package",
                "type", "struct", "interface", "map", "chan", "go", "defer", "select", "case",
                "default", "switch", "break", "continue", "nil", "true", "false", "make", "new",
            ]
        case "java", "kotlin":
            return [
                "class", "interface", "extends", "implements", "new", "return", "if", "else",
                "for", "while", "switch", "case", "default", "break", "continue", "try", "catch",
                "throw", "throws", "import", "package", "public", "private", "protected", "static",
                "final", "abstract", "void", "int", "boolean", "true", "false", "null", "this",
                "super", "instanceof", "enum", "val", "var", "fun", "when", "object", "companion",
            ]
        case "c", "cpp", "c++":
            return [
                "int", "char", "float", "double", "void", "if", "else", "for", "while", "return",
                "struct", "class", "enum", "typedef", "include", "define", "const", "static",
                "extern", "sizeof", "switch", "case", "default", "break", "continue", "true",
                "false", "nullptr", "NULL", "auto", "namespace", "using", "template", "virtual",
                "public", "private", "protected", "new", "delete", "this", "throw", "try", "catch",
            ]
        case "bash", "sh", "shell", "zsh":
            return [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                "function", "return", "exit", "echo", "export", "local", "source", "in", "true", "false",
            ]
        case "sql":
            return [
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "TABLE", "DROP", "ALTER", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER",
                "OUTER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING",
                "LIMIT", "OFFSET", "DISTINCT", "COUNT", "SUM", "AVG", "MAX", "MIN", "IN", "EXISTS",
                "LIKE", "BETWEEN", "UNION", "ALL", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer",
                "on", "and", "or", "not", "null", "as", "order", "by", "group", "having",
                "limit", "offset", "distinct", "in", "exists", "like", "between", "union", "all",
            ]
        case "html", "xml":
            return []  // HTML/XML don't really use keywords in the traditional sense
        case "css", "scss", "sass":
            return ["import", "media", "keyframes", "font-face", "supports", "charset"]
        case "json", "yaml", "yml", "toml", "markdown", "md":
            return []  // No keywords for data formats
        default:
            return []
        }
    }
}

// MARK: - Text Block for Rendering

/// Represents a text block to be rendered in NSTextView
enum SelectableTextBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case blockquote(String)
    case listItem(text: String, index: Int, ordered: Bool, indentLevel: Int)
    case horizontalRule
    case table(headers: [String], rows: [[String]])
}

// MARK: - Custom Attribute Keys

extension NSAttributedString.Key {
    /// Marks a range as a blockquote for custom drawing (vertical accent bar)
    static let blockquoteMarker = NSAttributedString.Key("osaurus.blockquote")
    /// Marks a range as a heading that should have an underline (H1/H2)
    static let headingUnderline = NSAttributedString.Key("osaurus.headingUnderline")
}

// MARK: - Selectable Text View

struct SelectableTextView: NSViewRepresentable {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    let theme: ThemeProtocol
    /// Optional cache key (turn ID) for persisting measured height across view recycling
    var cacheKey: String? = nil

    final class Coordinator {
        var lastBlocks: [SelectableTextBlock] = []
        var lastWidth: CGFloat = 0
        var lastThemeFingerprint: String = ""
        var lastMeasuredHeight: CGFloat = 0
        var cacheKey: String? = nil
        var blockLengths: [Int] = []  // per-block rendered lengths for incremental updates
        /// Disables ThreadCache lookups once content changes (prevents stale heights during streaming)
        var contentChangedSinceInit: Bool = false

        init(cacheKey: String? = nil) {
            self.cacheKey = cacheKey
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cacheKey: cacheKey)
    }

    func makeNSView(context: Context) -> SelectableNSTextView {
        let textView = SelectableNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero

        // Don't allow scrolling - we size to fit content
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false

        // Configure text container for fixed width, unlimited height for layout
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        // Apply theme selection color
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]

        // Apply cursor color
        textView.insertionPointColor = NSColor(theme.cursorColor)

        // Set theme colors for custom drawing
        textView.accentColor = NSColor(theme.accentColor)
        textView.blockquoteBarColor = NSColor(theme.accentColor).withAlphaComponent(0.6)
        textView.secondaryBackgroundColor = NSColor(theme.secondaryBackground)

        return textView
    }

    func updateNSView(_ textView: SelectableNSTextView, context: Context) {
        // Update container width
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)

        // Update selection color for theme changes
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]

        // Update theme colors for custom drawing
        textView.accentColor = NSColor(theme.accentColor)
        textView.blockquoteBarColor = NSColor(theme.accentColor).withAlphaComponent(0.6)
        textView.secondaryBackgroundColor = NSColor(theme.secondaryBackground)

        // Fast path: Direct comparison instead of expensive O(n) hashing every update
        // Swift's Equatable for arrays uses optimized comparison that short-circuits early
        let themeFingerprint = makeThemeFingerprint()
        let widthChanged = abs(context.coordinator.lastWidth - baseWidth) > 0.1
        let themeChanged = context.coordinator.lastThemeFingerprint != themeFingerprint
        let blocksChanged = context.coordinator.lastBlocks != blocks

        if blocksChanged || widthChanged || themeChanged {
            if !widthChanged && !themeChanged && !context.coordinator.lastBlocks.isEmpty {
                updateTextStorageIncrementally(
                    textView: textView,
                    oldBlocks: context.coordinator.lastBlocks,
                    newBlocks: blocks,
                    coordinator: context.coordinator
                )
            } else {
                textView.textStorage?.setAttributedString(buildAttributedString(coordinator: context.coordinator))
            }

            if (blocksChanged || themeChanged) && !context.coordinator.lastBlocks.isEmpty {
                context.coordinator.contentChangedSinceInit = true
            }

            context.coordinator.lastMeasuredHeight = 0
            context.coordinator.lastBlocks = blocks
            context.coordinator.lastWidth = baseWidth
            context.coordinator.lastThemeFingerprint = themeFingerprint
            textView.needsDisplay = true
        }
    }

    // MARK: - Sizing

    /// Three-tier height cache: coordinator -> ThreadCache -> full layout measurement
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? baseWidth
        let coord = context.coordinator

        // Tier 1: coordinator cache
        if coord.lastMeasuredHeight > 0, abs(coord.lastWidth - width) < 0.5 {
            return CGSize(width: width, height: coord.lastMeasuredHeight)
        }

        // Tier 2: ThreadCache (survives view recycling, skipped during streaming)
        if !coord.contentChangedSinceInit, let key = cacheKey {
            if let cached = ThreadCache.shared.height(for: "\(key)-w\(Int(width))") {
                coord.lastWidth = width
                coord.lastMeasuredHeight = cached
                return CGSize(width: width, height: cached)
            }
        }

        // Tier 3: full layout
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let tc = nsView.textContainer, let lm = nsView.layoutManager else { return nil }
        lm.ensureLayout(for: tc)
        let measured = ceil(lm.usedRect(for: tc).height) + 8

        coord.lastWidth = width
        coord.lastMeasuredHeight = measured

        if let key = cacheKey {
            ThreadCache.shared.setHeight(measured, for: "\(key)-w\(Int(width))")
        }
        return CGSize(width: width, height: measured)
    }

    // MARK: - Incremental Updates

    private func updateTextStorageIncrementally(
        textView: SelectableNSTextView,
        oldBlocks: [SelectableTextBlock],
        newBlocks: [SelectableTextBlock],
        coordinator: Coordinator
    ) {
        guard let storage = textView.textStorage else { return }

        // Find first differing block
        var diffIndex = 0
        let commonCount = min(oldBlocks.count, newBlocks.count)
        while diffIndex < commonCount && oldBlocks[diffIndex] == newBlocks[diffIndex] {
            diffIndex += 1
        }

        // Calculate prefix length from cached block lengths
        var prefixLength = 0
        if diffIndex > 0 {
            if coordinator.blockLengths.count >= diffIndex {
                prefixLength = coordinator.blockLengths.prefix(diffIndex).reduce(0, +)
            } else {
                diffIndex = 0
            }
        }
        if prefixLength > storage.length {
            diffIndex = 0
            prefixLength = 0
        }

        // Delete everything after the common prefix
        let deleteRange = NSRange(location: prefixLength, length: storage.length - prefixLength)
        if deleteRange.length > 0 { storage.deleteCharacters(in: deleteRange) }

        var newLengths = Array(coordinator.blockLengths.prefix(diffIndex))

        // If appending to a previously-last block, add the missing newline separator
        if diffIndex > 0 && diffIndex == oldBlocks.count && diffIndex < newBlocks.count {
            storage.append(NSAttributedString(string: "\n"))
            if diffIndex - 1 < newLengths.count {
                newLengths[diffIndex - 1] += 1
            }
        }

        // Render and append changed/new blocks
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale

        for i in diffIndex ..< newBlocks.count {
            let isFirst = i == 0
            let attrString = renderBlock(
                newBlocks[i],
                isFirst: isFirst,
                previousBlock: isFirst ? nil : newBlocks[i - 1],
                bodyFontSize: bodyFontSize,
                scale: scale
            )
            storage.append(attrString)
            var blockLen = attrString.length

            if i < newBlocks.count - 1 {
                storage.append(NSAttributedString(string: "\n"))
                blockLen += 1
            }

            newLengths.append(blockLen)
        }

        coordinator.blockLengths = newLengths
    }

    // MARK: - Attributed String Building

    private func buildAttributedString(coordinator: Coordinator) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale
        var lengths: [Int] = []

        for (i, block) in blocks.enumerated() {
            let isFirst = i == 0

            let attr = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: isFirst ? nil : blocks[i - 1],
                bodyFontSize: bodyFontSize,
                scale: scale
            )
            result.append(attr)

            var blockLen = attr.length
            if i < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n"))
                blockLen += 1
            }
            lengths.append(blockLen)
        }

        coordinator.blockLengths = lengths
        return result
    }

    private func renderBlock(
        _ block: SelectableTextBlock,
        isFirst: Bool,
        previousBlock: SelectableTextBlock?,
        bodyFontSize: CGFloat,
        scale: CGFloat
    ) -> NSMutableAttributedString {
        let spacing = isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock)

        switch block {
        case .paragraph(let text):
            let attrString = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular)
            applyParagraphStyle(to: attrString, lineSpacing: LineSpacing.paragraph, spacingBefore: spacing)
            return attrString

        case .heading(let level, let text):
            let fontSize = headingSize(level: level, scale: scale)
            let weight = level <= 2 ? NSFont.Weight.bold : .semibold
            let attrString = renderInlineMarkdown(text, fontSize: fontSize, weight: weight)
            applyParagraphStyle(to: attrString, lineSpacing: LineSpacing.heading, spacingBefore: spacing)
            if level <= 2 {
                attrString.addAttribute(
                    .headingUnderline,
                    value: true,
                    range: NSRange(location: 0, length: attrString.length)
                )
            }
            return attrString

        case .blockquote(let text):
            let attrString = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular, isItalic: true)
            let fullRange = NSRange(location: 0, length: attrString.length)
            attrString.addAttribute(.foregroundColor, value: NSColor(theme.secondaryText), range: fullRange)
            attrString.addAttribute(.blockquoteMarker, value: true, range: fullRange)
            applyParagraphStyle(
                to: attrString,
                lineSpacing: LineSpacing.blockquote,
                spacingBefore: spacing,
                leftIndent: 20
            )
            return attrString

        case .listItem(let text, let itemIndex, let ordered, let indentLevel):
            let bulletWidth: CGFloat = ordered ? 28 : 20
            let bullet = ordered ? "\(itemIndex + 1)." : "•"

            let fullLine = NSMutableAttributedString()
            fullLine.append(
                NSMutableAttributedString(
                    string: bullet,
                    attributes: [
                        .font: nsFont(size: bodyFontSize, weight: .medium),
                        .foregroundColor: NSColor(theme.accentColor),
                    ]
                )
            )
            fullLine.append(NSAttributedString(string: "\t"))
            fullLine.append(renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular))

            applyListParagraphStyle(
                to: fullLine,
                lineSpacing: LineSpacing.listItem,
                spacingBefore: spacing,
                bulletWidth: bulletWidth,
                indentLevel: indentLevel
            )
            return fullLine

        case .horizontalRule:
            let hrText = String(repeating: "\u{2500}", count: 40)
            let hrAttr = NSMutableAttributedString(
                string: hrText,
                attributes: [
                    .font: cachedFont(size: bodyFontSize * 0.5, weight: .ultraLight, italic: false),
                    .foregroundColor: NSColor(theme.primaryBorder.opacity(0.4)),
                ]
            )
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = spacing
            style.paragraphSpacing = 4
            hrAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: hrAttr.length))
            return hrAttr

        case .table(let headers, let rows):
            let tableText = renderTableAsText(headers: headers, rows: rows)
            let tableAttr = NSMutableAttributedString(
                string: tableText,
                attributes: [
                    .font: cachedMonoFont(size: bodyFontSize * 0.85, weight: .regular),
                    .foregroundColor: NSColor(theme.primaryText),
                ]
            )
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacingBefore = spacing
            tableAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: tableAttr.length))

            // Bold header row
            if let firstNewline = tableText.firstIndex(of: "\n") {
                let headerLength = tableText.distance(from: tableText.startIndex, to: firstNewline)
                tableAttr.addAttribute(
                    .font,
                    value: cachedMonoFont(size: bodyFontSize * 0.85, weight: .semibold),
                    range: NSRange(location: 0, length: headerLength)
                )
            }
            return tableAttr
        }
    }

    /// Render a markdown table as aligned monospace text
    private func renderTableAsText(headers: [String], rows: [[String]]) -> String {
        // Calculate column widths
        var colWidths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < colWidths.count {
                colWidths[i] = max(colWidths[i], cell.count)
            }
        }

        func padCell(_ text: String, width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }

        var lines: [String] = []

        // Header
        let headerLine = headers.enumerated().map { i, h in padCell(h, width: colWidths[i]) }.joined(separator: "  ")
        lines.append(headerLine)

        // Separator
        let separator = colWidths.map { String(repeating: "\u{2500}", count: $0) }.joined(separator: "  ")
        lines.append(separator)

        // Rows
        for row in rows {
            let rowLine = row.enumerated().map { i, cell in
                padCell(cell, width: i < colWidths.count ? colWidths[i] : cell.count)
            }.joined(separator: "  ")
            lines.append(rowLine)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Paragraph Style Helpers

    private func applyParagraphStyle(
        to attrString: NSMutableAttributedString,
        lineSpacing: CGFloat,
        spacingBefore: CGFloat,
        leftIndent: CGFloat = 0
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = spacingBefore
        paragraphStyle.firstLineHeadIndent = leftIndent
        paragraphStyle.headIndent = leftIndent

        attrString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attrString.length)
        )
    }

    private func applyListParagraphStyle(
        to attrString: NSMutableAttributedString,
        lineSpacing: CGFloat,
        spacingBefore: CGFloat,
        bulletWidth: CGFloat,
        indentLevel: Int = 0
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = spacingBefore

        // Base indent for the list, plus additional indent per nesting level
        let baseIndent: CGFloat = 24
        let indentPerLevel: CGFloat = 20
        let totalIndent = baseIndent + (CGFloat(indentLevel) * indentPerLevel)

        // Hanging indent: bullet at left margin, text indented
        paragraphStyle.firstLineHeadIndent = totalIndent
        paragraphStyle.headIndent = totalIndent + bulletWidth  // Wrap text aligns with first line text

        // Tab stop for text after bullet
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: totalIndent + bulletWidth, options: [:])
        ]

        attrString.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attrString.length)
        )
    }

    private func spacingBefore(block: SelectableTextBlock, previousBlock: SelectableTextBlock?) -> CGFloat {
        guard previousBlock != nil else { return 0 }

        switch block {
        case .heading(let level, _):
            if case .heading = previousBlock {
                return BlockSpacing.headingAfterHeading
            }
            return level <= 2 ? BlockSpacing.headingH1H2AfterOther : BlockSpacing.headingH3PlusAfterOther

        case .blockquote:
            if case .blockquote = previousBlock {
                return BlockSpacing.blockquoteAfterBlockquote
            }
            return BlockSpacing.blockquoteAfterOther

        case .listItem:
            if case .listItem = previousBlock {
                return BlockSpacing.listItemAfterListItem
            }
            return BlockSpacing.listItemAfterOther

        case .paragraph:
            return BlockSpacing.paragraphAfterOther

        case .horizontalRule:
            return BlockSpacing.horizontalRuleAfterOther

        case .table:
            return BlockSpacing.tableAfterOther
        }
    }

    // MARK: - Inline Markdown Rendering

    /// Quick check if text likely contains markdown syntax (avoids expensive parsing for plain text)
    @inline(__always)
    private func likelyContainsMarkdown(_ text: String) -> Bool {
        text.contains("*") || text.contains("_") || text.contains("`") || text.contains("[") || text.contains("~")
    }

    @inline(__always)
    private func containsInlineMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(")
    }

    private func renderInlineMarkdown(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        isItalic: Bool = false
    ) -> NSMutableAttributedString {
        // Base attributes - use cached font
        let baseFont = cachedFont(size: fontSize, weight: weight, italic: isItalic)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor(theme.primaryText),
        ]

        // Check for inline math — if present, split and render segments
        if containsInlineMath(text) {
            let segments = splitInlineMath(text)
            if segments.contains(where: { $0.isMath }) {
                return renderSegmentsWithMath(
                    segments,
                    fontSize: fontSize,
                    weight: weight,
                    isItalic: isItalic,
                    baseAttributes: baseAttributes
                )
            }
        }

        // Fast path: skip markdown parsing for plain text
        guard likelyContainsMarkdown(text) else {
            return NSMutableAttributedString(string: text, attributes: baseAttributes)
        }

        // Try to parse as markdown
        if let markdownAttr = try? NSAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Convert to mutable and apply theme styling
            let mutable = NSMutableAttributedString(attributedString: markdownAttr)
            applyThemeStyling(to: mutable, baseFontSize: fontSize, baseWeight: weight, isItalic: isItalic)
            return mutable
        }

        // Fallback to plain text
        return NSMutableAttributedString(string: text, attributes: baseAttributes)
    }

    // MARK: - Inline Math Helpers

    private struct InlineSegment {
        let text: String
        let isMath: Bool
    }

    /// Split text into alternating plain-text and math segments.
    /// Handles `$...$` (no whitespace padding) and `\(...\)` delimiters.
    private func splitInlineMath(_ text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        @inline(__always)
        func flushText() {
            if !current.isEmpty {
                segments.append(InlineSegment(text: current, isMath: false))
                current = ""
            }
        }

        while i < scalars.count {
            // \(...\) delimiter
            if i + 1 < scalars.count && scalars[i] == "\\" && scalars[i + 1] == "(" {
                flushText()
                i += 2
                var math = ""
                while i < scalars.count {
                    if i + 1 < scalars.count && scalars[i] == "\\" && scalars[i + 1] == ")" {
                        i += 2
                        break
                    }
                    math.append(String(scalars[i]))
                    i += 1
                }
                if !math.isEmpty {
                    segments.append(InlineSegment(text: math, isMath: true))
                }
                continue
            }

            // Escaped \$ — not a math delimiter
            if scalars[i] == "\\" && i + 1 < scalars.count && scalars[i + 1] == "$" {
                current.append("$")
                i += 2
                continue
            }

            // $...$ delimiter — require non-whitespace after opening and before closing $
            if scalars[i] == "$"
                && i + 1 < scalars.count
                && !scalars[i + 1].properties.isWhitespace
                && scalars[i + 1] != "$"
            {
                if let closeIdx = findClosingDollar(scalars, from: i + 1) {
                    let start = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: i + 1)
                    let end = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: closeIdx)
                    flushText()
                    segments.append(InlineSegment(text: String(text.unicodeScalars[start ..< end]), isMath: true))
                    i = closeIdx + 1
                    continue
                }
            }

            current.append(String(scalars[i]))
            i += 1
        }

        flushText()
        return segments
    }

    /// Find the index of a closing `$` that has no whitespace before it.
    private func findClosingDollar(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start
        while j < scalars.count {
            if scalars[j] == "$" && !scalars[j - 1].properties.isWhitespace {
                return j
            }
            j += 1
        }
        return nil
    }

    /// Build an attributed string from mixed text/math segments.
    private func renderSegmentsWithMath(
        _ segments: [InlineSegment],
        fontSize: CGFloat,
        weight: NSFont.Weight,
        isItalic: Bool,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let textColor = NSColor(theme.primaryText)

        for segment in segments {
            if segment.isMath {
                if let image = LaTeXRenderer.shared.renderToImage(
                    latex: segment.text,
                    fontSize: fontSize,
                    textColor: textColor
                ) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    // Align baseline: shift down so math sits on the text baseline
                    let yOffset = -(image.size.height - fontSize) / 2 - 1
                    attachment.bounds = CGRect(
                        x: 0,
                        y: yOffset,
                        width: image.size.width,
                        height: image.size.height
                    )
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    // Fallback: render the raw LaTeX as code-styled text
                    let fallback = NSMutableAttributedString(string: "$\(segment.text)$", attributes: baseAttributes)
                    result.append(fallback)
                }
            } else {
                // Render plain text through the standard markdown path
                if likelyContainsMarkdown(segment.text),
                    let markdownAttr = try? NSAttributedString(
                        markdown: segment.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    )
                {
                    let mutable = NSMutableAttributedString(attributedString: markdownAttr)
                    applyThemeStyling(to: mutable, baseFontSize: fontSize, baseWeight: weight, isItalic: isItalic)
                    result.append(mutable)
                } else {
                    result.append(NSMutableAttributedString(string: segment.text, attributes: baseAttributes))
                }
            }
        }
        return result
    }

    // MARK: - Font Caching

    /// Bounded font cache — evicts automatically under memory pressure.
    private static let fontCache: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 50
        return cache
    }()

    private func cachedFont(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let key = "\(theme.primaryFontName)-\(size)-\(weight.rawValue)-\(italic)" as NSString
        if let cached = Self.fontCache.object(forKey: key) {
            return cached
        }
        let font = nsFont(size: size, weight: weight, italic: italic)
        Self.fontCache.setObject(font, forKey: key)
        return font
    }

    private func cachedMonoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = "mono-\(theme.monoFontName)-\(size)-\(weight.rawValue)" as NSString
        if let cached = Self.fontCache.object(forKey: key) {
            return cached
        }
        let font = nsMonoFont(size: size, weight: weight)
        Self.fontCache.setObject(font, forKey: key)
        return font
    }

    private func applyThemeStyling(
        to attrString: NSMutableAttributedString,
        baseFontSize: CGFloat,
        baseWeight: NSFont.Weight,
        isItalic: Bool
    ) {
        let fullRange = NSRange(location: 0, length: attrString.length)

        // Cache colors to avoid repeated conversions
        let primaryTextColor = NSColor(theme.primaryText)
        let accentColor = NSColor(theme.accentColor)

        // Apply base text color
        attrString.addAttribute(.foregroundColor, value: primaryTextColor, range: fullRange)

        // Pre-cache common fonts
        let baseFont = cachedFont(size: baseFontSize, weight: baseWeight, italic: isItalic)
        let boldFont = cachedFont(size: baseFontSize, weight: .bold, italic: false)
        let boldItalicFont = cachedFont(size: baseFontSize, weight: .bold, italic: true)
        let italicFont = cachedFont(size: baseFontSize, weight: baseWeight, italic: true)
        let codeFont = cachedMonoFont(size: baseFontSize * 0.9, weight: .regular)

        // Enumerate and fix fonts/styles
        attrString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var newFont = baseFont

            if let existingFont = attributes[.font] as? NSFont {
                let traits = existingFont.fontDescriptor.symbolicTraits

                // Check for inline code (usually monospace)
                if traits.contains(.monoSpace) {
                    // Inline code styling
                    attrString.addAttribute(.font, value: codeFont, range: range)
                    attrString.addAttribute(.foregroundColor, value: accentColor, range: range)
                    return
                }

                // Determine weight and italic from existing font
                let isBold = traits.contains(.bold) || baseWeight == .bold || baseWeight == .semibold
                let fontIsItalic = traits.contains(.italic) || isItalic

                // Use pre-cached fonts
                if isBold && fontIsItalic {
                    newFont = boldItalicFont
                } else if isBold {
                    newFont = boldFont
                } else if fontIsItalic {
                    newFont = italicFont
                }
            }

            attrString.addAttribute(.font, value: newFont, range: range)

            // Style links
            if attributes[.link] != nil {
                attrString.addAttribute(.foregroundColor, value: accentColor, range: range)
                attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    // MARK: - Font Helpers

    private func nsFont(size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        let fontName = theme.primaryFontName

        // System font
        if fontName.lowercased().contains("sf pro") || fontName.isEmpty {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            return font
        }

        // Custom font
        if let customFont = NSFont(name: fontName, size: size) {
            var font = customFont
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            // Apply weight
            let weightValue = weightToNumber(weight)
            font =
                NSFontManager.shared.font(
                    withFamily: fontName,
                    traits: italic ? .italicFontMask : [],
                    weight: weightValue,
                    size: size
                ) ?? font
            return font
        }

        // Fallback
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func nsMonoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fontName = theme.monoFontName

        // System mono font
        if fontName.lowercased().contains("sf mono") || fontName.isEmpty {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        // Custom mono font
        if let customFont = NSFont(name: fontName, size: size) {
            return customFont
        }

        // Fallback
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func weightToNumber(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        case .black: return 11
        default: return 5
        }
    }

    // MARK: - Sizing Helpers

    private func headingSize(level: Int, scale: CGFloat) -> CGFloat {
        switch level {
        case 1: return CGFloat(theme.titleSize) * scale
        case 2: return (CGFloat(theme.titleSize) - 4) * scale
        case 3: return CGFloat(theme.headingSize) * scale
        case 4: return (CGFloat(theme.headingSize) - 2) * scale
        case 5: return (CGFloat(theme.bodySize) + 2) * scale
        default: return CGFloat(theme.bodySize) * scale
        }
    }

    // MARK: - Theme Fingerprint

    private func makeThemeFingerprint() -> String {
        "\(theme.primaryFontName)|\(theme.monoFontName)|\(theme.titleSize)|\(theme.headingSize)|\(theme.bodySize)|\(theme.captionSize)|\(theme.codeSize)"
    }
}

// MARK: - Custom NSTextView

/// Custom NSTextView that handles link clicks, cursor changes, blockquote bars, and heading underlines.
/// Code blocks are now rendered as standalone `CodeBlockView` / `CodeNSTextView` — no code-block
/// drawing happens here.
final class SelectableNSTextView: NSTextView {

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        if charIndex < textStorage?.length ?? 0,
            let link = textStorage?.attribute(.link, at: charIndex, effectiveRange: nil)
        {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url {
                NSWorkspace.shared.open(url)
                return
            }
        }

        super.mouseDown(with: event)
    }

    /// Theme colors for custom drawing (set by SelectableTextView on update)
    var accentColor: NSColor = .controlAccentColor
    var blockquoteBarColor: NSColor = .controlAccentColor
    var secondaryBackgroundColor: NSColor = .clear

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager = layoutManager,
            let textContainer = textContainer,
            let textStorage = textStorage
        else {
            super.draw(dirtyRect)
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Draw blockquote accent bars
        textStorage.enumerateAttribute(.blockquoteMarker, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: gr, in: textContainer)
            rect.origin.x = 0; rect.size.width = bounds.width

            guard rect.intersects(dirtyRect) else { return }

            secondaryBackgroundColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 4, y: rect.origin.y - 2, width: rect.width - 8, height: rect.height + 4),
                xRadius: 6,
                yRadius: 6
            ).fill()

            blockquoteBarColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 6, y: rect.origin.y - 2, width: 3, height: rect.height + 4),
                xRadius: 1.5,
                yRadius: 1.5
            ).fill()
        }

        // Draw heading underlines (H1/H2)
        textStorage.enumerateAttribute(.headingUnderline, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: gr, in: textContainer)
            let lineRect = NSRect(x: 0, y: rect.maxY + 4, width: bounds.width, height: 1)

            guard lineRect.intersects(dirtyRect) else { return }

            NSGradient(colors: [accentColor.withAlphaComponent(0.3), accentColor.withAlphaComponent(0.05)])?
                .draw(in: lineRect, angle: 0)
        }

        super.draw(dirtyRect)
    }
}
