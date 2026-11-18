//
//  RedactionPreviewFocusTests.swift
//  osaurusTests
//
//  The review sheet's inline preview is a few lines tall, and context
//  Osaurus injects (memory, current time) usually precedes the user's
//  words. The preview has to open scrolled to the item under review.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct RedactionPreviewFocusTests {
    private static let theme = CustomizableTheme(config: .lightDefault, fontScale: 1.0)

    private struct Harness: View {
        let text: String
        let focus: String
        var body: some View {
            RedactionPreviewTextView(
                scrubbedText: text,
                highlights: [focus: RedactionHighlight(placeholderToken: "a@b.co", direction: .preview)],
                theme: RedactionPreviewFocusTests.theme,
                focusText: focus
            )
            .frame(width: 320, height: 48)
        }
    }

    private static func scrollViews(in view: NSView) -> [FocusingScrollView] {
        ((view as? FocusingScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func previewOpensScrolledToTheItem() async throws {
        let context = (1 ... 40).map { "Injected context line \($0)." }.joined(separator: "\n")
        let text = context + "\nMail [EMAIL_1] tomorrow."
        let host = NSHostingView(rootView: Harness(text: text, focus: "[EMAIL_1]"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let scroll = try #require(Self.scrollViews(in: host).first)
        let textView = try #require(scroll.documentView as? NSTextView)
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: (text as NSString).range(of: "[EMAIL_1]"),
            actualCharacterRange: nil
        )
        let itemRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = scroll.contentView.bounds

        #expect(visible.height > 0)
        #expect(visible.intersects(itemRect), "visible \(visible) misses the item at \(itemRect)")
    }
}
