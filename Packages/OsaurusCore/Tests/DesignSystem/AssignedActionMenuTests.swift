//
//  AssignedActionMenuTests.swift
//  osaurusTests
//
//  The ⋯ trigger behind SettingsOverflowMenu and the chat sidebar rows.
//  Opening its panel changes the key window, which re-renders the parent;
//  the trigger used to re-show (rebuild) the open panel on every one of
//  those renders and swap its own hosting view's root mid-update.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct AssignedActionMenuTests {
    @MainActor private final class Model: ObservableObject {
        @Published var caption = "Waiting"
        @Published var opened = 0
    }

    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            HStack {
                Text(verbatim: model.caption)
                SettingsOverflowMenu(help: "More actions", size: .compact) {
                    Button { model.opened += 1 } label: { Text(verbatim: "Open \(model.caption)") }
                    Divider()
                    Button("Delete", role: .destructive) {}
                }
            }
            .padding()
            .environment(\.theme, ThemeManager.shared.currentTheme)
        }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// Awaits rather than spinning the run loop: the trigger defers work with
    /// `DispatchQueue.main.async`, which a nested run loop inside this
    /// main-queue test never drains.
    @Test func openMenuShowsOnceAcrossParentRerenders() async throws {
        let model = Model()
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await settle()
        let trigger = try #require(Self.all(AssignedActionMenuInput.InputView.self, in: host).first)
        #expect(trigger.frame.width > 10 && trigger.frame.height > 10, "the trigger sizes to its graphic")

        #expect(trigger.accessibilityPerformPress())
        try await settle()
        #expect(trigger.presenter.isPresented)
        #expect(trigger.presenter.showCount == 1)
        let firstMenu = try #require(trigger.openMenu)
        #expect(firstMenu.items.contains { $0.title == "Delete" }, "the menu lists the content's buttons")

        for step in 0 ..< 8 {
            model.caption = "Waiting \(step)"
            try await settle()
            #expect(Self.all(AssignedActionMenuInput.InputView.self, in: host).first === trigger)
            #expect(trigger.presenter.isPresented, "menu closed on re-render \(step)")
            #expect(trigger.presenter.showCount == 1, "menu rebuilt on re-render \(step)")
        }
        #expect(!host.needsLayout, "an idle open menu keeps scheduling layout")

        trigger.cancelPresentation()
        try await settle()
        #expect(!trigger.presenter.isPresented)
        #expect(trigger.accessibilityPerformPress())
        try await settle()
        #expect(trigger.presenter.isPresented, "menu reopens after closing")
        #expect(trigger.presenter.showCount == 2)
        #expect(trigger.openMenu !== firstMenu, "each opening builds its own menu, never swapping a root")
        trigger.cancelPresentation()
    }
}
