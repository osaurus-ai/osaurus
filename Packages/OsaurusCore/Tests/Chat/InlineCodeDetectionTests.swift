//
//  InlineCodeDetectionTests.swift
//  osaurusTests
//
//  Pins the assumption behind inline-code detection in
//  SelectableTextView.applyThemeStyling: a code span parsed by
//  NSAttributedString(markdown:) is identifiable via the font's monoSpace
//  trait OR the inline presentation intent — including when wrapped in
//  bold (`**`path`**`), the form that models commonly emit around file
//  paths and that font-trait-only detection missed (knowledge links).
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

struct InlineCodeDetectionTests {

    private func codeRunCovers(_ markdown: String, span: String) throws -> Bool {
        let attr = try NSAttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let full = NSRange(location: 0, length: attr.length)
        var found = false
        attr.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            let traits =
                (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let intent = SelectableTextView.inlineIntent(attributes)
            guard traits.contains(.monoSpace) || intent.contains(.code) else { return }
            if (attr.attributedSubstring(from: range).string) == span { found = true }
        }
        return found
    }

    @Test func plainCodeSpanIsDetectable() throws {
        #expect(try codeRunCovers("See `Docs/Report.md` here", span: "Docs/Report.md"))
    }

    @Test func boldWrappedCodeSpanIsDetectable() throws {
        #expect(try codeRunCovers("📄 **`UW Metrics & Definitions/Reports/Summary.md`**",
            span: "UW Metrics & Definitions/Reports/Summary.md"))
    }
}
