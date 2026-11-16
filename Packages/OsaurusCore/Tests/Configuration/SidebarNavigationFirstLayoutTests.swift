//
//  SidebarNavigationFirstLayoutTests.swift
//  osaurusTests
//
//  A window opening straight onto a focused page (the New Agent creator)
//  lays its sidebar out collapsed on the first pass, so no width spring
//  runs while the window's first layout settles.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SidebarNavigationFirstLayoutTests {
    @MainActor private final class Probe {
        var contentMinX: CGFloat?
    }

    private static func sidebar(focusCollapsed: Bool, probe: Probe) -> AnyView {
        AnyView(
            SidebarNavigation(
                selection: .constant("a"),
                searchText: .constant(""),
                sections: [
                    SidebarSectionData(
                        id: "main", title: "", items: [SidebarItemData(id: "a", icon: "star", label: "Agents")])
                ],
                focusCollapsed: focusCollapsed,
                content: { _ in
                    GeometryReader { proxy in
                        let minX = proxy.frame(in: .global).minX
                        Color.clear
                            .onAppear { probe.contentMinX = minX }
                            .onChange(of: minX) { _, x in probe.contentMinX = x }
                    }
                },
                footer: { EmptyView() }
            )
            .environment(\.theme, CustomizableTheme.dark()))
    }

    @Test func aFocusedPageLaysTheSidebarOutCollapsedOnTheFirstPass() throws {
        let probe = Probe()
        let host = NSHostingView(rootView: Self.sidebar(focusCollapsed: true, probe: probe))
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        let collapsed = try #require(probe.contentMinX)
        #expect(collapsed < 100, "content starts at \(collapsed); the sidebar laid out expanded first")

        host.rootView = Self.sidebar(focusCollapsed: false, probe: probe)
        host.layoutSubtreeIfNeeded()
        let restored = try #require(probe.contentMinX)
        #expect(restored > 200, "leaving the focused page restores the expanded sidebar (\(restored))")
    }
}
