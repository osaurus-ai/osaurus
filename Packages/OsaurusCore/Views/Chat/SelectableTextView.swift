//
//  SelectableTextView.swift
//  osaurus
//
//  NSTextView wrapper for web-like text selection across markdown blocks
//

import AppKit
import SwiftUI

// MARK: - Typography Spacing Constants

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
    static let inspectionMinimumLineHeight = NSAttributedString.Key("osaurus.inspectionLineHeight")
    /// Marks a range as a heading that should have an underline (H1/H2)
    static let headingUnderline = NSAttributedString.Key("osaurus.headingUnderline")
}

// MARK: - Selectable Text View

struct SelectableTextView: NSViewRepresentable {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    private let sourceTheme: any ThemeProtocol
    var theme: any ThemeProtocol { RichTextInspectionStyle.scope(sourceTheme) }
    init(blocks: [SelectableTextBlock], baseWidth: CGFloat, theme: any ThemeProtocol, cacheKey: String? = nil) {
        self.blocks = blocks; self.baseWidth = baseWidth; self.sourceTheme = theme; self.cacheKey = cacheKey
    }
    /// Optional cache key (turn ID) for persisting measured height across view recycling
    var cacheKey: String? = nil

    final class Coordinator {
        var lastBlocks: [SelectableTextBlock] = []
        var lastWidth: CGFloat = 0
        var lastThemeFingerprint: Int?
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
        // TextKit 1 from birth — this view reads `.layoutManager` for hit
        // testing and drawing, which would otherwise force a lazy TextKit 2 → 1
        // downgrade mid-lifecycle (see EditableTextView.makeNSView).
        let textView = SelectableNSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        // disable idle-time text features. NSTextView's defaults run these against
        // textStorage on every edit which is useless overhead for read-only model output and
        // measurably expensive at 60Hz streaming
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        // Don't allow scrolling - we size to fit content
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false

        // Configure text container for fixed width, unlimited height for layout
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        // Selection, cursor and link roles.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selection.background),
            .foregroundColor: NSColor(theme.selection.foreground),
        ]
        textView.insertionPointColor = NSColor(theme.cursor)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(theme.text.link),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        // Set theme colors for custom drawing
        textView.accentColor = NSColor(theme.text.link)
        textView.blockquoteBarColor = NSColor(theme.border.strong)
        textView.secondaryBackgroundColor = NSColor(theme.surface.subtle)
        RichTextInspectionStyle.prepare(textView, theme: theme)

        return textView
    }

    func updateNSView(_ textView: SelectableNSTextView, context: Context) {
        // compute change flags first so every guard below can reference them cheaply
        let themeFingerprint = theme.renderFingerprint
        let widthChanged = abs(context.coordinator.lastWidth - baseWidth) > 0.1
        let themeChanged = context.coordinator.lastThemeFingerprint != themeFingerprint
        let blocksChanged = context.coordinator.lastBlocks != blocks

        // setting containerSize calls textContainerChangedGeometry, which invalidates the
        // entire NSLayoutManager even when the value hasn't changed — guard it so we only
        // pay the layout cost when the width actually differs.
        if widthChanged {
            textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)
        }

        // selectedTextAttributes triggers needsDisplay; accent colors are only used during
        // custom drawing — only push these when the theme actually changes.
        if themeChanged {
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor(theme.selection.background),
                .foregroundColor: NSColor(theme.selection.foreground),
            ]
            textView.insertionPointColor = NSColor(theme.cursor)
            textView.linkTextAttributes = [
                .foregroundColor: NSColor(theme.text.link),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            textView.accentColor = NSColor(theme.text.link)
            textView.blockquoteBarColor = NSColor(theme.border.strong)
            textView.secondaryBackgroundColor = NSColor(theme.surface.subtle)
        RichTextInspectionStyle.prepare(textView, theme: theme)
        }

        if blocksChanged || widthChanged || themeChanged {
            let incrementalPath =
                !widthChanged && !themeChanged && !context.coordinator.lastBlocks.isEmpty
            if incrementalPath {
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
            // incremental path already invalidated a bounded tail rect. full
            // re-assign path needs an unbounded repaint
            if !incrementalPath {
                textView.needsDisplay = true
            }
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

    /// Apply an incremental text-storage update and bound the dirty rect to
    /// the changed tail so WindowServer composites only the affected region.
    /// Returns the character offset where the change begins, so callers can
    /// skip the unbounded `needsDisplay = true` fallback.
    @discardableResult
    func updateTextStorageIncrementally(
        textView: SelectableNSTextView,
        oldBlocks: [SelectableTextBlock],
        newBlocks: [SelectableTextBlock],
        coordinator: Coordinator
    ) -> Int {
        guard let storage = textView.textStorage else { return 0 }

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

        let damageStart = prefixLength

        // One edit session: each mutation outside one runs its own
        // `processEditing` and layout invalidation.
        storage.beginEditing()
        defer { storage.endEditing() }

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
        for i in diffIndex ..< newBlocks.count {
            let isFirst = i == 0
            let attrString = renderBlock(
                newBlocks[i],
                isFirst: isFirst,
                previousBlock: isFirst ? nil : newBlocks[i - 1]
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

        return damageStart
    }

    // MARK: - Package-Internal Convenience Builder

    /// Build an attributed string for the given blocks + theme without going
    /// through the full NSViewRepresentable lifecycle. Used by NativeMarkdownView
    /// to configure a SelectableNSTextView directly.
    static func attributedString(
        for blocks: [SelectableTextBlock],
        width: CGFloat,
        theme: any ThemeProtocol
    ) -> NSMutableAttributedString {
        let view = SelectableTextView(blocks: blocks, baseWidth: width, theme: theme)
        let coord = Coordinator()
        return view.buildAttributedString(coordinator: coord)
    }

    // MARK: - Attributed String Building

    func buildAttributedString(coordinator: Coordinator) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var lengths: [Int] = []

        for (i, block) in blocks.enumerated() {
            let isFirst = i == 0

            let attr = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: isFirst ? nil : blocks[i - 1]
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

    func renderBlock(
        _ block: SelectableTextBlock,
        isFirst: Bool,
        previousBlock: SelectableTextBlock?
    ) -> NSMutableAttributedString {
        let spacing = isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock)

        switch block {
        case .paragraph(let text):
            let attrString = renderInlineMarkdown(text, role: .body)
            applyParagraphStyle(to: attrString, role: .body, spacingBefore: spacing)
            return attrString

        case .heading(let level, let text):
            let role = headingRole(level: level)
            let attrString = renderInlineMarkdown(text, role: role)
            applyParagraphStyle(to: attrString, role: role, spacingBefore: spacing)
            if level <= 2 {
                attrString.addAttribute(
                    .headingUnderline,
                    value: true,
                    range: NSRange(location: 0, length: attrString.length)
                )
            }
            return attrString

        case .blockquote(let text):
            let attrString = renderInlineMarkdown(text, role: .body, isItalic: true)
            let fullRange = NSRange(location: 0, length: attrString.length)
            attrString.addAttribute(.foregroundColor, value: NSColor(theme.text.secondary), range: fullRange)
            attrString.addAttribute(.blockquoteMarker, value: true, range: fullRange)
            applyParagraphStyle(
                to: attrString,
                role: .body,
                spacingBefore: spacing,
                leftIndent: RichTextInspectionStyle.metric("padding", 20, theme)
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
                        .font: font(.body),
                        .foregroundColor: NSColor(theme.text.secondary),
                    ]
                )
            )
            fullLine.append(NSAttributedString(string: "\t"))
            fullLine.append(renderInlineMarkdown(text, role: .body))

            applyListParagraphStyle(
                to: fullLine,
                role: .body,
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
                    .font: font(.caption),
                    .foregroundColor: NSColor(theme.border.subtle),
                ]
            )
            let style = theme.paragraphStyle(.caption, alignment: .center)
            style.paragraphSpacingBefore = spacing
            style.paragraphSpacing = theme.space.s4
            hrAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: hrAttr.length))
            return hrAttr

        case .table(let headers, let rows):
            return renderTable(
                headers: headers,
                rows: rows,
                spacingBefore: spacing
            )
        }
    }

    /// Render a markdown table as an attributed string with inline markdown per cell
    /// and tab-stop-based column alignment.
    /// - Header row is rendered with semibold weight.
    /// - `**bold**` and other inline syntax in cells render as formatted text, not literal.
    /// - Long cells are capped at `maxColumnWidth` (truncated with ellipsis) so the
    ///   wrapped line never bleeds into the next column's tab stop.
    private func renderTable(
        headers: [String],
        rows: [[String]],
        spacingBefore: CGFloat
    ) -> NSMutableAttributedString {
        let columnGap = RichTextInspectionStyle.metric("gap", theme.space.s16, theme)
        let maxColumnWidth: CGFloat = 280

        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return NSMutableAttributedString(string: "")
        }

        // Render each cell (with inline markdown) into an attributed string.
        // Header cells use semibold weight.
        let headerCells: [NSMutableAttributedString] = (0 ..< columnCount).map { i in
            let text = i < headers.count ? headers[i] : ""
            return renderInlineMarkdown(text, role: .label)
        }
        let bodyCells: [[NSMutableAttributedString]] = rows.map { row in
            (0 ..< columnCount).map { i in
                let text = i < row.count ? row[i] : ""
                return renderInlineMarkdown(text, role: .bodySmall)
            }
        }

        // Cap each cell's rendered width by truncating underlying text with an ellipsis.
        func capWidth(_ cell: NSMutableAttributedString) -> NSMutableAttributedString {
            if cell.size().width <= maxColumnWidth { return cell }
            let ellipsisAttr =
                cell.length > 0
                ? cell.attributes(at: max(cell.length - 1, 0), effectiveRange: nil)
                : [:]
            // drop characters from the end until the measured width + "…" fits
            let mutable = NSMutableAttributedString(attributedString: cell)
            while mutable.length > 0 {
                let ellipsis = NSAttributedString(string: "…", attributes: ellipsisAttr)
                let probe = NSMutableAttributedString(attributedString: mutable)
                probe.append(ellipsis)
                if probe.size().width <= maxColumnWidth {
                    mutable.append(ellipsis)
                    return mutable
                }
                mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
            }
            return NSMutableAttributedString(string: "…", attributes: ellipsisAttr)
        }

        let cappedHeaders = headerCells.map(capWidth)
        let cappedRows = bodyCells.map { $0.map(capWidth) }

        // Column widths — max rendered width across header + rows, capped.
        var colWidths: [CGFloat] = (0 ..< columnCount).map { i in
            var w = cappedHeaders[i].size().width
            for row in cappedRows where i < row.count {
                w = max(w, row[i].size().width)
            }
            return min(ceil(w), maxColumnWidth)
        }
        // ensure non-zero widths so tab stops advance
        colWidths = colWidths.map { max($0, 1) }

        // Tab stops: cumulative column starts (column i lands at tab stop i-1).
        var tabStops: [NSTextTab] = []
        var cursor: CGFloat = 0
        for i in 0 ..< (columnCount - 1) {
            cursor += colWidths[i] + columnGap
            tabStops.append(NSTextTab(textAlignment: .left, location: cursor, options: [:]))
        }

        let paragraphStyle = theme.paragraphStyle(.bodySmall, lineBreakMode: .byTruncatingTail)
        paragraphStyle.paragraphSpacingBefore = spacingBefore
        paragraphStyle.tabStops = tabStops
        paragraphStyle.defaultTabInterval = max(columnGap, 1)

        let result = NSMutableAttributedString()

        func appendRow(_ cells: [NSMutableAttributedString], isLast: Bool) {
            for (i, cell) in cells.enumerated() {
                result.append(cell)
                if i < cells.count - 1 {
                    result.append(NSAttributedString(string: "\t"))
                }
            }
            if !isLast {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        // Header row
        appendRow(cappedHeaders, isLast: false)

        // Separator — horizontal rule beneath headers
        let separatorFont = font(.caption)
        let separatorWidth = (cursor + colWidths.last!)
        let ruleAdvance = max(("\u{2500}" as NSString).size(withAttributes: [.font: separatorFont]).width, 1)
        let separator = NSMutableAttributedString(
            string: String(repeating: "\u{2500}", count: max(Int(separatorWidth / ruleAdvance), 8)),
            attributes: [
                .font: separatorFont,
                .foregroundColor: NSColor(theme.border.subtle),
            ]
        )
        result.append(separator)
        result.append(NSAttributedString(string: "\n"))

        // Body rows
        for (idx, row) in cappedRows.enumerated() {
            appendRow(row, isLast: idx == cappedRows.count - 1)
        }

        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    // MARK: - Paragraph Style Helpers

    private func applyParagraphStyle(
        to attrString: NSMutableAttributedString,
        role: ThemeTextStyleRole,
        spacingBefore: CGFloat,
        leftIndent: CGFloat = 0
    ) {
        let paragraphStyle = theme.paragraphStyle(role)
        #if OSAURUS_DESIGN_SYSTEM
        attrString.enumerateAttribute(.inspectionMinimumLineHeight, in: NSRange(location: 0, length: attrString.length)) { value, _, _ in
            if let value = value as? CGFloat { paragraphStyle.minimumLineHeight = max(paragraphStyle.minimumLineHeight, value) }
        }
        #endif
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
        role: ThemeTextStyleRole,
        spacingBefore: CGFloat,
        bulletWidth: CGFloat,
        indentLevel: Int = 0
    ) {
        let paragraphStyle = theme.paragraphStyle(role)
        #if OSAURUS_DESIGN_SYSTEM
        attrString.enumerateAttribute(.inspectionMinimumLineHeight, in: NSRange(location: 0, length: attrString.length)) { value, _, _ in
            if let value = value as? CGFloat { paragraphStyle.minimumLineHeight = max(paragraphStyle.minimumLineHeight, value) }
        }
        #endif
        paragraphStyle.paragraphSpacingBefore = spacingBefore

        // Base indent for the list, plus additional indent per nesting level
        let baseIndent = RichTextInspectionStyle.metric("padding", 24, theme)
        let indentPerLevel = RichTextInspectionStyle.metric("padding", 20, theme)
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
        return RichTextInspectionStyle.metric("gap", originalSpacingBefore(block: block, previousBlock: previousBlock), theme)
    }
    private func originalSpacingBefore(block: SelectableTextBlock, previousBlock: SelectableTextBlock?) -> CGFloat {
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

    private func renderInlineMarkdown(
        _ text: String,
        role: ThemeTextStyleRole,
        isItalic: Bool = false
    ) -> NSMutableAttributedString {
        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font(role, italic: isItalic),
            .foregroundColor: NSColor(theme.text.primary),
        ]
        let tracking = theme.scaledTextStyle(role).tracking
        if tracking != 0 { baseAttributes[.kern] = tracking }

        // Check for inline math — if present, split and render segments
        if InlineMathScanner.mayContainMath(text) {
            let segments = InlineMathScanner.split(text)
            if segments.contains(where: { $0.isMath }) {
                return withKnowledgeLinks(
                    renderSegmentsWithMath(
                        segments,
                        role: role,
                        isItalic: isItalic,
                        baseAttributes: baseAttributes
                    ))
            }
        }

        // Fast path: skip markdown parsing for plain text
        guard likelyContainsMarkdown(text) else {
            return withKnowledgeLinks(NSMutableAttributedString(string: text, attributes: baseAttributes))
        }

        // Try to parse as markdown
        if let markdownAttr = try? NSAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Convert to mutable and apply theme styling
            let mutable = NSMutableAttributedString(attributedString: markdownAttr)
            applyThemeStyling(to: mutable, role: role, isItalic: isItalic, tracking: tracking)
            return withKnowledgeLinks(mutable)
        }

        // Fallback to plain text
        return withKnowledgeLinks(NSMutableAttributedString(string: text, attributes: baseAttributes))
    }

    /// Attach knowledge-document links to paths written as plain prose.
    /// Ranges already linked (markdown links, backticked spans handled in
    /// `applyThemeStyling`) are left untouched.
    private func withKnowledgeLinks(_ attrString: NSMutableAttributedString) -> NSMutableAttributedString {
        let matches = KnowledgeLinkResolver.plainTextMatches(in: attrString.string)
        guard !matches.isEmpty else { return attrString }
        let accentColor = NSColor(theme.text.link)
        for match in matches {
            guard match.range.location + match.range.length <= attrString.length,
                attrString.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
            else { continue }
            attrString.addAttribute(.link, value: match.url, range: match.range)
            attrString.addAttribute(.foregroundColor, value: accentColor, range: match.range)
            attrString.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range
            )
        }
        return attrString
    }

    // MARK: - Inline Math Helpers

    // The delimiter rules live in `InlineMathScanner` so they can be tested without a view.

    /// Build an attributed string from mixed text/math segments.
    private func renderSegmentsWithMath(
        _ segments: [InlineMathScanner.Segment],
        role: ThemeTextStyleRole,
        isItalic: Bool,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let textColor = NSColor(theme.text.primary)
        let fontSize = theme.pointSize(role)

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
                    // Typesetter rejected it — show the source exactly as written.
                    let fallback = NSMutableAttributedString(string: segment.fallback, attributes: baseAttributes)
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
                    applyThemeStyling(
                        to: mutable,
                        role: role,
                        isItalic: isItalic,
                        tracking: theme.scaledTextStyle(role).tracking
                    )
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

    /// The role's font with emphasis traits layered on, so bold and italic
    /// runs keep the style's family and size.
    private func font(_ role: ThemeTextStyleRole, bold: Bool = false, italic: Bool = false) -> NSFont {
        let key = "\(theme.renderFingerprint)-\(role.rawValue)-\(bold)-\(italic)" as NSString
        if let cached = Self.fontCache.object(forKey: key) {
            return cached
        }
        var font = theme.nsFont(role)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        Self.fontCache.setObject(font, forKey: key)
        return font
    }

    private func applyThemeStyling(
        to attrString: NSMutableAttributedString,
        role: ThemeTextStyleRole,
        isItalic: Bool,
        tracking: Double
    ) {
        let fullRange = NSRange(location: 0, length: attrString.length)

        // Cache colors to avoid repeated conversions
        let primaryTextColor = NSColor(theme.text.primary)
        let accentColor = NSColor(theme.text.link)

        // Apply base text color
        attrString.addAttribute(.foregroundColor, value: primaryTextColor, range: fullRange)
        if tracking != 0 { attrString.addAttribute(.kern, value: tracking, range: fullRange) }

        // Pre-cache common fonts
        let baseIsBold = theme.scaledTextStyle(role).weight >= 600
        let baseFont = font(role, bold: baseIsBold, italic: isItalic)
        let boldFont = font(role, bold: true)
        let boldItalicFont = font(role, bold: true, italic: true)
        let italicFont = font(role, bold: baseIsBold, italic: true)
        let codeFont = font(.code)

        // Enumerate and fix fonts/styles
        attrString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var newFont = baseFont
            // Foundation's markdown parser doesn't always express a code span
            // through the font: nested forms like `**`code`**` can carry the
            // code-ness only in the presentation intent, with a non-monospace
            // font. Check both signals.
            let intent = Self.inlineIntent(attributes)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if let existingFont = attributes[.font] as? NSFont {
                traits = existingFont.fontDescriptor.symbolicTraits
            }

            // Check for inline code
            if traits.contains(.monoSpace) || intent.contains(.code) {
                // Inline code styling (bold-wrapped code keeps its bold)
                let isBoldCode = traits.contains(.bold) || intent.contains(.stronglyEmphasized)
                attrString.addAttribute(.font, value: isBoldCode ? font(.code, bold: true) : codeFont, range: range)
                attrString.addAttribute(.foregroundColor, value: accentColor, range: range)
                #if OSAURUS_DESIGN_SYSTEM
                attrString.addAttribute(.kern, value: theme.assignedTracking(RichTextInspectionStyle.key + "code") ?? 0, range: range)
                attrString.addAttribute(.inspectionMinimumLineHeight, value: theme.assignedLineHeight(RichTextInspectionStyle.key + "code", fallback: CGFloat(theme.lineHeight(.code))), range: range)
                #endif
                // A code span naming a real knowledge document becomes a
                // clickable link to it (existence-gated, so ordinary
                // path-shaped spans are untouched).
                if attributes[.link] == nil {
                    let span = attrString.attributedSubstring(from: range).string
                    if let match = KnowledgeLinkResolver.linkURL(forCodeSpan: span) {
                        let linkRange = NSRange(location: range.location, length: match.matchedLength)
                        attrString.addAttribute(.link, value: match.url, range: linkRange)
                        attrString.addAttribute(
                            .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: linkRange
                        )
                    }
                }
                return
            }

            if attributes[.font] is NSFont {
                // Determine weight and italic from existing font or intent
                let isBold =
                    traits.contains(.bold) || intent.contains(.stronglyEmphasized) || baseIsBold
                let fontIsItalic = traits.contains(.italic) || intent.contains(.emphasized) || isItalic

                // Use pre-cached fonts
                if isBold && fontIsItalic {
                    newFont = boldItalicFont
                } else if isBold {
                    newFont = boldFont
                } else if fontIsItalic {
                    newFont = italicFont
                }
            }

            #if OSAURUS_DESIGN_SYSTEM
            if [.body, .bodySmall].contains(role), intent.contains(.stronglyEmphasized) || (traits.contains(.bold) && !baseIsBold) {
                let key = RichTextInspectionStyle.key + "emphasis"
                newFont = theme.assignedNativeFont(key, fallback: boldFont)
                if intent.contains(.emphasized) || traits.contains(.italic) { newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask) }
                attrString.addAttribute(.kern, value: theme.assignedTracking(key) ?? 0, range: range)
                attrString.addAttribute(.inspectionMinimumLineHeight, value: theme.assignedLineHeight(key, fallback: CGFloat(theme.lineHeight(role))), range: range)
            }
            #endif
            attrString.addAttribute(.font, value: newFont, range: range)

            // Style links
            if attributes[.link] != nil {
                attrString.addAttribute(.foregroundColor, value: accentColor, range: range)
                attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    /// Read the markdown parser's inline presentation intent off a run's
    /// attributes. Bridged NSAttributedStrings carry it as an NSNumber.
    ///
    /// The NSNumber check must come first: a failing
    /// `as? InlinePresentationIntent` cast on an ObjC-bridged value forces a
    /// slow Swift runtime conformance lookup. This runs once per attribute run
    /// on the main thread during `applyThemeStyling`, so the old cast order
    /// caused app hangs on long/streaming messages.
    nonisolated static func inlineIntent(_ attributes: [NSAttributedString.Key: Any]) -> InlinePresentationIntent {
        guard let raw = attributes[.inlinePresentationIntent] else { return [] }
        if let number = raw as? NSNumber {
            return InlinePresentationIntent(rawValue: number.uintValue)
        }
        if let intent = raw as? InlinePresentationIntent {
            return intent
        }
        return []
    }

    // MARK: - Sizing Helpers

    private func headingRole(level: Int) -> ThemeTextStyleRole {
        switch level {
        case 1, 2: return .title
        case 3, 4: return .heading
        default: return .label
        }
    }
}

// MARK: - Custom NSTextView

/// Custom NSTextView that handles link clicks, cursor changes, blockquote bars, and heading underlines.
/// Code blocks are now rendered as standalone `CodeBlockView` / `CodeNSTextView` — no code-block
/// drawing happens here.
final class SelectableNSTextView: NSTextView, CrossSelectableTextView {
    #if OSAURUS_DESIGN_SYSTEM
    private let knowledgeMenuPresenter = AssignedMenuPanelPresenter()
    #endif

    /// Slice of the thread-wide cross-block selection (see ChatCrossSelection).
    /// Painted at the top of `draw(_:)` — drawsBackground is false here, so
    /// AppKit's own background/selection pass never runs.
    var crossSelectionRange: NSRange? {
        didSet {
            guard oldValue != crossSelectionRange else { return }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Context-menu Copy and Edit > Copy prefer the cross-block selection
    /// (see `copyCrossSelectionIfActive`).
    override func copy(_ sender: Any?) {
        if copyCrossSelectionIfActive() { return }
        super.copy(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        crossSelectionEnablesCopy(item) || super.validateUserInterfaceItem(item)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { needsDisplay = true }
        return result
    }

    /// Suppress NSTextView's default scroll-rect-to-visible.
    ///
    /// NSTextView calls `scrollRectToVisible` to keep its caret/selection in
    /// view as the text container lays out (in particular, while a row is
    /// dequeued and configured during the chat scroll-up — the layout pass
    /// happens before the cell's superview hierarchy is in its final
    /// position). The walk to `enclosingScrollView` then yanks the chat's
    /// `clip.y` to this view's origin, which the user perceives as a
    /// multi-row "snap to message top" mid-gesture (verified via NSLog
    /// instrumentation: −616pt single-frame jumps with no preceding
    /// `noteHeightOfRows` or self-mutation, landing exactly at the row's y).
    ///
    /// This view is read-only — the user cannot move the caret with
    /// arrow keys or text input — so the auto-scroll has no UX value here.
    /// Suppressing it eliminates the snap.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSPointInRect(point, bounds) else { return nil }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        // table cells and overlay views sometimes prevent first responder; claim it before link handling
        if window?.firstResponder != self {
            window?.makeFirstResponder(self)
        }
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        if charIndex < textStorage?.length ?? 0,
            let link = textStorage?.attribute(.link, at: charIndex, effectiveRange: nil)
        {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let url {
                if url.scheme == "artifact" {
                    handleArtifactLink(url)
                } else if url.scheme == KnowledgeLinkResolver.scheme {
                    handleKnowledgeLink(url)
                } else {
                    Self.openAsync(url)
                }
                return
            }
        }

        // Single-click drags route to the cross-block selection controller
        // so the highlight can span past this block (each block is its own
        // text view — native tracking can't cross that boundary, #2129).
        // Multi-clicks (word/paragraph select) keep native behavior.
        if event.clickCount == 1 {
            ChatCrossSelection.shared.beginDrag(from: self, with: event)
            return
        }
        ChatCrossSelection.shared.clear()
        super.mouseDown(with: event)
    }

    /// Open the knowledge document a link points at. Falls back to
    /// revealing it in Finder if no app claims the file type.
    private func handleKnowledgeLink(_ url: URL) {
        guard let fileURL = KnowledgeLinkResolver.fileURL(from: url) else {
            // The link resolved at render time but the document is gone now
            // (deleted, collection removed or disabled). A silent no-op on an
            // underlined link reads as a broken app, so say what happened.
            ToastManager.shared.warningLocalized(
                "Document Not Found",
                message: "This knowledge document no longer exists in its collection."
            )
            return
        }
        Self.openAsync(fileURL) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    /// Open a URL without blocking the main thread. The synchronous
    /// `NSWorkspace.open(_:)` waits on a Launch Services round-trip until the
    /// handler app finishes launching, which can hang the UI for seconds
    /// when called from `mouseDown`. The completion-handler variant returns
    /// immediately; `onFailure` (if any) runs on the main queue.
    private static func openAsync(_ url: URL, onFailure: (@MainActor @Sendable () -> Void)? = nil) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil, let onFailure else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onFailure() }
            }
        }
    }

    // MARK: Knowledge link context menu

    /// Right-clicking a knowledge link gets a file-shaped menu (Open, Open
    /// With, Show in Finder, Copy Path) instead of NSTextView's stock text
    /// menu, whose built-in link items would act on the internal
    /// `osaurus-knowledge://` URL and do nothing useful.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        guard charIndex < textStorage?.length ?? 0,
            let link = textStorage?.attribute(.link, at: charIndex, effectiveRange: nil),
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)),
            url.scheme == KnowledgeLinkResolver.scheme,
            let fileURL = KnowledgeLinkResolver.fileURL(from: url)
        else { return super.menu(for: event) }

        let menu = NSMenu()
        // Explicit enabling: with auto-enable, the submenu-only Open With
        // item would not respect the empty-submenu disable below.
        menu.autoenablesItems = false

        let open = NSMenuItem(title: L("Open"), action: #selector(openKnowledgeDocument(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = fileURL
        menu.addItem(open)

        let openWith = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
        let submenu = openWithSubmenu(for: fileURL)
        openWith.submenu = submenu
        openWith.isEnabled = submenu.items.isEmpty == false
        menu.addItem(openWith)

        menu.addItem(.separator())

        let reveal = NSMenuItem(
            title: L("Show in Finder"),
            action: #selector(showKnowledgeDocumentInFinder(_:)),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.representedObject = fileURL
        menu.addItem(reveal)

        let copyPath = NSMenuItem(
            title: L("Copy Path"),
            action: #selector(copyKnowledgeDocumentPath(_:)),
            keyEquivalent: ""
        )
        copyPath.target = self
        copyPath.representedObject = fileURL
        menu.addItem(copyPath)

        #if OSAURUS_DESIGN_SYSTEM
        knowledgeMenuPresenter.showContextMenu(menu, from: self,
            theme: ThemeManager.shared.currentTheme, at: point)
        return nil
        #else
        return menu
        #endif
    }

    /// One item per app that can open the file, default handler first.
    private func openWithSubmenu(for fileURL: URL) -> NSMenu {
        let submenu = NSMenu()
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: fileURL)

        var appURLs = workspace.urlsForApplications(toOpen: fileURL)
        // Dedupe (the same app can be reported at multiple paths) and put
        // the default handler first, matching Finder's Open With menu.
        var seen = Set<String>()
        appURLs = appURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        appURLs.sort {
            $0.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveCompare($1.deletingPathExtension().lastPathComponent)
                == .orderedAscending
        }
        if let defaultApp, let i = appURLs.firstIndex(where: {
            $0.standardizedFileURL.path == defaultApp.standardizedFileURL.path
        }) {
            appURLs.remove(at: i)
            appURLs.insert(defaultApp, at: 0)
        }

        for appURL in appURLs {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: appURL.path),
                action: #selector(openKnowledgeDocumentWith(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = [fileURL, appURL]
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func openKnowledgeDocument(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }
        Self.openAsync(fileURL) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    @objc private func openKnowledgeDocumentWith(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], urls.count == 2 else { return }
        NSWorkspace.shared.open([urls[0]], withApplicationAt: urls[1], configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func showKnowledgeDocumentInFinder(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copyKnowledgeDocumentPath(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }

    private func handleArtifactLink(_ url: URL) {
        let filename = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !filename.isEmpty else { return }

        let artifactsRoot = OsaurusPaths.artifactsDir()
        let fm = FileManager.default
        guard
            let contextDirs = try? fm.contentsOfDirectory(
                at: artifactsRoot,
                includingPropertiesForKeys: nil
            )
        else { return }

        for dir in contextDirs {
            let candidate = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.activateFileViewerSelecting([candidate])
                return
            }
        }
    }

    /// Theme colors for custom drawing (set by SelectableTextView on update).
    /// `accentColor` carries `text.link`; `blockquoteBarColor` is `border.strong`.
    var accentColor: NSColor = .linkColor
    var blockquoteBarColor: NSColor = .separatorColor
    var secondaryBackgroundColor: NSColor = .clear
    var inspectedQuoteWidth: CGFloat = 3
    var inspectedQuoteRadius: CGFloat = 1.5

    /// Closure invoked on every `mouseMoved` (when the text view is
    /// the owner of an `NSTrackingArea` with `.mouseMoved`). Used by
    /// `RedactionHoverController` to drive its popover without
    /// duplicating tracking-area management. Cleared by the
    /// controller's `detach()` so streaming chat with no privacy
    /// hits doesn't pay for an idle dispatch on every cursor wiggle.
    var onMouseHover: ((NSEvent) -> Void)?
    /// Closure invoked on `mouseExited`. Drives the controller's
    /// 80ms hide debounce.
    var onMouseExitedHover: (() -> Void)?

    /// Whether the redaction-hover `.mouseMoved` tracking area should be
    /// installed. Toggled by `RedactionHoverController`. The area itself is
    /// created/destroyed inside `updateTrackingAreas()` with `owner: self`,
    /// so AppKit manages its lifecycle and it is torn down with the view —
    /// it can never be left dangling for the tracking-area manager to
    /// dispatch `mouseMoved:` into a freed owner (the
    /// `-[_NSTrackingAreaAKManager mouseMoved:]` launch SIGABRT, issue
    /// #1632). The pre-fix code added the area imperatively from the
    /// controller without reconciling it in `updateTrackingAreas()`, so a
    /// view moved between windows (prewarm) or torn down via a cell path
    /// that skipped `detach()` could leave a stale area behind.
    var wantsRedactionHoverTracking: Bool = false {
        didSet {
            guard oldValue != wantsRedactionHoverTracking else { return }
            if wantsRedactionHoverTracking { window?.acceptsMouseMovedEvents = true }
            updateTrackingAreas()
        }
    }

    /// Our owned hover tracking area. Reconciled on every
    /// `updateTrackingAreas()` pass; nil when hover tracking is disabled.
    private var redactionHoverTrackingArea: NSTrackingArea?

    /// Drives the I-beam/pointing-hand cursor. Legacy cursor rects don't
    /// survive layer-backed table-cell recycling, so the cursor comes from
    /// a `.cursorUpdate` tracking area (see `chatTextCursorUpdate`).
    private var cursorTrackingArea: NSTrackingArea?

    override func cursorUpdate(with event: NSEvent) {
        chatTextCursorUpdate(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let cursorArea = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(cursorArea)
        cursorTrackingArea = cursorArea
        // Reconcile only the area we own (tracked by reference). NSTextView
        // manages its own areas — for the I-beam cursor etc. — via
        // `super`, and we must not disturb those. Remove-then-add against
        // the current bounds so the area always matches the live geometry.
        if let existing = redactionHoverTrackingArea {
            removeTrackingArea(existing)
            redactionHoverTrackingArea = nil
        }
        guard wantsRedactionHoverTracking else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        redactionHoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseHover?(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseHover?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExitedHover?()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCrossSelectionHighlight()
        guard let layoutManager = layoutManager,
            let textContainer = textContainer,
            let textStorage = textStorage
        else {
            super.draw(dirtyRect)
            return
        }

        // Only walk the characters that fall inside `dirtyRect`. Enumerating
        // the whole document forced `boundingRect(forGlyphRange:)` — and thus
        // full-document typesetting — on every draw pass, even a one-line
        // partial redraw. Restricting to the visible glyph range keeps the
        // per-draw layout cost proportional to what's actually being painted.
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
        let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleRange.length > 0 else {
            super.draw(dirtyRect)
            return
        }

        // Draw blockquote accent bars
        textStorage.enumerateAttribute(.blockquoteMarker, in: visibleRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: gr, in: textContainer)
            rect.origin.x = 0; rect.size.width = bounds.width

            guard rect.intersects(dirtyRect) else { return }

            // The minimum line height adds its leading above the glyphs; start
            // the bar at the glyphs so it brackets the text evenly.
            if let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            {
                let natural = ceil(font.ascender - font.descender + font.leading)
                let leading = min(max(0, style.minimumLineHeight - natural), rect.height / 2)
                rect.origin.y += leading
                rect.size.height -= leading
            }

            // Bar only: a filled panel reads as a second surface on top of
            // the assistant reply surface.
            blockquoteBarColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 4, y: rect.origin.y, width: inspectedQuoteWidth, height: rect.height),
                xRadius: inspectedQuoteRadius,
                yRadius: inspectedQuoteRadius
            ).fill()
        }

        // Draw heading underlines (H1/H2)
        textStorage.enumerateAttribute(.headingUnderline, in: visibleRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: gr, in: textContainer)
            let lineRect = NSRect(x: 0, y: rect.maxY + 4, width: bounds.width, height: inspectedQuoteWidth)

            guard lineRect.intersects(dirtyRect) else { return }

            blockquoteBarColor.setFill()
            lineRect.fill()
        }

        super.draw(dirtyRect)
    }
}
