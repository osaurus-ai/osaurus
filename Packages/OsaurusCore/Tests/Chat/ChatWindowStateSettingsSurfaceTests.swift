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

    @Test("Insights is its own page surface and leaves Settings' page alone")
    func insightsIsItsOwnSurface() async throws {
        try await ChatHistoryTestStorage.run {
            Self.withSelectedTabRestored {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                let chatTab = window.activeTabId

                window.showSettings(tab: .privacy)
                window.showMainSurface(.insights)
                #expect(window.mainSurface == .insights)
                #expect(window.showsPageSurface)
                #expect(ManagementStateManager.shared.selectedTab == .privacy, "Settings keeps its page")
                #expect(window.activeTabId == chatTab)
                #expect(window.goBack() == false, "back never leaves Insights")

                window.showMainSurface(.chat)
                #expect(window.showsPageSurface == false)
                #expect(window.activeTabId == chatTab)
            }
        }
    }

    @Test("a link to another surface offers the way back, one jump at a time")
    func linkedSurfaceOffersBack() async throws {
        try await ChatHistoryTestStorage.run {
            Self.withSelectedTabRestored {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                let chatTab = window.activeTabId
                #expect(window.surfaceBack == nil)

                window.showSettings(tab: .privacy)
                window.showMainSurface(.insights)
                #expect(window.surfaceBack?.surface == .settings)
                #expect(window.surfaceBack?.title == ManagementTab.privacy.label)

                #expect(window.returnToPreviousSurface())
                #expect(window.mainSurface == .settings)
                #expect(ManagementStateManager.shared.selectedTab == .privacy)
                #expect(window.surfaceBack?.surface == .chat)

                #expect(window.returnToPreviousSurface())
                #expect(window.mainSurface == .chat)
                #expect(window.activeTabId == chatTab)
                #expect(window.surfaceBack == nil)
                #expect(window.returnToPreviousSurface() == false)
            }
        }
    }

    @Test("leaving New Agent for the agent it made keeps the way back to where New Agent opened")
    func newAgentHandsItsBackOn() async throws {
        try await ChatHistoryTestStorage.run {
            Self.withSelectedTabRestored {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                let chatTab = window.activeTabId

                window.showMainSurface(.newAgent)
                #expect(window.showsPageSurface)
                #expect(window.surfaceBack?.surface == .chat)

                window.leaveNewAgent { window.showSettings(tab: .agents) }
                #expect(window.mainSurface == .settings)
                #expect(window.surfaceBack?.surface == .chat, "back skips the emptied creator")
                #expect(window.surfaceReturns.count == 1)

                #expect(window.returnToPreviousSurface())
                #expect(window.mainSurface == .chat)
                #expect(window.activeTabId == chatTab)
            }
        }
    }

    @Test("the navigation rail is top level and drops the way back")
    func railDropsBack() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.showMainSurface(.insights)
            #expect(window.surfaceBack != nil)
            window.showMainSurfaceFromRail(.settings)
            #expect(window.surfaceBack == nil)
            window.showMainSurfaceFromRail(.insights)
            #expect(window.surfaceBack == nil)
        }
    }

    @Test("a Workflows page a link opened goes back to the link after its own pages")
    func workflowsLinkBackAfterOwnPages() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.showMainSurfaceFromRail(.insights)

            let workflowID = UUID()
            window.showWorkflowRun(workflowID: workflowID, runID: UUID())
            #expect(window.surfaceBack?.surface == .insights)

            window.pushWorkflowsPage(.workflow(workflowID))
            #expect(window.surfaceBack == nil, "Workflows' own back button steps out first")
            #expect(window.goBack())
            #expect(window.surfaceBack?.surface == .insights)

            #expect(window.goBack())
            #expect(window.mainSurface == .insights)
            #expect(window.surfaceBack == nil)
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
