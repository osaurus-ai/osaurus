//
//  AssignedPickerTriggerTests.swift
//  osaurusTests
//
//  The menu trigger over a styled picker lives beside the picker's hosting
//  view, not inside it. SwiftUI strips foreign subviews from an
//  NSHostingView on every update; re-adding the trigger from layout kept
//  re-dirtying the window until AppKit aborted with "more Update Constraints
//  in Window passes than there are views".
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct AssignedPickerTriggerTests {
    @MainActor private final class Model: ObservableObject {
        @Published var selection = ""
        @Published var caption = "Waiting"
    }

    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack(alignment: .leading) {
                Text(verbatim: model.caption)
                SettingsMenuPicker(selection: $model.selection) {
                    Text(verbatim: "Choose…").tag("")
                    ForEach(["Approve as written", "Send back", "Discard"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .fixedSize()
            }
            .padding()
            .environment(\.theme, ThemeManager.shared.currentTheme)
        }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func triggers(in view: NSView) -> [NSView] {
        let mine = String(describing: type(of: view)).contains("AssignedPickerMenuTrigger") ? [view] : []
        return mine + view.subviews.flatMap { triggers(in: $0) }
    }

    @Test func triggerSurvivesRerendersBesideTheHostingView() throws {
        let model = Model()
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.titled], backing: .buffered,
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
        settle()
        let first = try #require(Self.triggers(in: host).first)
        let container = try #require(first.superview)
        let popupWidth = try #require(Self.all(NSPopUpButton.self, in: container).first).intrinsicContentSize.width
        #expect(container.frame.width == popupWidth, "the picker sizes to its styled popup")
        for step in 0 ..< 8 {
            model.caption = "Waiting \(step)"
            if step % 3 == 2 { model.selection = step % 2 == 0 ? "Send back" : "" }
            settle()
            let found = Self.triggers(in: host)
            #expect(found.count == 1)
            #expect(found.first === first, "trigger replaced on re-render \(step)")
            #expect(!(first.superview is NSHostingView<AnyView>), "trigger must not sit inside a hosting view")
            // The settings picker draws its closed value in the trigger over a
            // hidden popup, so the trigger covers the whole picker.
            let popup = try #require(Self.all(NSPopUpButton.self, in: host).first)
            #expect(popup.alphaValue == 0)
            #expect(first.frame == first.superview?.bounds, "trigger drifted off the picker")
            #expect(first.frame.width > 40 && first.frame.height > 10)
        }
        #expect(!host.needsLayout, "an idle picker keeps scheduling layout")
    }
}
