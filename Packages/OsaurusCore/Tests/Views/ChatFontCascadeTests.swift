//
//  ChatFontCascadeTests.swift
//  OsaurusCoreTests
//

import AppKit
import CoreText
import Testing

@testable import OsaurusCore

@Suite("Chat font cascade")
@MainActor
struct ChatFontCascadeTests {
    private let simplifiedOnly = "东京都神奈川县爱知县兵库县鸟取县静冈县"

    private func cascadeFamilies(_ font: NSFont) -> [String] {
        guard let list = CTFontCopyAttribute(font as CTFont, kCTFontCascadeListAttribute) as? [CTFontDescriptor]
        else { return [] }
        return list.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

    @Test("wrapped system bold font carries an explicit CJK cascade family")
    func wrappedFontHasCjkCascade() throws {
        let base = NSFont.systemFont(ofSize: 15, weight: .bold)
        let wrapped = SelectableTextView.withCjkCascade(base)
        #expect(cascadeFamilies(wrapped).contains { $0 == "PingFang SC" || $0 == "Songti SC" })
    }

    @Test("serif theme font resolves its CJK cascade through a serif family")
    func serifThemeGetsSerifCascade() throws {
        let georgia = try #require(NSFont(name: "Georgia", size: 15))
        let wrapped = SelectableTextView.withCjkCascade(georgia)
        #expect(cascadeFamilies(wrapped).contains("Songti SC"))
    }

    @Test("streaming re-layouts render simplified-only codepoints with zero notdef glyphs")
    func streamingLayoutProducesNoNotdefGlyphs() throws {
        let bold = SelectableTextView.withCjkCascade(NSFont.systemFont(ofSize: 15, weight: .bold))
        let regular = SelectableTextView.withCjkCascade(NSFont.systemFont(ofSize: 15, weight: .regular))

        let text = "1. **\(simplifiedOnly)** — 14,236,627 人\n人口最少的都道府县是**\(simplifiedOnly)**。"
        let chars = Array(text)

        // Simulate the streaming apply pattern: full storage replace per tick
        // with a growing prefix, each followed by a forced layout.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        _ = textView.layoutManager
        textView.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        var index = 0
        repeat {
            index = min(chars.count, index + 29)
            textView.textStorage?.setAttributedString(themeStyled(String(chars[0..<index]), bold: bold, regular: regular))
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        } while index < chars.count

        let storage = try #require(textView.textStorage)
        let layoutManager = try #require(textView.layoutManager)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)

        var notdefChars: [String] = []
        for glyphIndex in glyphRange.location..<(glyphRange.location + glyphRange.length) {
            var isValid: ObjCBool = false
            if layoutManager.glyph(at: glyphIndex, isValidIndex: &isValid) == 0 {
                let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                notdefChars.append((storage.string as NSString).substring(with: NSRange(location: charIndex, length: 1)))
            }
        }
        #expect(notdefChars.isEmpty, "notdef glyphs for: \(notdefChars.joined())")
    }

    @Test("non-CJK scripts still resolve through fallback with the cascade attached")
    func nonCjkScriptsUnaffected() throws {
        let wrapped = SelectableTextView.withCjkCascade(NSFont.systemFont(ofSize: 15, weight: .regular))
        let text = "Русский текст, Ελληνικά, العربية, ไทย, café"

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 60))
        _ = textView.layoutManager
        textView.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: wrapped]))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let storage = try #require(textView.textStorage)
        let layoutManager = try #require(textView.layoutManager)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)

        var notdefCount = 0
        for glyphIndex in glyphRange.location..<(glyphRange.location + glyphRange.length) {
            var isValid: ObjCBool = false
            if layoutManager.glyph(at: glyphIndex, isValidIndex: &isValid) == 0 {
                notdefCount += 1
            }
        }
        // All scripts above are BMP, so any notdef here is a real regression.
        #expect(notdefCount == 0)
    }

    // Mirrors SelectableTextView.applyThemeStyling: markdown parse, then bold
    // runs (via emphasis intent) get the bold font, everything else regular.
    private func themeStyled(_ text: String, bold: NSFont, regular: NSFont) -> NSAttributedString {
        let parsed =
            (try? NSAttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? NSAttributedString(string: text)
        let mutable = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: regular, range: full)
        mutable.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            if let raw = attributes[.inlinePresentationIntent] as? NSNumber,
                InlinePresentationIntent(rawValue: raw.uintValue).contains(.stronglyEmphasized)
            {
                mutable.addAttribute(.font, value: bold, range: range)
            }
        }
        return mutable
    }
}
