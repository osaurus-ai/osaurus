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
}

// MARK: - Text Block for Rendering

/// Represents a text block to be rendered in NSTextView
enum SelectableTextBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case blockquote(String)
    case listItem(text: String, index: Int, ordered: Bool, indentLevel: Int)
}

// MARK: - Selectable Text View

struct SelectableTextView: NSViewRepresentable {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    let theme: ThemeProtocol
    /// Optional cache key (turn ID) for persisting measured height across view recycling
    var cacheKey: String? = nil

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

        init(cacheKey: String? = nil) {
            self.cacheKey = cacheKey
            // Initialize from cache if available
            if let key = cacheKey, let cachedHeight = MessageHeightCache.shared.height(for: key) {
                self.lastMeasuredHeight = cachedHeight
            }
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

        // Initialize preferred size from cache if available (prevents LazyVStack height estimation issues)
        if context.coordinator.lastMeasuredHeight > 0 {
            textView.updatePreferredSize(width: baseWidth, height: context.coordinator.lastMeasuredHeight)
        }

        return textView
    }

    func updateNSView(_ textView: SelectableNSTextView, context: Context) {
        // Update container width
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)

        // Update selection color for theme changes
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]

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

            // Force layout once (single pass). SwiftUI sizing uses intrinsicContentSize.
            if let textContainer = textView.textContainer,
                let layoutManager = textView.layoutManager
            {
                layoutManager.ensureLayout(for: textContainer)
                let usedRect = layoutManager.usedRect(for: textContainer)
                let measured = ceil(usedRect.height) + 4  // small buffer to prevent clipping
                context.coordinator.lastMeasuredHeight = measured
                textView.updatePreferredSize(width: baseWidth, height: measured)

                // Cache the measured height for future view recycling
                if let key = cacheKey {
                    MessageHeightCache.shared.setHeight(measured, for: key)
                }
            } else {
                textView.updatePreferredSize(width: baseWidth, height: context.coordinator.lastMeasuredHeight)
            }

            // Update coordinator state
            context.coordinator.lastBlocks = blocks
            context.coordinator.lastWidth = baseWidth
            context.coordinator.lastThemeFingerprint = themeFingerprint
        } else {
            // Fast path: keep intrinsic sizing stable without re-layout.
            textView.updatePreferredSize(width: baseWidth, height: context.coordinator.lastMeasuredHeight)
        }
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
    }

    // MARK: - Attributed String Building

    private func buildAttributedString(coordinator: Coordinator? = nil) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale
        var lengths: [Int] = []

        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0
            let previousBlock = isFirst ? nil : blocks[index - 1]

            let attrString = renderBlock(
                block,
                isFirst: isFirst,
                previousBlock: previousBlock,
                bodyFontSize: bodyFontSize,
                scale: scale
            )
            result.append(attrString)

            var blockLen = attrString.length

            // Add newline between blocks (except after the last one)
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n"))
                blockLen += 1
            }

            lengths.append(blockLen)
        }

        if let coord = coordinator {
            coord.blockLengths = lengths
        }

        return result
    }

    private func renderBlock(
        _ block: SelectableTextBlock,
        isFirst: Bool,
        previousBlock: SelectableTextBlock?,
        bodyFontSize: CGFloat,
        scale: CGFloat
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()

        switch block {
        case .paragraph(let text):
            let attrString = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular)
            applyParagraphStyle(
                to: attrString,
                lineSpacing: LineSpacing.paragraph,
                spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock)
            )
            result.append(attrString)

        case .heading(let level, let text):
            let fontSize = headingSize(level: level, scale: scale)
            let weight = level <= 2 ? NSFont.Weight.bold : .semibold
            let attrString = renderInlineMarkdown(text, fontSize: fontSize, weight: weight)
            applyParagraphStyle(
                to: attrString,
                lineSpacing: LineSpacing.heading,
                spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock)
            )
            result.append(attrString)

        case .blockquote(let text):
            let attrString = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular, isItalic: true)
            // Apply secondary text color for blockquotes
            attrString.addAttribute(
                .foregroundColor,
                value: NSColor(theme.secondaryText),
                range: NSRange(location: 0, length: attrString.length)
            )
            applyParagraphStyle(
                to: attrString,
                lineSpacing: LineSpacing.blockquote,
                spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock),
                leftIndent: 16
            )
            result.append(attrString)

        case .listItem(let text, let itemIndex, let ordered, let indentLevel):
            let bulletWidth: CGFloat = ordered ? 28 : 20
            let bullet: String
            if ordered {
                bullet = "\(itemIndex + 1)."
            } else {
                bullet = "•"
            }

            // Create the full line with bullet + text
            let fullLine = NSMutableAttributedString()

            // Create bullet with accent color
            let bulletAttr = NSMutableAttributedString(
                string: bullet,
                attributes: [
                    .font: nsFont(size: bodyFontSize, weight: .medium),
                    .foregroundColor: NSColor(theme.accentColor),
                ]
            )
            fullLine.append(bulletAttr)

            // Add tab character
            fullLine.append(NSAttributedString(string: "\t"))

            // Create item text
            let itemAttr = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular)
            fullLine.append(itemAttr)

            // Apply paragraph style with hanging indent, accounting for nesting level
            applyListParagraphStyle(
                to: fullLine,
                lineSpacing: LineSpacing.listItem,
                spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock),
                bulletWidth: bulletWidth,
                indentLevel: indentLevel
            )
            result.append(fullLine)
        }

        return result
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
        guard let prev = previousBlock else { return 0 }

        switch block {
        case .heading(let level, _):
            if case .heading = prev {
                return BlockSpacing.headingAfterHeading
            }
            return level <= 2 ? BlockSpacing.headingH1H2AfterOther : BlockSpacing.headingH3PlusAfterOther

        case .blockquote:
            if case .blockquote = prev {
                return BlockSpacing.blockquoteAfterBlockquote
            }
            return BlockSpacing.blockquoteAfterOther

        case .listItem:
            if case .listItem = prev {
                return BlockSpacing.listItemAfterListItem
            }
            return BlockSpacing.listItemAfterOther

        case .paragraph:
            return BlockSpacing.paragraphAfterOther
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

// MARK: - Custom NSTextView

/// Custom NSTextView that handles link clicks and cursor changes
final class SelectableNSTextView: NSTextView {
    private var preferredIntrinsicWidth: CGFloat = 0
    private var preferredIntrinsicHeight: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        let width = preferredIntrinsicWidth > 0 ? preferredIntrinsicWidth : super.intrinsicContentSize.width
        let height = preferredIntrinsicHeight > 0 ? preferredIntrinsicHeight : super.intrinsicContentSize.height
        return NSSize(width: width, height: height)
    }

    func updatePreferredSize(width: CGFloat, height: CGFloat) {
        let w = max(1, width)
        let h = max(1, height)
        guard w != preferredIntrinsicWidth || h != preferredIntrinsicHeight else { return }
        preferredIntrinsicWidth = w
        preferredIntrinsicHeight = h
        invalidateIntrinsicContentSize()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        // Check for link at click location
        if charIndex < textStorage?.length ?? 0,
            let link = textStorage?.attribute(.link, at: charIndex, effectiveRange: nil)
        {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return
            } else if let urlString = link as? String, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        super.mouseDown(with: event)
    }
}

// MARK: - SwiftUI Sizing

struct SelectableTextViewSizer: View {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    /// Optional cache key (turn ID) for persisting measured height across view recycling
    let cacheKey: String?

    @Environment(\.theme) private var theme
    @State private var height: CGFloat

    init(blocks: [SelectableTextBlock], baseWidth: CGFloat, cacheKey: String? = nil) {
        self.blocks = blocks
        self.baseWidth = baseWidth
        self.cacheKey = cacheKey

        // Initialize height from cache if available, otherwise start at 0
        if let key = cacheKey, let cachedHeight = MessageHeightCache.shared.height(for: key) {
            _height = State(initialValue: cachedHeight)
        } else {
            _height = State(initialValue: 0)
        }
    }

    var body: some View {
        SelectableTextView(blocks: blocks, baseWidth: baseWidth, theme: theme)
            .frame(width: baseWidth, height: max(20, height), alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TextHeightPreferenceKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(TextHeightPreferenceKey.self) { newHeight in
                if newHeight > 0 && newHeight != height {
                    height = newHeight
                    // Cache the measured height for future view recycling
                    if let key = cacheKey {
                        MessageHeightCache.shared.setHeight(newHeight, for: key)
                    }
                }
            }
    }
}

private struct TextHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Height Calculator

extension SelectableTextView {
    /// Calculate the height needed for the text blocks
    static func calculateHeight(
        blocks: [SelectableTextBlock],
        baseWidth: CGFloat,
        theme: ThemeProtocol
    ) -> CGFloat {
        let view = SelectableTextView(blocks: blocks, baseWidth: baseWidth, theme: theme)
        let attrString = view.buildAttributedString()

        // Create a temporary text container to measure
        let textStorage = NSTextStorage(attributedString: attrString)
        let textContainer = NSTextContainer(size: NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()

        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // Add small buffer to prevent clipping
        return ceil(usedRect.height) + 4
    }
}
