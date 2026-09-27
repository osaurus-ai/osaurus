//
//  ChatWindowStateInspectorTests.swift
//  osaurusTests
//
//  The chat window's right-hand rail mirrors the session sidebar: one
//  toolbar button opens and closes it (reopening on the pane it last
//  showed), the rail's own lens bar switches between File Changes and
//  History, "N files changed" rows deep-link to File Changes, the toolbar
//  badge counts changed files only while the rail is closed, and at narrow
//  widths the two rails take turns rather than crushing the chat column.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateInspectorTests {

    @Test("the toolbar toggle opens on History first, then closes")
    func toggleOpensAndCloses() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.inspectorPane == nil)
            #expect(window.isInspectorOpen == false)
            window.toggleInspector()
            #expect(window.inspectorPane == .history, "a fresh window has no file changes to show")
            #expect(window.isInspectorOpen)
            window.toggleInspector()
            #expect(window.inspectorPane == nil)
        }
    }

    @Test("the toggle reopens on the pane the rail last showed")
    func toggleRemembersLastPane() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.showInspector(.fileChanges)
            #expect(window.inspectorPane == .fileChanges)
            window.closeInspector()
            #expect(window.inspectorPane == nil)
            #expect(window.lastInspectorPane == .fileChanges)
            window.toggleInspector()
            #expect(window.inspectorPane == .fileChanges)
        }
    }

    @Test("the lens bar switches panes in place; showing never closes")
    func showSwitchesInPlace() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.showInspector(.history)
            window.showInspector(.fileChanges)
            #expect(window.inspectorPane == .fileChanges)
            window.showInspector(.fileChanges)
            #expect(window.inspectorPane == .fileChanges, "re-selecting the open pane keeps it open")
            window.showInspector(.history)
            #expect(window.inspectorPane == .history)
        }
    }

    @Test("opening the changes panel shows File Changes focused on the set, even over History")
    func openChangesPanelFocusesSet() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let setId = UUID()

            window.showInspector(.history)
            window.openChangesPanel(focusing: setId)
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.changesPanelFocusSetId == setId)

            // Re-opening without a focus clears the stale focus.
            window.openChangesPanel()
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.changesPanelFocusSetId == nil)
        }
    }

    @Test("an unpinned File Changes falls back to History while the chat has no change sets")
    func fileChangesFallsBackToHistory() {
        #expect(ChatWindowState.effectiveInspectorPane(requested: nil, fileChangeSetCount: 0, isPinned: false) == nil)
        #expect(ChatWindowState.effectiveInspectorPane(requested: .history, fileChangeSetCount: 0, isPinned: false) == .history)
        #expect(
            ChatWindowState.effectiveInspectorPane(requested: .fileChanges, fileChangeSetCount: 0, isPinned: false) == .history,
            "nothing to show yet: History is the useful pane")
        #expect(
            ChatWindowState.effectiveInspectorPane(requested: .fileChanges, fileChangeSetCount: 0, isPinned: true) == .fileChanges,
            "the user asked for it: show the empty state, not a different pane")
        #expect(ChatWindowState.effectiveInspectorPane(requested: .fileChanges, fileChangeSetCount: 2, isPinned: false) == .fileChanges)
    }

    @Test("the lens bar pins the pane; the toggle reopens unpinned; a new tab on screen unpins")
    func pinFollowsExplicitPicks() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.toggleInspector()
            #expect(window.inspectorPanePinned == false)
            #expect(window.effectiveInspectorPane == .history)

            // Tapping File Changes with nothing in it is an explicit choice.
            window.showInspector(.fileChanges)
            #expect(window.inspectorPanePinned)
            #expect(window.effectiveInspectorPane == .fileChanges)

            // Close and reopen from the toolbar: the remembered pane comes
            // back unpinned, so the empty pane yields to History again.
            window.closeInspector()
            window.toggleInspector()
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.inspectorPanePinned == false)
            #expect(window.effectiveInspectorPane == .history)

            // A deep link pins too, and a new chat on screen clears the pin.
            window.openChangesPanel()
            #expect(window.inspectorPanePinned)
            #expect(window.effectiveInspectorPane == .fileChanges)
            window.startNewChat()
            #expect(window.inspectorPanePinned == false)
            #expect(window.effectiveInspectorPane == .history)
        }
    }

    @Test("on a project the same toggle drives Project Settings, remembered across windows")
    func projectInspectorToggle() async throws {
        let defaults = UserDefaults.standard
        let key = ChatWindowState.projectInspectorDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)

        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.showProjectInspector, "open by default: the settings are what the rail is for")
            // On a chat the rail state is the chat inspector's.
            #expect(window.isRightRailOpen == false)
            window.openProjectId = UUID()
            #expect(window.isRightRailOpen)
            window.toggleProjectInspector()
            #expect(window.showProjectInspector == false)
            #expect(window.isRightRailOpen == false)
            #expect(window.inspectorPane == nil, "the chat inspector is untouched")

            // The choice survives into the next window.
            let next = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { next.cleanup() }
            #expect(next.showProjectInspector == false)

            // Asking for the stepped-aside sidebar back closes the rail on
            // screen, which on a project is Project Settings.
            window.toggleProjectInspector()
            window.isSidebarAutoHidden = true
            window.toggleSidebar()
            #expect(window.showProjectInspector == false)
            #expect(window.showSidebar)
        }
    }

    @Test("the toolbar badge counts changed files only while the rail is closed, for local chats")
    func badgeCount() {
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 0, isInspectorOpen: false, isRemoteAgentChat: false) == nil)
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: false, isRemoteAgentChat: false) == 3)
        #expect(
            ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: true, isRemoteAgentChat: false) == nil,
            "open, the lens bar carries the count")
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: false, isRemoteAgentChat: true) == nil)
    }

    @Test("the rail hides on the project page and keeps its pane for the chat's return")
    func visiblePane() {
        #expect(ChatView.visibleInspectorPane(requested: nil, isProjectPageOpen: false) == nil)
        #expect(ChatView.visibleInspectorPane(requested: .history, isProjectPageOpen: true) == nil)
        #expect(ChatView.visibleInspectorPane(requested: .fileChanges, isProjectPageOpen: false) == .fileChanges)
    }

    @Test("the sidebar steps aside only when both rails plus a readable chat column do not fit")
    func sidebarStepsAside() {
        // 260 sidebar + 440 chat + 300 inspector floor = 1000.
        #expect(ChatView.sidebarStepsAside(windowWidth: 800, sidebarWidth: 260, inspectorOpen: true) == true)
        #expect(ChatView.sidebarStepsAside(windowWidth: 800, sidebarWidth: 260, inspectorOpen: false) == false)
        #expect(ChatView.sidebarStepsAside(windowWidth: 1000, sidebarWidth: 260, inspectorOpen: true) == false)
        // A wider sidebar needs a wider window before both stay up.
        #expect(ChatView.sidebarStepsAside(windowWidth: 1100, sidebarWidth: 400, inspectorOpen: true) == true)
        #expect(ChatView.sidebarStepsAside(windowWidth: 1140, sidebarWidth: 400, inspectorOpen: true) == false)
    }

    @Test("the chrome reports the sidebar actually on screen, and asking for it back closes the inspector")
    func sidebarVisibilityFollowsAutoHide() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.showSidebar)
            #expect(window.isSidebarVisible)

            // Narrow window, inspector open: ChatView reports the step-aside.
            window.toggleInspector()
            window.isSidebarAutoHidden = true
            #expect(window.isSidebarVisible == false)
            #expect(window.showSidebar, "the user's choice is untouched")

            // The toolbar button now reads "Show sidebar"; pressing it must
            // produce a visible sidebar, which means the inspector goes.
            window.toggleSidebar()
            #expect(window.inspectorPane == nil)
            #expect(window.showSidebar)
            window.isSidebarAutoHidden = false  // ChatView follows the closed inspector
            #expect(window.isSidebarVisible)

            // With nothing pushing it aside the toggle is a plain flip.
            window.toggleSidebar()
            #expect(window.showSidebar == false)
            #expect(window.isSidebarVisible == false)
            window.toggleSidebar()
            #expect(window.isSidebarVisible)
        }
    }

    @Test("the inspector keeps the user's width until the chat column would drop below its floor")
    func inspectorWidth() {
        #expect(ChatView.changesPanelWidth(totalWidth: 1400, sidebarWidth: 260, preferredWidth: 380) == 380)
        #expect(ChatView.changesPanelWidth(totalWidth: 1400, sidebarWidth: 260, preferredWidth: 480) == 480)
        // 800pt window, sidebar stepped aside: 800 - 0 - 440 = 360 available.
        #expect(ChatView.changesPanelWidth(totalWidth: 800, sidebarWidth: 0, preferredWidth: 380) == 360)
        // Never narrower than the floor even when the chat column has to give.
        #expect(ChatView.changesPanelWidth(totalWidth: 700, sidebarWidth: 0, preferredWidth: 380) == 300)
        // A stale out-of-range stored width is clamped, like the sidebar's.
        #expect(ChatView.clampInspectorWidth(100) == 300)
        #expect(ChatView.clampInspectorWidth(900) == 520)
        #expect(ChatView.changesPanelWidth(totalWidth: 1400, sidebarWidth: 260, preferredWidth: 900) == 520)
    }
}
