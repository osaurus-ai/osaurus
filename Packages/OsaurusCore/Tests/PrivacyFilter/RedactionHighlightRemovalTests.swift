//
//  RedactionHighlightRemovalTests.swift
//  osaurusTests
//
//  Forget and Stop redacting shrink a conversation's redactions while its
//  bubbles stay on screen. The highlighter only adds attributes, so a
//  bubble must lose the underline and accent color of a value that is no
//  longer redacted.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RedactionHighlightRemovalTests {
    private static let theme = CustomizableTheme(config: .lightDefault, fontScale: 1.0)
    private static let phone = "212-555-0199"

    private func textViews(_ view: NSView) -> [NSTextView] {
        if let textView = view as? NSTextView { return [textView] }
        return view.subviews.flatMap(textViews)
    }

    private func paintedRanges(_ view: NSView) -> [NSRange] {
        textViews(view).flatMap { textView -> [NSRange] in
            guard let storage = textView.textStorage else { return [] }
            var ranges: [NSRange] = []
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.redactionPlaceholder, in: full) { value, range, _ in
                if value != nil { ranges.append(range) }
            }
            storage.enumerateAttribute(.underlineStyle, in: full) { value, range, _ in
                if value != nil { ranges.append(range) }
            }
            return ranges
        }
    }

    private func rendered(_ highlights: [String: RedactionHighlight]) -> NativeMarkdownView {
        let view = NativeMarkdownView()
        view.configure(
            text: "Call \(Self.phone) about the build.",
            width: 600,
            theme: Self.theme,
            cacheKey: nil,
            isStreaming: false
        )
        view.setRedactionHighlights(highlights, theme: Self.theme)
        return view
    }

    @Test func clearingHighlightsRemovesTheirUnderline() {
        let view = rendered([Self.phone: RedactionHighlight(placeholderToken: "[PHONE_1]", direction: .outbound)])
        #expect(!paintedRanges(view).isEmpty)

        view.setRedactionHighlights([:], theme: Self.theme)

        #expect(paintedRanges(view).isEmpty)
    }

    @Test func droppingOneHighlightKeepsTheOthers() {
        let email = "alice@example.com"
        let view = NativeMarkdownView()
        view.configure(
            text: "Call \(Self.phone) or mail \(email).",
            width: 600,
            theme: Self.theme,
            cacheKey: nil,
            isStreaming: false
        )
        view.setRedactionHighlights(
            [
                Self.phone: RedactionHighlight(placeholderToken: "[PHONE_1]", direction: .outbound),
                email: RedactionHighlight(placeholderToken: "[EMAIL_1]", direction: .outbound),
            ],
            theme: Self.theme
        )

        view.setRedactionHighlights(
            [email: RedactionHighlight(placeholderToken: "[EMAIL_1]", direction: .outbound)],
            theme: Self.theme
        )

        let text = textViews(view).map(\.string).joined()
        let emailRange = (text as NSString).range(of: email)
        let ranges = paintedRanges(view)
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { NSIntersectionRange($0, emailRange).length == $0.length })
    }

    /// Forget clears the chat's redactions while the transcript stays the
    /// same, so the table has to repaint bubbles that are already on screen.
    @Test func forgettingRedactionsRepaintsBubblesOnScreen() async throws {
        let tableView = MessageTableRepresentable.makeTableView()
        let scrollView = MessageTableRepresentable.makeScrollView(documentView: tableView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        scrollView.frame = window.contentView!.bounds
        window.contentView?.addSubview(scrollView)
        defer { window.close() }
        let coordinator = MessageTableRepresentable.Coordinator()
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.setupDataSource(for: tableView)
        coordinator.lastSwiftUIWidth = 700

        let memoizer = BlockMemoizer()
        let turns = [
            ChatTurn(role: .user, content: "Call \(Self.phone) about the build."),
            ChatTurn(role: .assistant, content: "I'll call \(Self.phone) now."),
        ]
        func apply(_ redactions: [String: String]) async {
            var context = CellRenderingContext(
                width: coordinator.resolvedContentWidth(swiftUIWidth: 700),
                agentName: "Osaurus",
                agentAvatar: nil,
                agentCustomAvatarPath: nil,
                isStreaming: false,
                lastAssistantTurnId: turns.last?.id,
                theme: Self.theme,
                expandedIds: coordinator.expandedIds,
                onToggleExpand: { _ in },
                onHeightMeasured: { [weak coordinator] height, id in
                    coordinator?.reportMeasuredHeight(height, forBlockId: id)
                }
            )
            context.sessionRedactions = redactions
            coordinator.applyBlocks(
                memoizer.blocks(from: turns, streamingTurnId: nil, agentName: "Osaurus"),
                groupHeaderMap: memoizer.groupHeaderMap,
                context: context,
                isStreaming: false,
                lastAssistantTurnId: turns.last?.id,
                autoScrollEnabled: true
            )
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 50_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        await apply([Self.phone: "[PHONE_1]"])
        #expect(!paintedRanges(tableView).isEmpty)

        await apply([:])
        #expect(paintedRanges(tableView).isEmpty)
    }
}
