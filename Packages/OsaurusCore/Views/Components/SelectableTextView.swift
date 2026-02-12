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
    static let codeBlockAfterOther: CGFloat = 14
    static let horizontalRuleAfterOther: CGFloat = 8
    static let tableAfterOther: CGFloat = 14
}

// MARK: - Syntax Highlighting Keywords

private enum SyntaxKeywords {
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
    case codeBlock(code: String, language: String?)
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
    /// Optional overlay data for code block copy buttons (provided by wrapper view)
    var overlayData: CodeBlockOverlayData? = nil

    /// Observable object that publishes code block overlay data to SwiftUI
    final class CodeBlockOverlayData: ObservableObject {
        struct OverlayItem: Identifiable {
            let id: Int
            let code: String
            let language: String?
            let rect: CGRect
        }

        @Published var items: [OverlayItem] = []
    }

    final class Coordinator {
        var lastBlocks: [SelectableTextBlock] = []
        var lastWidth: CGFloat = 0
        var lastThemeFingerprint: String = ""
        var lastMeasuredHeight: CGFloat = 0
        var cacheKey: String? = nil
        var blockLengths: [Int] = []  // per-block rendered lengths for incremental updates
        var codeBlockInfos: [SelectableNSTextView.CodeBlockInfo] = []
        weak var overlayData: CodeBlockOverlayData?
        /// Disables ThreadCache lookups once content changes (prevents stale heights during streaming)
        var contentChangedSinceInit: Bool = false

        init(cacheKey: String? = nil) {
            self.cacheKey = cacheKey
        }

        /// Publish overlay rects for code block copy buttons (deferred to avoid mid-update publishing)
        @MainActor
        func updateOverlayRects(textView: SelectableNSTextView) {
            guard let overlayData else { return }
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                DispatchQueue.main.async { overlayData.items = [] }
                return
            }

            let items: [CodeBlockOverlayData.OverlayItem] = codeBlockInfos.enumerated().map { index, info in
                let glyphRange = layoutManager.glyphRange(forCharacterRange: info.range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x = 0
                rect.size.width = textView.bounds.width
                return .init(id: index, code: info.code, language: info.language, rect: rect)
            }
            DispatchQueue.main.async { overlayData.items = items }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(cacheKey: cacheKey)
        coordinator.overlayData = overlayData
        return coordinator
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
        textView.lineNumberColor = NSColor(theme.tertiaryText.opacity(0.4))

        return textView
    }

    func updateNSView(_ textView: SelectableNSTextView, context: Context) {
        // Keep overlay data reference up to date
        context.coordinator.overlayData = overlayData

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
        textView.lineNumberColor = NSColor(theme.tertiaryText.opacity(0.4))

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
            textView.codeBlockInfos = context.coordinator.codeBlockInfos
            textView.needsDisplay = true
            context.coordinator.updateOverlayRects(textView: textView)
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
        let measured = ceil(lm.usedRect(for: tc).height) + 4

        coord.lastWidth = width
        coord.lastMeasuredHeight = measured
        coord.updateOverlayRects(textView: nsView)

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
        rebuildCodeBlockInfos(blocks: newBlocks, lengths: newLengths, coordinator: coordinator)
    }

    /// Rebuild code block range info from block lengths
    private func rebuildCodeBlockInfos(
        blocks: [SelectableTextBlock],
        lengths: [Int],
        coordinator: Coordinator
    ) {
        let bodyFontSize = CGFloat(theme.bodySize) * Typography.scale(for: baseWidth)
        var codeInfos: [SelectableNSTextView.CodeBlockInfo] = []
        var offset = 0

        for (i, block) in blocks.enumerated() {
            let blockLen = i < lengths.count ? lengths[i] : 0
            let hasTrailingNewline = i < blocks.count - 1
            let contentLen = hasTrailingNewline ? max(0, blockLen - 1) : blockLen

            if case .codeBlock(let code, let language) = block {
                codeInfos.append(
                    makeCodeBlockInfo(
                        code: code,
                        language: language,
                        offset: offset,
                        length: contentLen,
                        bodyFontSize: bodyFontSize
                    )
                )
            }
            offset += blockLen
        }

        coordinator.codeBlockInfos = codeInfos
    }

    /// Build a `CodeBlockInfo` from code content and positional data
    private func makeCodeBlockInfo(
        code: String,
        language: String?,
        offset: Int,
        length: Int,
        bodyFontSize: CGFloat
    ) -> SelectableNSTextView.CodeBlockInfo {
        let lineCount = code.components(separatedBy: "\n").count
        let gutterDigits = "\(lineCount)".count
        let codeFontSize = bodyFontSize * 0.85
        let gutterPointWidth = CGFloat(gutterDigits + 2) * codeFontSize * 0.62

        return SelectableNSTextView.CodeBlockInfo(
            code: code,
            language: language,
            range: NSRange(location: offset, length: length),
            codeStartOffset: offset + 1,  // +1 for header pad "\n"
            lineCount: lineCount,
            gutterPointWidth: gutterPointWidth,
            codeFontSize: codeFontSize
        )
    }

    // MARK: - Attributed String Building

    private func buildAttributedString(coordinator: Coordinator) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale
        var lengths: [Int] = []
        var codeInfos: [SelectableNSTextView.CodeBlockInfo] = []

        for (i, block) in blocks.enumerated() {
            let isFirst = i == 0
            let offset = result.length

            let attr = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: isFirst ? nil : blocks[i - 1],
                bodyFontSize: bodyFontSize,
                scale: scale
            )
            result.append(attr)

            if case .codeBlock(let code, let language) = block {
                codeInfos.append(
                    makeCodeBlockInfo(
                        code: code,
                        language: language,
                        offset: offset,
                        length: attr.length,
                        bodyFontSize: bodyFontSize
                    )
                )
            }

            var blockLen = attr.length
            if i < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n"))
                blockLen += 1
            }
            lengths.append(blockLen)
        }

        coordinator.blockLengths = lengths
        coordinator.codeBlockInfos = codeInfos
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

        case .codeBlock(let code, let language):
            let codeFontSize = bodyFontSize * 0.85
            let codeFont = cachedMonoFont(size: codeFontSize, weight: .regular)
            let codeColor = NSColor(theme.primaryText.opacity(0.95))
            let bgColor = NSColor(theme.codeBlockBackground)
            let lines = code.components(separatedBy: "\n")

            let result = NSMutableAttributedString()

            // Header pad: invisible line that reserves space for the overlay bar
            result.append(makeCodeBlockHeaderPad(bgColor: bgColor, spacingBefore: isFirst ? 8 : spacing))

            let codeStart = result.length

            // Code content (line numbers are drawn separately in draw(_:))
            for (i, line) in lines.enumerated() {
                let highlighted = highlightSyntax(line, language: language, font: codeFont, defaultColor: codeColor)
                highlighted.addAttribute(
                    .backgroundColor,
                    value: bgColor,
                    range: NSRange(location: 0, length: highlighted.length)
                )
                result.append(highlighted)
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: [.backgroundColor: bgColor]))
                }
            }

            // Indent code past the gutter area
            let gutterDigits = "\(lines.count)".count
            let gutterWidth = CGFloat(gutterDigits + 2) * codeFontSize * 0.62
            let indent: CGFloat = 12 + gutterWidth
            let codeStyle = NSMutableParagraphStyle()
            codeStyle.lineSpacing = 2
            codeStyle.paragraphSpacing = 8
            codeStyle.firstLineHeadIndent = indent
            codeStyle.headIndent = indent
            codeStyle.tailIndent = -12

            let codeRange = NSRange(location: codeStart, length: result.length - codeStart)
            if codeRange.length > 0 {
                result.addAttribute(.paragraphStyle, value: codeStyle, range: codeRange)
            }
            return result

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

    /// Invisible header pad line for code blocks (reserves space for the overlay bar)
    private func makeCodeBlockHeaderPad(bgColor: NSColor, spacingBefore: CGFloat) -> NSMutableAttributedString {
        let pad = NSMutableAttributedString(
            string: "\n",
            attributes: [
                .font: cachedMonoFont(size: 8, weight: .regular),
                .foregroundColor: NSColor.clear,
                .backgroundColor: bgColor,
            ]
        )
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.minimumLineHeight = 28
        style.maximumLineHeight = 28
        pad.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: pad.length))
        return pad
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

        case .codeBlock:
            return BlockSpacing.codeBlockAfterOther

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
        // Check for common inline markdown characters
        // This is a fast heuristic to skip markdown parsing for plain text
        text.contains("*") || text.contains("_") || text.contains("`") || text.contains("[") || text.contains("~")
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

    // MARK: - Syntax Highlighting

    // MARK: - Regex Cache

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    /// Lightweight keyword-based syntax highlighter for code blocks.
    /// Handles comments, strings, numbers, and language-specific keywords.
    private func highlightSyntax(
        _ line: String,
        language: String?,
        font: NSFont,
        defaultColor: NSColor
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(
            string: line,
            attributes: [.font: font, .foregroundColor: defaultColor]
        )

        guard let lang = language?.lowercased(), !line.isEmpty else { return result }

        let commentColor = NSColor(theme.tertiaryText.opacity(0.6))
        let stringColor = NSColor(theme.successColor.opacity(0.85))
        let keywordColor = NSColor(theme.accentColor)
        let numberColor = NSColor(theme.warningColor.opacity(0.85))
        let typeColor = NSColor(theme.infoColor)

        let fullRange = NSRange(location: 0, length: (line as NSString).length)

        // 1. Line comments (// or # depending on language)
        let commentPrefix: String? = {
            switch lang {
            case "python", "py", "ruby", "rb", "bash", "sh", "shell", "zsh", "yaml", "yml", "toml":
                return "#"
            case "swift", "javascript", "js", "typescript", "ts", "java", "kotlin", "c", "cpp", "c++",
                "rust", "go", "json", "css", "scss", "sass", "php":
                return "//"
            case "sql":
                return "--"
            case "html", "xml":
                return nil  // handled separately with <!-- -->
            default:
                return "//"
            }
        }()

        if let prefix = commentPrefix {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                result.addAttribute(.foregroundColor, value: commentColor, range: fullRange)
                return result
            }
        }

        // HTML/XML comments
        if (lang == "html" || lang == "xml") && line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
            result.addAttribute(.foregroundColor, value: commentColor, range: fullRange)
            return result
        }

        // 2. Strings (double and single quoted)
        if let regex = Self.cachedRegex(#"(\"[^\"\\]*(?:\\.[^\"\\]*)*\"|'[^'\\]*(?:\\.[^'\\]*)*')"#) {
            for match in regex.matches(in: line, range: fullRange) {
                result.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }

        // 3. Numbers (integer and float literals)
        if let regex = Self.cachedRegex(#"\b(\d+\.?\d*)\b"#) {
            for match in regex.matches(in: line, range: fullRange) {
                // Don't colorize if inside a string (check if already colored)
                var existingColor: NSColor?
                if match.range.location < result.length {
                    existingColor =
                        result.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor
                }
                if existingColor == defaultColor {
                    result.addAttribute(.foregroundColor, value: numberColor, range: match.range)
                }
            }
        }

        // 4. Language keywords
        let keywords: [String] = SyntaxKeywords.keywords(for: lang)
        if !keywords.isEmpty {
            for keyword in keywords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                if let regex = Self.cachedRegex(pattern) {
                    for match in regex.matches(in: line, range: fullRange) {
                        // Only apply if not inside a string
                        var existingColor: NSColor?
                        if match.range.location < result.length {
                            existingColor =
                                result.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil)
                                as? NSColor
                        }
                        if existingColor == defaultColor {
                            result.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                            result.addAttribute(
                                .font,
                                value: cachedMonoFont(size: font.pointSize, weight: .medium),
                                range: match.range
                            )
                        }
                    }
                }
            }
        }

        // 5. Type names (capitalized identifiers like String, Int, etc.)
        if let regex = Self.cachedRegex(#"\b([A-Z][a-zA-Z0-9_]*)\b"#) {
            for match in regex.matches(in: line, range: fullRange) {
                var existingColor: NSColor?
                if match.range.location < result.length {
                    existingColor =
                        result.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor
                }
                if existingColor == defaultColor {
                    result.addAttribute(.foregroundColor, value: typeColor, range: match.range)
                }
            }
        }

        return result
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

// MARK: - Selectable Text View with Code Block Overlays

/// Wraps `SelectableTextView` with code block overlays (language label + copy)
struct SelectableTextWithOverlays: View {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    let theme: ThemeProtocol
    var cacheKey: String? = nil

    @StateObject private var overlayData = SelectableTextView.CodeBlockOverlayData()
    @State private var hoveredCodeBlock: Int? = nil

    var body: some View {
        SelectableTextView(
            blocks: blocks,
            baseWidth: baseWidth,
            theme: theme,
            cacheKey: cacheKey,
            overlayData: overlayData
        )
        .frame(minWidth: baseWidth, maxWidth: baseWidth, alignment: .leading)
        .overlay(alignment: .topLeading) {
            ForEach(overlayData.items) { item in
                ZStack(alignment: .top) {
                    Color.clear
                        .frame(width: item.rect.width, height: item.rect.height)
                        .allowsHitTesting(false)

                    CodeBlockCopyOverlay(
                        code: item.code,
                        language: item.language,
                        width: item.rect.width,
                        isHovered: hoveredCodeBlock == item.id,
                        theme: theme
                    )
                    .frame(height: 30)
                }
                .frame(width: item.rect.width, height: item.rect.height)
                .offset(x: item.rect.origin.x, y: item.rect.origin.y)
                .onHover { hovering in
                    hoveredCodeBlock = hovering ? item.id : nil
                }
            }
        }
    }
}

/// Language label overlay for a single code block
private struct CodeBlockCopyOverlay: View {
    let code: String
    let language: String?
    let width: CGFloat
    let isHovered: Bool
    let theme: ThemeProtocol

    @State private var copied = false

    var body: some View {
        HStack {
            // Language label (always visible)
            Text(language?.lowercased() ?? "code")
                .font(theme.monoFont(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            Spacer(minLength: 0)

            // Copy button (shown on hover)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(copied ? theme.successColor : theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
            .animation(theme.animationQuick(), value: isHovered)
        }
        .padding(.horizontal, 12)
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Custom NSTextView

/// Custom NSTextView that handles link clicks, cursor changes, and code block background drawing.
/// Sizing is driven by `SelectableTextView.sizeThatFits` -- no custom
/// intrinsicContentSize override is needed.
final class SelectableNSTextView: NSTextView {

    /// Code block ranges and their metadata for overlay rendering (copy buttons)
    var codeBlockInfos: [CodeBlockInfo] = []

    struct CodeBlockInfo {
        let code: String
        let language: String?
        let range: NSRange
        let codeStartOffset: Int
        let lineCount: Int
        let gutterPointWidth: CGFloat
        let codeFontSize: CGFloat
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Strips invisible header-pad newlines from copied text so users get clean code.
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0, let textStorage else { super.copy(sender); return }

        // Collect header-pad character offsets (within the selection) in reverse order
        // so removing earlier characters doesn't shift later offsets.
        var padOffsets: [Int] = []
        for info in codeBlockInfos {
            let padLoc = info.range.location
            guard padLoc >= sel.location, padLoc < NSMaxRange(sel) else { continue }
            padOffsets.append(padLoc - sel.location)
        }

        var result = (textStorage.string as NSString).substring(with: sel)
        for offset in padOffsets.sorted().reversed() {
            let ns = result as NSString
            guard offset < ns.length, ns.character(at: offset) == 0x0A else { continue }
            result = ns.replacingCharacters(in: NSRange(location: offset, length: 1), with: "")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
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
    var lineNumberColor: NSColor = .tertiaryLabelColor

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager = layoutManager,
            let textContainer = textContainer,
            let textStorage = textStorage
        else {
            super.draw(dirtyRect)
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Draw code block backgrounds with rounded corners
        textStorage.enumerateAttribute(.backgroundColor, in: fullRange, options: []) { value, range, _ in
            guard let bgColor = value as? NSColor else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = bounds.width

            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            bgColor.setFill()
            path.fill()
        }

        // Draw line numbers in code block gutters
        let nsString = textStorage.string as NSString
        for info in codeBlockInfos {
            guard info.lineCount > 0 else { continue }

            let font = NSFont.monospacedSystemFont(ofSize: info.codeFontSize, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: lineNumberColor]
            let digits = "\(info.lineCount)".count
            let charWidth = info.codeFontSize * 0.62
            let leftPad: CGFloat = 12
            let blockEnd = NSMaxRange(info.range)
            var charIndex = info.codeStartOffset

            for lineNum in 1 ... info.lineCount {
                guard charIndex < blockEnd, charIndex < textStorage.length else { break }

                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

                let numStr = String(lineNum).padding(toLength: digits, withPad: " ", startingAt: 0) as NSString
                let numSize = numStr.size(withAttributes: attrs)
                let x = leftPad + info.gutterPointWidth - numSize.width - charWidth * 1.2
                let y = fragRect.origin.y + (fragRect.height - numSize.height) / 2

                numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

                let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
                charIndex = NSMaxRange(lineRange)
            }
        }

        // Draw blockquote accent bars
        textStorage.enumerateAttribute(.blockquoteMarker, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: gr, in: textContainer)
            rect.origin.x = 0; rect.size.width = bounds.width

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
            NSGradient(colors: [accentColor.withAlphaComponent(0.3), accentColor.withAlphaComponent(0.05)])?
                .draw(in: lineRect, angle: 0)
        }

        super.draw(dirtyRect)
    }
}
