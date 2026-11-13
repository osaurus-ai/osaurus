//
//  ChatWindowStateInspectorTests.swift
//  osaurusTests
//
//  The chat window's right-hand rail mirrors the session sidebar: it shows
//  the chat's File Changes and only exists once the chat has changed a
//  file, one toolbar button opens and closes it, "N files changed" rows
//  deep-link to it, the toolbar badge counts changed files only while the
//  rail is closed, and at narrow widths the two rails take turns rather
//  than crushing the chat column.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateInspectorTests {

    @Test("File Changes is asked for from the start and appears with the chat's first change")
    func panelFollowsFileChanges() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.inspectorPane == .fileChanges)
            #expect(window.hasContextPanel == false)
            #expect(window.isContextPanelOpen == false, "no file changes: no panel")

            window.setFileChangeCountsForTesting(files: 1, sets: 1)
            #expect(window.hasContextPanel)
            #expect(window.isContextPanelOpen, "the first change brings the panel up")

            window.toggleContextPanel()
            #expect(window.inspectorPane == nil)
            #expect(window.isContextPanelOpen == false)
            #expect(window.hasContextPanel, "the toggle stays to bring it back")
            window.toggleContextPanel()
            #expect(window.isContextPanelOpen)
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

    @Test("showing switches panes in place and never closes")
    func showSwitchesInPlace() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.showInspector(.workflows)
            window.showInspector(.fileChanges)
            #expect(window.inspectorPane == .fileChanges)
            window.showInspector(.fileChanges)
            #expect(window.inspectorPane == .fileChanges, "re-selecting the open pane keeps it open")
            window.showInspector(.workflows)
            #expect(window.inspectorPane == .workflows)
        }
    }

    @Test("opening the changes panel shows File Changes focused on the set, even over Workflows")
    func openChangesPanelFocusesSet() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let setId = UUID()

            window.showInspector(.workflows)
            window.openChangesPanel(focusing: setId)
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.changesPanelFocusSetId == setId)

            // Re-opening without a focus clears the stale focus.
            window.openChangesPanel()
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.changesPanelFocusSetId == nil)
        }
    }

    @Test("the context panel draws File Changes only while asked for and the chat has a change")
    func contextPaneRules() {
        #expect(ChatWindowState.contextPane(requested: .fileChanges, fileChangeSetCount: 0, isArchitect: false) == nil)
        #expect(ChatWindowState.contextPane(requested: .fileChanges, fileChangeSetCount: 2, isArchitect: false) == .fileChanges)
        #expect(ChatWindowState.contextPane(requested: nil, fileChangeSetCount: 2, isArchitect: false) == nil)
        #expect(
            ChatWindowState.contextPane(requested: .draft, fileChangeSetCount: 2, isArchitect: false) == .fileChanges,
            "any request counts: visiting the Architect never hides the next chat's File Changes")
        #expect(ChatWindowState.contextPane(requested: .workflows, fileChangeSetCount: 2, isArchitect: false) == .fileChanges)
        #expect(
            ChatWindowState.contextPane(requested: .fileChanges, fileChangeSetCount: 2, isArchitect: true) == nil,
            "the Architect's draft lives in the Workflows split")
    }

    @Test("a new chat hides the panel until its first change; closing it sticks across chats")
    func panelAcrossChats() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.setFileChangeCountsForTesting(files: 2, sets: 2)
            #expect(window.isContextPanelOpen)
            window.startNewChat()
            #expect(window.isContextPanelOpen == false, "a fresh chat has no changes")
            #expect(window.inspectorPane == .fileChanges, "still asked for, for its first change")

            window.setFileChangeCountsForTesting(files: 1, sets: 1)
            window.toggleContextPanel()
            window.startNewChat()
            window.setFileChangeCountsForTesting(files: 1, sets: 1)
            #expect(window.isContextPanelOpen == false, "closed by the user stays closed")
        }
    }

    @Test("the toolbar badge counts changed files only while the rail is closed, for local chats")
    func badgeCount() {
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 0, isInspectorOpen: false, isRemoteAgentChat: false) == nil)
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: false, isRemoteAgentChat: false) == 3)
        #expect(
            ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: true, isRemoteAgentChat: false) == nil,
            "open, the panel carries the count")
        #expect(ChatWindowState.inspectorBadgeCount(fileChangesCount: 3, isInspectorOpen: false, isRemoteAgentChat: true) == nil)
    }

    @Test("Architect chats swap File Changes for the draft; other chats have no Draft")
    func architectPanes() {
        #expect(ChatWindowState.effectiveInspectorPane(requested: .fileChanges, isArchitect: true) == .draft)
        #expect(ChatWindowState.effectiveInspectorPane(requested: .draft, isArchitect: false) == .workflows)
        #expect(ChatWindowState.effectiveInspectorPane(requested: nil, isArchitect: true) == nil)
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

    @Test("picking a workflow opens its run in Workflows, run by the same agent; Architect chats keep the Workflows lens")
    func workflowsLensKeepsTheAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let tabs = window.tabs.count

            window.showInspector(.workflows)
            #expect(window.effectiveInspectorPane == .workflows)
            let workflowID = UUID()
            window.openWorkflowTab(workflowID: workflowID, agentId: window.agentId)
            #expect(window.tabs.count == tabs)
            #expect(window.mainSurface == .workflows)
            #expect(window.workflowsPath.last == .run(workflowID: workflowID, runID: nil, agentId: Agent.defaultId))
            #expect(window.agentId == Agent.defaultId)

            let architect = ChatWindowState(windowId: UUID(), agentId: Agent.architectId)
            defer { architect.cleanup() }
            architect.showInspector(.workflows)
            #expect(architect.effectiveInspectorPane == .workflows)
        }
    }

    @Test("in an Architect chat, picking a workflow edits it there; New Workflow reuses an untouched chat")
    func architectWorkflowsLensEditsInPlace() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let drafts = WorkflowDraftStore.shared
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.architectId)
            defer { window.cleanup() }
            let tabs = window.tabs.count

            window.showInspector(.workflows)
            ArchitectLauncher.edit(installed, in: window)
            let draft = try #require(drafts.draft(forSession: window.session.sessionId?.uuidString))
            defer { drafts.delete(draft.id) }
            #expect(window.effectiveInspectorPane == .draft, "picking a workflow shows its draft")
            #expect(window.agentId == Agent.architectId)
            #expect(window.tabs.count == tabs, "a blank Architect chat is reused")
            #expect(draft.templateID == installed.templateID)
            #expect(draft.baseVersion == installed.templateVersion)
            #expect(draft.definition == installed.definition)
            #expect(
                draft.pendingUserEdits.contains { $0.contains(installed.name) }, "The Architect hears what it edits")

            window.showInspector(.workflows)
            ArchitectLauncher.edit(installed, in: window)
            #expect(window.tabs.count == tabs)
            #expect(drafts.draft(forSession: window.session.sessionId?.uuidString)?.id == draft.id, "already editing it")
            #expect(window.effectiveInspectorPane == .draft, "picking the one it edits still shows the draft")

            window.showInspector(.workflows)
            ArchitectLauncher.newWorkflow(in: window)
            #expect(window.effectiveInspectorPane == .draft)
            #expect(window.tabs.count == tabs)
            #expect(drafts.draft(id: draft.id) == nil, "the untouched draft goes with the reused chat")
            let fresh = try #require(drafts.draft(forSession: window.session.sessionId?.uuidString))
            defer { drafts.delete(fresh.id) }
            #expect(fresh.templateID == nil)
        }
    }

    @Test("editing a workflow opens the Architect chat that built it, history and all, on the saved version")
    func architectEditReopensTheChatThatBuiltIt() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let drafts = WorkflowDraftStore.shared

            let chat = ChatSessionData(
                title: "Build client intake",
                turns: [ChatTurnData(role: .user, content: "build me a client intake workflow")],
                agentId: Agent.architectId)
            ChatSessionsManager.shared.save(chat)
            var older = installed.template
            older.version = installed.templateVersion - 1
            older.payload = .workflow(WorkflowDefinition())
            let built = drafts.create(sessionID: chat.id.uuidString, from: older)
            defer { drafts.delete(built.id) }

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.architectId)
            defer { window.cleanup() }
            ArchitectLauncher.edit(installed, in: window)
            let untouched = drafts.drafts(templateID: installed.templateID).filter { $0.id != built.id }
            defer { untouched.forEach { drafts.delete($0.id) } }

            #expect(window.session.sessionId == chat.id, "the chat that built it opens")
            #expect(window.session.turns.count == 1, "with its history")
            let reopened = try #require(drafts.draft(id: built.id))
            #expect(reopened.baseVersion == installed.templateVersion, "brought up to the saved version")
            #expect(reopened.definition == installed.definition)
            #expect(!reopened.history.isEmpty, "undo restores what the draft held")
            #expect(untouched.isEmpty, "no second draft for the same workflow")

            ArchitectLauncher.newWorkflow(in: window)
            let fresh = try #require(drafts.draft(forSession: window.session.sessionId?.uuidString))
            defer { drafts.delete(fresh.id) }
            #expect(window.session.sessionId != chat.id)
            #expect(drafts.draft(id: built.id) != nil, "a chat with history keeps its draft")
        }
    }

    @Test("only the Architect opens the inspector, and only when it is closed; leaving it never closes the rail")
    func agentChangesNeverToggleTheInspector() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.closeInspector()

            window.openInspectorForArchitect()
            #expect(window.inspectorPane == nil, "other agents leave the rail as it is")

            window.switchAgent(to: Agent.architectId)
            window.openInspectorForArchitect()
            #expect(window.effectiveInspectorPane == .draft, "the Architect opens on its draft")

            window.switchAgent(to: Agent.defaultId)
            window.openInspectorForArchitect()
            #expect(window.isInspectorOpen, "leaving the Architect keeps the rail open")
            #expect(window.effectiveInspectorPane == .workflows, "other agents have no Draft lens")

            window.showInspector(.fileChanges)
            window.switchAgent(to: Agent.architectId)
            window.openInspectorForArchitect()
            #expect(window.inspectorPane == .fileChanges, "an open rail keeps the pane the user picked")
        }
    }

    @Test("the chrome reports the sidebar actually on screen, and asking for it back closes the inspector")
    func sidebarVisibilityFollowsAutoHide() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            #expect(window.showSidebar)
            #expect(window.isSidebarVisible)

            // Narrow window, inspector open: ChatView reports the step-aside.
            window.showInspector(.fileChanges)
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

    @Test("the tab strip stops at the chat column: inset by each rail less the chrome already beside it")
    func tabStripInsetsFollowTheRails() async throws {
        // Sidebar 260 with the 76pt sidebar-button chrome ahead of the strip.
        #expect(ChatTabStripView.leadingInset(sidebarWidth: 260, chromeWidth: 76) == 184)
        // Mid-drag the strip follows the LIVE on-screen width, not the
        // persisted one, so every value in the range is a valid input.
        #expect(ChatTabStripView.leadingInset(sidebarWidth: 333, chromeWidth: 76) == 257)
        // Never negative: a rail narrower than its chrome needs no inset.
        #expect(ChatTabStripView.leadingInset(sidebarWidth: 60, chromeWidth: 76) == 0)
        // Hidden or stepped aside for the inspector: ChatView reports 0 and
        // the tabs return to the window's left edge.
        #expect(ChatTabStripView.leadingInset(sidebarWidth: 0, chromeWidth: 76) == 0)

        // Inspector closed: nothing to clear.
        #expect(ChatTabStripView.trailingInset(inspectorWidth: 0, chromeWidth: 80) == 0)
        // Inspector at its 380 default with the pin / toggle chrome after the strip.
        #expect(ChatTabStripView.trailingInset(inspectorWidth: 380, chromeWidth: 80) == 300)
        // Squeezed to its 300 floor at a narrow window.
        #expect(ChatTabStripView.trailingInset(inspectorWidth: 300, chromeWidth: 80) == 220)
        #expect(ChatTabStripView.trailingInset(inspectorWidth: 50, chromeWidth: 80) == 0)

        // A fresh window has no rail on screen until ChatView lays one out:
        // both widths come from its geometry, never from the defaults key.
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.inspectorColumnWidth == 0)
            #expect(window.sidebarColumnWidth == 0)
        }
    }

    // MARK: - Responsive shell

    @Test("a compact window toggles a drawer and never rewrites the docked sidebar choice")
    func compactDrawer() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.showSidebar)

            window.updateShellBreakpoint(.compact)
            #expect(window.isCompactSidebarPresented == false, "the drawer starts closed")
            #expect(window.isSidebarVisible == false)

            window.toggleSidebar()
            #expect(window.isCompactSidebarPresented)
            #expect(window.isSidebarVisible)
            #expect(window.showSidebar, "docked choice untouched")

            window.toggleSidebar()
            #expect(window.isCompactSidebarPresented == false)
            #expect(window.showSidebar)

            // Widening closes the drawer and the docked sidebar returns.
            window.toggleSidebar()
            window.updateShellBreakpoint(.regular)
            #expect(window.isCompactSidebarPresented == false)
            #expect(window.isSidebarVisible)
        }
    }

    @Test("compact shows one overlay at a time, and Esc closes the drawer before the context panel")
    func compactOverlaysAreExclusive() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.dismissShellOverlay() == false, "nothing to dismiss outside compact")
            window.setFileChangeCountsForTesting(files: 1, sets: 1)

            window.updateShellBreakpoint(.compact)
            window.toggleSidebar()
            window.toggleContextPanel()
            #expect(window.isContextPanelOpen)
            #expect(window.isCompactSidebarPresented == false, "the context overlay replaces the drawer")

            window.toggleSidebar()
            #expect(window.isCompactSidebarPresented)
            #expect(window.inspectorPane == nil, "the drawer replaces the context overlay")

            window.inspectorPane = .fileChanges
            window.isCompactSidebarPresented = true
            #expect(window.dismissShellOverlay())
            #expect(window.isCompactSidebarPresented == false)
            #expect(window.inspectorPane == .fileChanges)
            #expect(window.dismissShellOverlay())
            #expect(window.inspectorPane == nil)
            #expect(window.dismissShellOverlay() == false)
        }
    }

    @Test("narrowing into compact closes a docked context panel; widening brings it back")
    func enteringCompactClosesContext() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.setFileChangeCountsForTesting(files: 1, sets: 1)
            window.updateShellBreakpoint(.wide)
            #expect(window.isContextPanelOpen)
            window.updateShellBreakpoint(.regular)
            #expect(window.isContextPanelOpen, "regular still docks")
            window.updateShellBreakpoint(.compact)
            #expect(window.isContextPanelOpen == false, "no overlay opens on its own")
            window.updateShellBreakpoint(.regular)
            #expect(window.isContextPanelOpen, "widening brings the docked panel back")

            window.toggleContextPanel()
            window.updateShellBreakpoint(.compact)
            window.updateShellBreakpoint(.wide)
            #expect(window.isContextPanelOpen == false, "a panel the user closed stays closed")
        }
    }

    @Test("the context toggle works from what is drawn, whatever pane was asked for")
    func contextToggleFromHiddenPane() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.setFileChangeCountsForTesting(files: 1, sets: 1)
            window.showInspector(.workflows)
            #expect(window.isContextPanelOpen, "the chat surface shows File Changes for any request")
            window.toggleContextPanel()
            #expect(window.inspectorPane == nil)
            window.toggleContextPanel()
            #expect(window.inspectorPane == .fileChanges)
        }
    }
}
