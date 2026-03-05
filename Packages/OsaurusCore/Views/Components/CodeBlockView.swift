//
//  CodeBlockView.swift
//  osaurus
//
//  Standalone SwiftUI view for rendering fenced code blocks.
//  Background, header bar (language + copy), and code content are all
//  SwiftUI-owned — no cross-layer synchronization with AppKit overlays.
//  Line numbers are drawn inside the code NSTextView's draw() so they
//  share the same coordinate system and timing as the text layout.
//

import AppKit
import SwiftUI

// MARK: - CodeBlockView

struct CodeBlockView: View {
    let code: String
    let language: String?
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme
    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            CodeContentView(
                code: code,
                language: language,
                baseWidth: baseWidth,
                theme: theme
            )
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.codeBlockBackground)
        )
        .onHover { isHovered = $0 }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            Text(language?.lowercased() ?? "code")
                .font(theme.monoFont(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            Spacer(minLength: 0)

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
        .frame(height: 28)
    }
}

// MARK: - CodeContentView (NSViewRepresentable)

/// Minimal NSTextView wrapper for syntax-highlighted code with line numbers.
/// Line numbers are drawn in the same NSTextView's draw() so they share
/// the exact same coordinate system and layout timing as the code text.
struct CodeContentView: NSViewRepresentable {
    let code: String
    let language: String?
    let baseWidth: CGFloat
    let theme: ThemeProtocol

    final class Coordinator {
        var lastCode: String = ""
        var lastLanguage: String?
        var lastWidth: CGFloat = 0
        var lastThemeId: String = ""
        var lastMeasuredHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeNSTextView {
        let textView = CodeNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false

        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selectionColor)
        ]
        textView.insertionPointColor = NSColor(theme.cursorColor)
        textView.lineNumberColor = NSColor(theme.tertiaryText.opacity(0.4))

        return textView
    }

    func updateNSView(_ textView: CodeNSTextView, context: Context) {
        let coord = context.coordinator
        let themeId = "\(theme.monoFontName)|\(theme.bodySize)"
        textView.textContainer?.containerSize = NSSize(width: baseWidth, height: .greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        textView.lineNumberColor = NSColor(theme.tertiaryText.opacity(0.4))

        let codeChanged = coord.lastCode != code
        let langChanged = coord.lastLanguage != language
        let widthChanged = abs(coord.lastWidth - baseWidth) > 0.1
        let themeChanged = coord.lastThemeId != themeId

        if codeChanged || langChanged || widthChanged || themeChanged {
            let attrStr = buildAttributedString()
            textView.textStorage?.setAttributedString(attrStr)
            textView.lineCount = code.components(separatedBy: "\n").count
            textView.codeFontSize = codeFontSize

            coord.lastCode = code
            coord.lastLanguage = language
            coord.lastWidth = baseWidth
            coord.lastThemeId = themeId
            coord.lastMeasuredHeight = 0
            textView.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? baseWidth
        let coord = context.coordinator

        if coord.lastMeasuredHeight > 0, abs(coord.lastWidth - width) < 0.5 {
            return CGSize(width: width, height: coord.lastMeasuredHeight)
        }

        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        guard let tc = nsView.textContainer, let lm = nsView.layoutManager else { return nil }
        lm.ensureLayout(for: tc)
        let measured = ceil(lm.usedRect(for: tc).height) + 4

        coord.lastWidth = width
        coord.lastMeasuredHeight = measured
        return CGSize(width: width, height: measured)
    }

    // MARK: - Attributed String

    private var scale: CGFloat { Typography.scale(for: baseWidth) }
    private var bodyFontSize: CGFloat { CGFloat(theme.bodySize) * scale }
    private var codeFontSize: CGFloat { bodyFontSize * 0.85 }

    private func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fontName = theme.monoFontName
        if fontName.lowercased().contains("sf mono") || fontName.isEmpty {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        if let custom = NSFont(name: fontName, size: size) { return custom }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func buildAttributedString() -> NSMutableAttributedString {
        let fontSize = codeFontSize
        let font = monoFont(size: fontSize, weight: .regular)
        let codeColor = NSColor(theme.primaryText.opacity(0.95))
        let lines = code.components(separatedBy: "\n")

        let gutterDigits = "\(lines.count)".count
        let gutterWidth = CGFloat(gutterDigits + 2) * fontSize * 0.62
        let indent: CGFloat = 12 + gutterWidth

        let result = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let highlighted = highlightSyntax(line, language: language, font: font, defaultColor: codeColor)
            result.append(highlighted)
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -12

        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: style, range: fullRange)

        return result
    }

    // MARK: - Syntax Highlighting (reuses SyntaxKeywords from SelectableTextView)

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

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
                return nil
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

        if (lang == "html" || lang == "xml") && line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") {
            result.addAttribute(.foregroundColor, value: commentColor, range: fullRange)
            return result
        }

        if let regex = Self.cachedRegex(#"(\"[^\"\\]*(?:\\.[^\"\\]*)*\"|'[^'\\]*(?:\\.[^'\\]*)*')"#) {
            for match in regex.matches(in: line, range: fullRange) {
                result.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }

        if let regex = Self.cachedRegex(#"\b(\d+\.?\d*)\b"#) {
            for match in regex.matches(in: line, range: fullRange) {
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

        let keywords = SyntaxKeywords.keywords(for: lang)
        if !keywords.isEmpty {
            for keyword in keywords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                if let regex = Self.cachedRegex(pattern) {
                    for match in regex.matches(in: line, range: fullRange) {
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
                                value: monoFont(size: font.pointSize, weight: .medium),
                                range: match.range
                            )
                        }
                    }
                }
            }
        }

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
}

// MARK: - CodeNSTextView

/// Minimal NSTextView subclass that draws line numbers in the gutter.
/// No background drawing, no overlay coordination — just text + line numbers.
final class CodeNSTextView: NSTextView {
    var lineNumberColor: NSColor = .tertiaryLabelColor
    var lineCount: Int = 0
    var codeFontSize: CGFloat = 12

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
            if let url { NSWorkspace.shared.open(url); return }
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager = layoutManager,
            textContainer != nil,
            let textStorage = textStorage,
            lineCount > 0
        else {
            super.draw(dirtyRect)
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: lineNumberColor]
        let digits = "\(lineCount)".count
        let charWidth = codeFontSize * 0.62
        let leftPad: CGFloat = 12
        let gutterPointWidth = CGFloat(digits + 2) * codeFontSize * 0.62
        let nsString = textStorage.string as NSString
        var charIndex = 0

        for lineNum in 1 ... lineCount {
            guard charIndex < textStorage.length else { break }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            let y = fragRect.origin.y
            guard y + fragRect.height >= dirtyRect.minY, y <= dirtyRect.maxY else {
                let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
                charIndex = NSMaxRange(lineRange)
                continue
            }

            let numStr = String(lineNum).padding(toLength: digits, withPad: " ", startingAt: 0) as NSString
            let numSize = numStr.size(withAttributes: attrs)
            let x = leftPad + gutterPointWidth - numSize.width - charWidth * 1.2

            numStr.draw(at: NSPoint(x: x, y: fragRect.origin.y), withAttributes: attrs)

            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
        }

        super.draw(dirtyRect)
    }
}
