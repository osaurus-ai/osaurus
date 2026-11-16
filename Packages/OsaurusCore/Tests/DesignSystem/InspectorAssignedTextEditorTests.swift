//
//  InspectorAssignedTextEditorTests.swift
//  osaurusTests
//
//  Clearing a multiline editor from code (Help resets its form after Send)
//  used to restore an empty selection list. `NSTextView` raises on that, and
//  the exception, thrown through a SwiftUI update, left Observation's
//  tracking state dangling until a later read crashed the app.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct InspectorAssignedTextEditorTests {
    @MainActor private final class Model: ObservableObject {
        @Published var text = ""
    }

    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            SettingsTextEditor(text: $model.text, placeholder: "Describe the problem", minHeight: 120)
                .frame(width: 320)
                .padding()
                .environment(\.theme, ThemeManager.shared.currentTheme)
        }
    }

    @MainActor private final class SizedModel: ObservableObject {
        @Published var text = ""
        @Published var width: CGFloat = 400
    }

    /// The Agent page's System Prompt editor at a width the test controls.
    private struct SizedHarness: View {
        @ObservedObject var model: SizedModel
        var body: some View {
            SettingsTextEditor(text: $model.text, minHeight: 160, maxHeight: 300, monospaced: true)
                .frame(width: model.width)
                .environment(\.theme, ThemeManager.shared.currentTheme)
        }
    }

    private static func textViews(in view: NSView) -> [InspectorMultilineTextView] {
        ((view as? InspectorMultilineTextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews(in: $0) }
    }

    private static func scrollViews(in view: NSView) -> [InspectorEditorScrollView] {
        ((view as? InspectorEditorScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Hosts the sized harness with width-consuming scroll bars, as macOS
    /// draws them with a mouse attached or "Show scroll bars: Always".
    private static func hostLegacyScrollerEditor(_ model: SizedModel) throws -> (
        NSWindow, NSHostingView<SizedHarness>, InspectorEditorScrollView
    ) {
        let host = NSHostingView(rootView: SizedHarness(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollViews(in: host).first)
        scroll.scrollerStyle = .legacy
        return (window, host, scroll)
    }

    /// Lays out and yields the main actor for `seconds`, returning every
    /// editor height seen. The editor publishes its measured height with
    /// `DispatchQueue.main.async`, which a nested `RunLoop.run` inside this
    /// main-queue test job would never drain; `Task.sleep` does.
    private static func observedHeights(
        _ host: NSView, _ scroll: NSScrollView, for seconds: Double = 0.25
    ) async -> Set<CGFloat> {
        var heights: Set<CGFloat> = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 5_000_000)
            host.layoutSubtreeIfNeeded()
            heights.insert(scroll.frame.height)
        }
        return heights
    }

    private static func settle(_ host: NSView, _ scroll: NSScrollView) async {
        _ = await observedHeights(host, scroll, for: 0.15)
    }

    @Test func restoredSelectionKeepsRangesThatStillFit() {
        let ranges = [NSValue(range: NSRange(location: 2, length: 3))]
        #expect(InspectorAssignedTextEditor.restoredSelection(ranges, length: 10) == ranges)
    }

    @Test func restoredSelectionIsNeverEmpty() {
        let caretAtOldEnd = [NSValue(range: NSRange(location: 58, length: 0))]
        #expect(
            InspectorAssignedTextEditor.restoredSelection(caretAtOldEnd, length: 0)
                == [NSValue(range: NSRange(location: 0, length: 0))])
        #expect(
            InspectorAssignedTextEditor.restoredSelection([], length: 4)
                == [NSValue(range: NSRange(location: 4, length: 0))])
    }

    @Test func clearingTheBoundTextWithTheCaretAtTheEndKeepsACaret() throws {
        let model = Model()
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
        }
        model.text = "Crash repro test: app crashed right after sending a report"
        settle()
        let view = try #require(Self.textViews(in: host).first)
        #expect(view.string == model.text)
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))

        model.text = ""
        settle()

        #expect(view.string.isEmpty)
        #expect(view.selectedRanges == [NSValue(range: NSRange(location: 0, length: 0))])
    }

    /// Issue #3426: an auto-hiding legacy scroller narrowed the text by one
    /// wrap, the editor grew to fit, the scroller hid, the text unwrapped, and
    /// the page jittered by a line every frame.
    @Test func heightBetweenMinAndMaxStaysStillWithLegacyScrollers() async throws {
        let model = SizedModel()
        model.text = Array(repeating: "ab", count: 180).joined(separator: " ")
        let (window, host, scroll) = try Self.hostLegacyScrollerEditor(model)
        defer { window.close() }

        var unstable: [String] = []
        var inRange = 0
        // Wider than one word plus a legacy scroller, so some width wraps
        // differently with and without the scroller.
        for width in stride(from: CGFloat(400), through: 440, by: 1) {
            model.width = width
            await Self.settle(host, scroll)
            let heights = await Self.observedHeights(host, scroll)
            if heights.allSatisfy({ $0 > 100 && $0 < 300 }) { inRange += 1 }
            if heights.count > 1 { unstable.append("\(width): \(heights.sorted())") }
        }
        #expect(inRange > 0, "The sweep never sized the editor between its min and max height")
        #expect(unstable.isEmpty, "Editor height changed while idle at widths \(unstable)")
    }

    @Test func shortTextStaysAtTheMinimumHeightWithoutAScroller() async throws {
        let model = SizedModel()
        model.text = "Short prompt"
        let (window, host, scroll) = try Self.hostLegacyScrollerEditor(model)
        defer { window.close() }

        await Self.settle(host, scroll)
        let heights = await Self.observedHeights(host, scroll)
        #expect(heights.count == 1)
        #expect(!scroll.hasVerticalScroller || scroll.verticalScroller?.isHidden != false)
    }

    @Test func textTallerThanTheMaximumScrollsAtTheMaximumHeight() async throws {
        let model = SizedModel()
        model.text = Array(repeating: "ab", count: 1500).joined(separator: " ")
        let (window, host, scroll) = try Self.hostLegacyScrollerEditor(model)
        defer { window.close() }

        await Self.settle(host, scroll)
        let heights = await Self.observedHeights(host, scroll)
        #expect(heights == [300])
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.verticalScroller?.isHidden == false)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentSize.height)
    }
}
