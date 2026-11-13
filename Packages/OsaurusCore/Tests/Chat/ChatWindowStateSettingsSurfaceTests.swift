//
//  ChatWindowStateSettingsSurfaceTests.swift
//  osaurusTests
//
//  Settings is a destination of the chat window, beside Chat and
//  Workflows: opening it lands on the requested page without touching the
//  window's chat tabs, back never leaves it, and a compact window
//  collapses its sidebar to icons until the window widens again.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateSettingsSurfaceTests {

    private static func withSelectedTabRestored(_ body: () throws -> Void) rethrows {
        let manager = ManagementStateManager.shared
        let original = manager.selectedTab
        defer { manager.selectedTab = original }
        try body()
    }

    @Test("showSettings lands on the requested page and keeps the chat tab")
    func showSettingsSelectsTab() async throws {
        try await ChatHistoryTestStorage.run {
            Self.withSelectedTabRestored {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                let chatTab = window.activeTabId

                window.showSettings(tab: .models)
                #expect(window.mainSurface == .settings)
                #expect(ManagementStateManager.shared.selectedTab == .models)
                #expect(window.activeTabId == chatTab)

                window.showSettings()
                #expect(ManagementStateManager.shared.selectedTab == .models, "no tab keeps the page on screen")

                #expect(window.goBack() == false, "back never leaves Settings")
                #expect(window.mainSurface == .settings)

                window.showMainSurface(.chat)
                #expect(window.mainSurface == .chat)
                #expect(window.activeTabId == chatTab)
            }
        }
    }

    @Test("a compact window collapses the Settings sidebar and widening restores the choice")
    func compactCollapsesSidebar() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.updateShellBreakpoint(.wide)

            #expect(window.isSettingsSidebarCollapsed == false)
            window.updateShellBreakpoint(.compact)
            #expect(window.isSettingsSidebarCollapsed)
            window.updateShellBreakpoint(.regular)
            #expect(window.isSettingsSidebarCollapsed == false)

            window.isSettingsSidebarCollapsed = true
            window.updateShellBreakpoint(.compact)
            window.isSettingsSidebarCollapsed = false
            window.updateShellBreakpoint(.wide)
            #expect(window.isSettingsSidebarCollapsed, "widening restores the choice from before compact")
        }
    }
}
