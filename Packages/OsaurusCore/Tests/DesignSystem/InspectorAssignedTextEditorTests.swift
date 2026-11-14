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

    private static func textViews(in view: NSView) -> [InspectorMultilineTextView] {
        ((view as? InspectorMultilineTextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews(in: $0) }
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
}
