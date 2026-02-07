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
        // Store previous state directly for O(1) comparison instead of O(n) hashing
        var lastBlocks: [SelectableTextBlock] = []
        var lastWidth: CGFloat = 0
        var lastThemeFingerprint: String = ""
        var lastMeasuredHeight: CGFloat = 0
        var cacheKey: String? = nil

        // Track length of each block's rendered text (including trailing newline if present)
        // This enables O(1) incremental updates by only modifying changed blocks
        var blockLengths: [Int] = []

        // Track code block ranges for overlay rendering (copy buttons)
        var codeBlockInfos: [SelectableNSTextView.CodeBlockInfo] = []

        /// External overlay data provided by the wrapper view
        weak var overlayData: CodeBlockOverlayData?

        /// Once set, disables ThreadCache (Tier 2) lookups for the rest of this
        /// coordinator's lifetime. Only fresh coordinators (recycled views) benefit
        /// from Tier 2 to avoid expensive ensureLayout on large messages.
        var contentChangedSinceInit: Bool = false

        init(cacheKey: String? = nil) {
            self.cacheKey = cacheKey
        }

        /// Update overlay items from the current code block infos and text view layout.
        /// Deferred to the next run loop iteration to avoid publishing changes during
        /// SwiftUI's view update cycle (which causes undefined behavior warnings).
        @MainActor
        func updateOverlayRects(textView: SelectableNSTextView) {
            guard let overlayData = overlayData else { return }
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                DispatchQueue.main.async {
                    overlayData.items = []
                }
                return
            }

            var items: [CodeBlockOverlayData.OverlayItem] = []
            for (index, info) in codeBlockInfos.enumerated() {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: info.range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                // Expand to full width for the code block background
                rect.origin.x = 0
                rect.size.width = textView.bounds.width

                items.append(
                    CodeBlockOverlayData.OverlayItem(
                        id: index,
                        code: info.code,
                        language: info.language,
                        rect: rect
                    )
                )
            }
            DispatchQueue.main.async {
                overlayData.items = items
            }
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

        // Fast path: Direct comparison instead of expensive O(n) hashing every update
        // Swift's Equatable for arrays uses optimized comparison that short-circuits early
        let themeFingerprint = makeThemeFingerprint()
        let widthChanged = abs(context.coordinator.lastWidth - baseWidth) > 0.1
        let themeChanged = context.coordinator.lastThemeFingerprint != themeFingerprint
        let blocksChanged = context.coordinator.lastBlocks != blocks

        if blocksChanged || widthChanged || themeChanged {
            // Incremental update optimization
            if !widthChanged && !themeChanged && context.coordinator.lastBlocks.count > 0 {
                updateTextStorageIncrementally(
                    textView: textView,
                    oldBlocks: context.coordinator.lastBlocks,
                    newBlocks: blocks,
                    coordinator: context.coordinator
                )
            } else {
                // Full rebuild
                let attributedString = buildAttributedString(coordinator: context.coordinator)
                textView.textStorage?.setAttributedString(attributedString)
            }

            // Mark content as changed (disables Tier 2 ThreadCache lookups to prevent
            // stale heights during streaming). Only set for non-initial loads since
            // fresh coordinators (recycled views) should use ThreadCache.
            if (blocksChanged || themeChanged) && !context.coordinator.lastBlocks.isEmpty {
                context.coordinator.contentChangedSinceInit = true
            }

            // Reset coordinator height so sizeThatFits re-measures
            context.coordinator.lastMeasuredHeight = 0

            // Update coordinator state
            context.coordinator.lastBlocks = blocks
            context.coordinator.lastWidth = baseWidth
            context.coordinator.lastThemeFingerprint = themeFingerprint

            // Pass code block info to the text view for background drawing
            textView.codeBlockInfos = context.coordinator.codeBlockInfos
            textView.needsDisplay = true

            // Update overlay rects for copy buttons
            context.coordinator.updateOverlayRects(textView: textView)
        }
    }

    // MARK: - Sizing

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? baseWidth

        // Tier 1: coordinator cache (same width, height already measured this cycle)
        if context.coordinator.lastMeasuredHeight > 0
            && abs(context.coordinator.lastWidth - width) < 0.5
        {
            return CGSize(width: width, height: context.coordinator.lastMeasuredHeight)
        }

        // Tier 2: ThreadCache with width-aware key (survives view recycling).
        // Skipped when content has changed since coordinator creation to prevent
        // returning stale heights from a previous width during streaming.
        if !context.coordinator.contentChangedSinceInit, let key = cacheKey {
            let widthKey = "\(key)-w\(Int(width))"
            if let cached = ThreadCache.shared.height(for: widthKey) {
                context.coordinator.lastWidth = width
                context.coordinator.lastMeasuredHeight = cached
                return CGSize(width: width, height: cached)
            }
        }

        // Tier 3: full layout measurement
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let textContainer = nsView.textContainer,
            let layoutManager = nsView.layoutManager
        else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let measured = ceil(usedRect.height) + 4  // small buffer to prevent clipping

        context.coordinator.lastWidth = width
        context.coordinator.lastMeasuredHeight = measured

        // Update overlay rects now that layout is complete
        context.coordinator.updateOverlayRects(textView: nsView)

        // Cache for future view recycling (width-aware key)
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

        // Find the first index where blocks differ
        var diffIndex = 0
        let commonCount = min(oldBlocks.count, newBlocks.count)

        while diffIndex < commonCount {
            if oldBlocks[diffIndex] != newBlocks[diffIndex] {
                break
            }
            diffIndex += 1
        }

        // If diffIndex is 0, we have to rebuild everything (no common prefix)
        // But we can still use the loop structure below

        // Calculate the safe prefix length using cached block lengths
        var prefixLength = 0
        if diffIndex > 0 {
            // Ensure blockLengths matches oldBlocks
            if coordinator.blockLengths.count >= diffIndex {
                prefixLength = coordinator.blockLengths.prefix(diffIndex).reduce(0, +)
            } else {
                // Fallback: cached lengths out of sync, force full rebuild
                diffIndex = 0
                prefixLength = 0
            }
        }

        // Safety check: ensure prefix length is within bounds
        if prefixLength > storage.length {
            diffIndex = 0
            prefixLength = 0
        }

        // 1. Delete modified/removed content
        let rangeToDelete = NSRange(location: prefixLength, length: storage.length - prefixLength)
        if rangeToDelete.length > 0 {
            storage.deleteCharacters(in: rangeToDelete)
        }

        // 2. Prepare to append new content
        // Update cached lengths: keep valid prefix
        var newLengths = Array(coordinator.blockLengths.prefix(diffIndex))

        // 3. Handle boundary condition: if we are appending to a previously "last" block,
        // it needs a newline added because it's no longer last.
        // The block content itself (at diffIndex-1) didn't change (it's in common prefix),
        // but its rendering context changed (needs \n).
        if diffIndex > 0 && diffIndex == oldBlocks.count && diffIndex < newBlocks.count {
            // Append newline to the now-intermediate block
            let newline = NSAttributedString(string: "\n")
            storage.append(newline)

            // Update length of the previous block to include the newline
            if diffIndex - 1 < newLengths.count {
                newLengths[diffIndex - 1] += 1
            }
        }

        // 4. Render and append new blocks
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale

        for i in diffIndex ..< newBlocks.count {
            let block = newBlocks[i]
            let isFirst = i == 0
            let previousBlock = isFirst ? nil : newBlocks[i - 1]

            // Render block
            let attrString = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: previousBlock,
                bodyFontSize: bodyFontSize,
                scale: scale
            )

            storage.append(attrString)
            var blockLen = attrString.length

            // Append newline if not last
            if i < newBlocks.count - 1 {
                storage.append(NSAttributedString(string: "\n"))
                blockLen += 1
            }

            newLengths.append(blockLen)
        }

        // Update cache
        coordinator.blockLengths = newLengths

        // Rebuild code block infos from scratch (ranges may have shifted)
        rebuildCodeBlockInfos(blocks: newBlocks, lengths: newLengths, coordinator: coordinator)
    }

    /// Rebuild code block range info from block lengths
    private func rebuildCodeBlockInfos(
        blocks: [SelectableTextBlock],
        lengths: [Int],
        coordinator: Coordinator
    ) {
        var codeInfos: [SelectableNSTextView.CodeBlockInfo] = []
        var offset = 0
        for (i, block) in blocks.enumerated() {
            let blockContentLength = i < lengths.count ? lengths[i] : 0
            // Subtract trailing newline from the content range
            let hasTrailingNewline = i < blocks.count - 1
            let contentLen = hasTrailingNewline ? max(0, blockContentLength - 1) : blockContentLength

            if case .codeBlock(let code, let language) = block {
                codeInfos.append(
                    SelectableNSTextView.CodeBlockInfo(
                        code: code,
                        language: language,
                        range: NSRange(location: offset, length: contentLen)
                    )
                )
            }
            offset += blockContentLength
        }
        coordinator.codeBlockInfos = codeInfos
    }

    // MARK: - Attributed String Building

    private func buildAttributedString(coordinator: Coordinator) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale
        var lengths: [Int] = []
        var codeInfos: [SelectableNSTextView.CodeBlockInfo] = []

        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0
            let previousBlock = isFirst ? nil : blocks[index - 1]

            let currentOffset = result.length

            let attrString = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: previousBlock,
                bodyFontSize: bodyFontSize,
                scale: scale
            )
            result.append(attrString)

            // Track code block ranges
            if case .codeBlock(let code, let language) = block {
                codeInfos.append(
                    SelectableNSTextView.CodeBlockInfo(
                        code: code,
                        language: language,
                        range: NSRange(location: currentOffset, length: attrString.length)
                    )
                )
            }

            var blockLen = attrString.length

            // Add newline between blocks (except after the last one)
            if index < blocks.count - 1 {
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

        case .codeBlock(let code, _):
            let codeAttr = NSMutableAttributedString(
                string: code,
                attributes: [
                    .font: cachedMonoFont(size: bodyFontSize * 0.85, weight: .regular),
                    .foregroundColor: NSColor(theme.primaryText.opacity(0.95)),
                    .backgroundColor: NSColor(theme.codeBlockBackground),
                ]
            )
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacingBefore = isFirst ? 8 : spacing
            style.paragraphSpacing = 8
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
            codeAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: codeAttr.length))
            return codeAttr

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

    /// Thread-local font cache to avoid repeated font creation
    private static var fontCache: [String: NSFont] = [:]

    private func cachedFont(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let key = "\(theme.primaryFontName)-\(size)-\(weight.rawValue)-\(italic)"
        if let cached = Self.fontCache[key] {
            return cached
        }
        let font = nsFont(size: size, weight: weight, italic: italic)
        Self.fontCache[key] = font
        return font
    }

    private func cachedMonoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = "mono-\(theme.monoFontName)-\(size)-\(weight.rawValue)"
        if let cached = Self.fontCache[key] {
            return cached
        }
        let font = nsMonoFont(size: size, weight: weight)
        Self.fontCache[key] = font
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

    /// Lightweight fingerprint for theme changes (computed rarely, only when theme changes)
    /// Uses string-based key instead of expensive color conversions
    private func makeThemeFingerprint() -> String {
        // Simple concatenation of theme properties that affect rendering
        // This is much cheaper than hashing colors via NSColor conversion
        return
            "\(theme.primaryFontName)|\(theme.monoFontName)|\(theme.titleSize)|\(theme.headingSize)|\(theme.bodySize)|\(theme.captionSize)|\(theme.codeSize)"
    }
}

// MARK: - Selectable Text View with Code Block Overlays

/// Wraps `SelectableTextView` with copy button overlays for inline code blocks
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
            codeBlockOverlays
        }
    }

    @ViewBuilder
    private var codeBlockOverlays: some View {
        ForEach(overlayData.items) { item in
            CodeBlockCopyOverlay(
                code: item.code,
                language: item.language,
                isHovered: hoveredCodeBlock == item.id,
                theme: theme
            )
            .frame(width: item.rect.width, height: 30)  // Only cover top strip for hover/button
            .offset(x: item.rect.origin.x, y: item.rect.origin.y)
            .onHover { hovering in
                hoveredCodeBlock = hovering ? item.id : nil
            }
        }
    }
}

/// Copy button overlay for a single code block
private struct CodeBlockCopyOverlay: View {
    let code: String
    let language: String?
    let isHovered: Bool
    let theme: ThemeProtocol

    @State private var copied = false

    private var languageIcon: String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "python", "py": return "chevron.left.forwardslash.chevron.right"
        case "javascript", "js", "typescript", "ts": return "curlybraces"
        case "json": return "doc.text"
        case "bash", "sh", "shell", "zsh": return "terminal"
        case "html", "xml": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "sass": return "paintbrush"
        case "sql": return "cylinder"
        case "rust", "go", "java", "kotlin", "c", "cpp", "c++": return "chevron.left.forwardslash.chevron.right"
        case "markdown", "md": return "doc.richtext"
        default: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: languageIcon)
                        .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    Text(language.lowercased())
                        .font(theme.monoFont(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground.opacity(0.5))
                )
                .opacity(isHovered || copied ? 1 : 0)
            }

            Spacer()

            Button(action: copyCode) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    if copied {
                        Text("Copied!")
                            .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    }
                }
                .foregroundColor(copied ? theme.successColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(copied ? theme.successColor.opacity(0.15) : theme.tertiaryBackground.opacity(0.6))
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .contentShape(Rectangle())
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                copied = false
            }
        }
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
    }

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

        // Draw blockquote accent bars and subtle background
        textStorage.enumerateAttribute(.blockquoteMarker, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = bounds.width

            // Subtle background
            let bgRect = NSRect(x: 4, y: rect.origin.y - 2, width: rect.width - 8, height: rect.height + 4)
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
            secondaryBackgroundColor.withAlphaComponent(0.3).setFill()
            bgPath.fill()

            // Vertical accent bar
            let barRect = NSRect(x: 6, y: rect.origin.y - 2, width: 3, height: rect.height + 4)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            blockquoteBarColor.setFill()
            barPath.fill()
        }

        // Draw heading underlines for H1/H2
        textStorage.enumerateAttribute(.headingUnderline, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            // Draw a subtle gradient underline below the heading
            let lineY = rect.origin.y + rect.height + 4
            let lineRect = NSRect(x: 0, y: lineY, width: bounds.width, height: 1)

            if let gradient = NSGradient(
                colors: [
                    accentColor.withAlphaComponent(0.3),
                    accentColor.withAlphaComponent(0.05),
                ]
            ) {
                gradient.draw(in: lineRect, angle: 0)
            }
        }

        super.draw(dirtyRect)
    }
}
