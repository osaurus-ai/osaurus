//
//  SelectableTextView.swift
//  osaurus
//
//  NSTextView wrapper for web-like text selection across markdown blocks
//

import AppKit
import SwiftUI

// MARK: - Text Block for Rendering

/// Represents a text block to be rendered in NSTextView
enum SelectableTextBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case blockquote(String)
    case listItem(text: String, index: Int, ordered: Bool)
}

// MARK: - Selectable Text View

struct SelectableTextView: NSViewRepresentable {
    let blocks: [SelectableTextBlock]
    let baseWidth: CGFloat
    let theme: ThemeProtocol

    final class Coordinator {
        var lastKey: Int?
        var lastMeasuredHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        return textView
    }

    func updateNSView(_ textView: SelectableNSTextView, context: Context) {
        // Update container width
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: CGFloat.greatestFiniteMagnitude)

        // Update selection color for theme changes
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]

        // Cache key: blocks + theme + width. Avoid rebuilding attributed strings (and relayout) when unchanged.
        let key = makeCacheKey()
        if context.coordinator.lastKey != key {
            let attributedString = buildAttributedString()
            textView.textStorage?.setAttributedString(attributedString)

            // Force layout once (single pass). SwiftUI sizing uses intrinsicContentSize.
            if let textContainer = textView.textContainer,
                let layoutManager = textView.layoutManager
            {
                layoutManager.ensureLayout(for: textContainer)
                let usedRect = layoutManager.usedRect(for: textContainer)
                let measured = ceil(usedRect.height) + 4  // small buffer to prevent clipping
                context.coordinator.lastMeasuredHeight = measured
                textView.updatePreferredSize(width: baseWidth, height: measured)
            } else {
                textView.updatePreferredSize(width: baseWidth, height: context.coordinator.lastMeasuredHeight)
            }
            context.coordinator.lastKey = key
        } else {
            // Fast path: keep intrinsic sizing stable without re-layout.
            textView.updatePreferredSize(width: baseWidth, height: context.coordinator.lastMeasuredHeight)
        }
    }

    // MARK: - Attributed String Building

    private func buildAttributedString() -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let scale = Typography.scale(for: baseWidth)
        let bodyFontSize = CGFloat(theme.bodySize) * scale

        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0
            let previousBlock = isFirst ? nil : blocks[index - 1]

            switch block {
            case .paragraph(let text):
                let attrString = renderInlineMarkdown(text, fontSize: bodyFontSize, weight: .regular)
                applyParagraphStyle(
                    to: attrString,
                    lineSpacing: 5,
                    spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock)
                )
                result.append(attrString)

            case .heading(let level, let text):
                let fontSize = headingSize(level: level, scale: scale)
                let weight = level <= 2 ? NSFont.Weight.bold : .semibold
                let attrString = renderInlineMarkdown(text, fontSize: fontSize, weight: weight)
                applyParagraphStyle(
                    to: attrString,
                    lineSpacing: 2,
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
                    lineSpacing: 4,
                    spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock),
                    leftIndent: 16
                )
                result.append(attrString)

            case .listItem(let text, let itemIndex, let ordered):
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

                // Apply paragraph style with hanging indent
                applyListParagraphStyle(
                    to: fullLine,
                    lineSpacing: 4,
                    spacingBefore: isFirst ? 0 : spacingBefore(block: block, previousBlock: previousBlock),
                    bulletWidth: bulletWidth
                )
                result.append(fullLine)
            }

            // Add newline between blocks (except after the last one)
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
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
        bulletWidth: CGFloat
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = spacingBefore

        // Hanging indent: bullet at left margin, text indented
        let indent: CGFloat = 24  // Left margin for the whole list
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent + bulletWidth  // Wrap text aligns with first line text

        // Tab stop for text after bullet
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: indent + bulletWidth, options: [:])
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
                return 8
            }
            return level <= 2 ? 20 : 16

        case .blockquote:
            if case .blockquote = prev {
                return 4
            }
            return 12

        case .listItem:
            if case .listItem = prev {
                return 6
            }
            return 10

        case .paragraph:
            return 12
        }
    }

    // MARK: - Inline Markdown Rendering

    private func renderInlineMarkdown(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        isItalic: Bool = false
    ) -> NSMutableAttributedString {
        // Base attributes
        let baseFont = nsFont(size: fontSize, weight: weight, italic: isItalic)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor(theme.primaryText),
        ]

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

    private func applyThemeStyling(
        to attrString: NSMutableAttributedString,
        baseFontSize: CGFloat,
        baseWeight: NSFont.Weight,
        isItalic: Bool
    ) {
        let fullRange = NSRange(location: 0, length: attrString.length)

        // Apply base text color
        attrString.addAttribute(.foregroundColor, value: NSColor(theme.primaryText), range: fullRange)

        // Enumerate and fix fonts/styles
        attrString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var newFont = nsFont(size: baseFontSize, weight: baseWeight, italic: isItalic)

            if let existingFont = attributes[.font] as? NSFont {
                let traits = existingFont.fontDescriptor.symbolicTraits

                // Determine weight and italic from existing font
                let isBold = traits.contains(.bold) || baseWeight == .bold || baseWeight == .semibold
                let fontIsItalic = traits.contains(.italic) || isItalic

                // Check for inline code (usually monospace)
                if existingFont.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                    // Inline code styling
                    let codeFont = nsMonoFont(size: baseFontSize * 0.9, weight: .regular)
                    attrString.addAttribute(.font, value: codeFont, range: range)
                    attrString.addAttribute(.foregroundColor, value: NSColor(theme.accentColor), range: range)
                    return
                }

                // Reconstruct font with proper weight/italic
                if isBold && fontIsItalic {
                    newFont = nsFont(size: baseFontSize, weight: .bold, italic: true)
                } else if isBold {
                    newFont = nsFont(size: baseFontSize, weight: .bold, italic: false)
                } else if fontIsItalic {
                    newFont = nsFont(size: baseFontSize, weight: baseWeight, italic: true)
                }
            }

            attrString.addAttribute(.font, value: newFont, range: range)

            // Style links
            if attributes[.link] != nil {
                attrString.addAttribute(.foregroundColor, value: NSColor(theme.accentColor), range: range)
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

    // MARK: - Cache Key

    private func makeCacheKey() -> Int {
        var hasher = Hasher()
        // Width affects Typography.scale(for:) and layout
        hasher.combine(Int((baseWidth * 10).rounded()))  // 0.1pt precision
        hashBlocks(into: &hasher)
        hashTheme(into: &hasher)
        return hasher.finalize()
    }

    private func hashBlocks(into hasher: inout Hasher) {
        hasher.combine(blocks.count)
        for b in blocks {
            switch b {
            case .paragraph(let s):
                hasher.combine(0)
                hasher.combine(s)
            case .heading(let level, let text):
                hasher.combine(1)
                hasher.combine(level)
                hasher.combine(text)
            case .blockquote(let s):
                hasher.combine(2)
                hasher.combine(s)
            case .listItem(let text, let index, let ordered):
                hasher.combine(3)
                hasher.combine(text)
                hasher.combine(index)
                hasher.combine(ordered)
            }
        }
    }

    private func hashTheme(into hasher: inout Hasher) {
        hasher.combine(theme.primaryFontName)
        hasher.combine(theme.monoFontName)
        hasher.combine(theme.titleSize)
        hasher.combine(theme.headingSize)
        hasher.combine(theme.bodySize)
        hasher.combine(theme.captionSize)
        hasher.combine(theme.codeSize)
        hashColor(theme.primaryText, into: &hasher)
        hashColor(theme.secondaryText, into: &hasher)
        hashColor(theme.accentColor, into: &hasher)
        hashColor(theme.selectionColor, into: &hasher)
    }

    private func hashColor(_ color: Color, into hasher: inout Hasher) {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else {
            hasher.combine(ns.description)
            return
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        hasher.combine(Int((r * 255).rounded()))
        hasher.combine(Int((g * 255).rounded()))
        hasher.combine(Int((b * 255).rounded()))
        hasher.combine(Int((a * 255).rounded()))
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

    @Environment(\.theme) private var theme
    @State private var height: CGFloat = 0

    var body: some View {
        SelectableTextView(blocks: blocks, baseWidth: baseWidth, theme: theme)
            .frame(width: baseWidth, height: max(20, height), alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TextHeightPreferenceKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(TextHeightPreferenceKey.self) { newHeight in
                if newHeight > 0 {
                    height = newHeight
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
