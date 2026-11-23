//
//  NativeArtifactCardHeightTests.swift
//
//  A text artifact's preview draws at most six lines. The card must size
//  to those six lines, not to every line a long paragraph would wrap to,
//  or the footer stretches into an empty band under the preview.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct NativeArtifactCardHeightTests {

    private func measuredHeight(content: String, width: CGFloat = 420) -> CGFloat {
        let card = NativeArtifactCardView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.widthAnchor.constraint(equalToConstant: width),
        ])
        card.configure(
            artifact: SharedArtifact(
                contextId: "test", contextType: .chat, filename: "intro.md", mimeType: "text/markdown",
                fileSize: content.utf8.count, hostPath: "/tmp/intro.md", content: content,
                description: "Weekly competitor update intro paragraph"),
            theme: CustomizableTheme.light())
        host.layoutSubtreeIfNeeded()
        return card.measuredCardHeight()
    }

    @Test("a long paragraph in the preview sizes the card like any six drawn lines")
    func longParagraphPreviewIsCappedAtSixLines() {
        let paragraph = String(
            repeating: "The tools competing most directly with us are fast becoming full-stack AI workbenches. ",
            count: 20)
        let wrapped = measuredHeight(content: "# Weekly Competitor Update\n\n\(paragraph)\n\nMore below.")
        let sixShortLines = measuredHeight(content: (1...6).map { "line \($0)" }.joined(separator: "\n"))
        #expect(abs(wrapped - sixShortLines) <= 1, "wrapped \(wrapped) vs six lines \(sixShortLines)")
    }

    @Test("a short preview still sizes to its own lines")
    func shortPreviewStaysShort() {
        let oneLine = measuredHeight(content: "hello")
        let sixLines = measuredHeight(content: (1...6).map { "line \($0)" }.joined(separator: "\n"))
        #expect(oneLine < sixLines)
    }
}
