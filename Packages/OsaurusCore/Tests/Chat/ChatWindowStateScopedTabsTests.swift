//
//  ChatWindowStateScopedTabsTests.swift
//  osaurusTests
//
//  The tab strip is scoped per agent: `scopedTabs` shows only the active
//  agent's tabs, tab navigation (adjacent / close / move) stays inside that
//  scope, picking an agent in the sidebar focuses its existing tabs (the
//  one awaiting input first, then the most recently used) and drops a blank
//  tab left behind, and background runs from the `BackgroundTaskManager`
//  registry attach as non-activating tabs of their agent — closing such a
//  tab never stops the run, while closing a finished run's tab dismisses it.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private func makeRegistryTask(
    agentId: UUID,
    title: String,
    status: BackgroundTaskStatus = .running,
    source: SessionSource = .schedule
) -> BackgroundTaskState {
    let id = UUID()
    let context = ExecutionContext(id: id, agentId: agentId, title: title, source: source)
    context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
    return BackgroundTaskState(
        id: id,
        taskTitle: title,
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status,
        currentStep: nil,
        source: source,
        sourcePluginId: nil,
        externalSessionKey: nil,
        showToast: true
    )
}

@Suite(.serialized)
@MainActor
struct ChatWindowStateScopedTabsTests {

    private var mgr: BackgroundTaskManager { BackgroundTaskManager.shared }

    private func makeAgent(_ label: String) -> Agent {
        let agent = Agent(name: "\(label)-\(UUID().uuidString.prefix(6))")
        AgentManager.shared.add(agent)
        return agent
    }

    private func addTurn(_ session: ChatSession, _ text: String) {
        session.turns.append(ChatTurn(role: .user, content: text))
    }

    // MARK: Scope

    @Test func scopedTabs_showOnlyTheActiveAgentsTabs_andBlankOutgoingTabIsDropped() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")
            let defaultTab = window.activeTabId

            window.newTab(agentId: agentB.id)
            #expect(window.activeScope == .local(agentB.id))
            #expect(window.tabs.count == 2)
            #expect(window.scopedTabs.map(\.id) == [window.activeTabId], "only B's tab is in B's strip")

            // Back to Default: its existing tab is focused; B's blank tab
            // is dropped rather than left behind.
            window.switchAgent(to: Agent.defaultId)
            #expect(window.activeTabId == defaultTab)
            #expect(window.tabs.count == 1)
            #expect(window.scopedTabs.map(\.id) == [defaultTab])
        }
    }

    @Test func switchAgent_prefersTabAwaitingInput_thenMostRecentlyUsed() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            // Two B conversations; b1 is used most recently.
            window.newTab(agentId: agentB.id)
            let b1 = window.activeTabId
            addTurn(window.session, "b1")
            window.newTab(agentId: agentB.id)
            let b2 = window.activeTabId
            addTurn(window.session, "b2")
            window.selectTab(id: b1)
            #expect(window.tabs.count == 3)

            window.switchAgent(to: Agent.defaultId)
            #expect(window.activeScope == .local(Agent.defaultId))
            #expect(window.tabs.count == 3, "non-blank tabs are never dropped")

            window.switchAgent(to: agentB.id)
            #expect(window.activeTabId == b1, "most recently used B tab wins")

            // A B tab paused on a clarify prompt outranks recency.
            window.switchAgent(to: Agent.defaultId)
            let b2Session = try #require(window.tabs.first { $0.id == b2 }?.session)
            b2Session.awaitingClarify = ClarifyPayload(question: "which one?")
            window.switchAgent(to: agentB.id)
            #expect(window.activeTabId == b2, "the tab that needs input wins")
            b2Session.awaitingClarify = nil

            // Picking the agent already showing is a no-op.
            window.switchAgent(to: agentB.id)
            #expect(window.activeTabId == b2)
            #expect(window.tabs.count == 3)
        }
    }

    // MARK: Navigation within scope

    @Test func selectAdjacentTab_cyclesWithinTheActiveAgentOnly() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "d1")
            let d1 = window.activeTabId
            window.newTab(agentId: agentB.id)
            addTurn(window.session, "b1")
            let b1 = window.activeTabId
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "d2")
            let d2 = window.activeTabId
            #expect(window.tabs.map(\.id) == [d1, b1, d2])
            #expect(window.scopedTabs.map(\.id) == [d1, d2])

            window.selectAdjacentTab(offset: 1)
            #expect(window.activeTabId == d1, "wraps within Default's tabs, skipping B")
            window.selectAdjacentTab(offset: -1)
            #expect(window.activeTabId == d2)
            window.selectAdjacentTab(offset: 1)
            #expect(window.activeTabId == d1)
        }
    }

    @Test func moveTab_takesAScopedSlot_andKeepsOtherAgentsTabsInPlace() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "d1")
            let d1 = window.activeTabId
            window.newTab(agentId: agentB.id)
            addTurn(window.session, "b1")
            let b1 = window.activeTabId
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "d2")
            let d2 = window.activeTabId

            window.moveTab(id: d2, to: 0)
            #expect(window.scopedTabs.map(\.id) == [d2, d1])
            #expect(window.tabs.map(\.id) == [d2, d1, b1])

            window.moveTab(id: d2, to: 1)
            #expect(window.scopedTabs.map(\.id) == [d1, d2])
            #expect(window.tabs.map(\.id) == [d1, d2, b1])
        }
    }

    @Test func closeTab_picksTheNeighborInScope() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "d1")
            let d1 = window.activeTabId
            window.newTab(agentId: agentB.id)
            addTurn(window.session, "b1")
            let b1 = window.activeTabId
            window.newTab(agentId: Agent.defaultId)
            addTurn(window.session, "d2")
            window.selectTab(id: d1)

            window.closeTab(id: d1)
            #expect(window.tabs.count == 2)
            #expect(window.activeScope == .local(Agent.defaultId), "closing stays with the agent")
            #expect(window.session.turns.first?.content == "d2", "the neighbor is Default's other tab, not B's")
            #expect(window.tabs.contains { $0.id == b1 })
        }
    }

    @Test func closeTab_lastTabOfAgent_withConversation_leavesABlankChatForThatAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")
            window.newTab(agentId: agentB.id)
            addTurn(window.session, "b work")
            let bTab = window.activeTabId

            window.closeTab(id: bTab)

            #expect(window.tabs.count == 2)
            #expect(window.activeTabId != bTab)
            #expect(window.activeScope == .local(agentB.id), "the agent stays selected")
            #expect(window.session.turns.isEmpty, "replaced by a blank chat")
            #expect(window.session.agentId == agentB.id)

            // Closing the lone blank tab is a no-op (⌘W falls through to the window).
            let blank = window.activeTabId
            window.closeTab(id: blank)
            #expect(window.activeTabId == blank)
            #expect(window.tabs.count == 2)
        }
    }

    // MARK: Background runs as tabs

    @Test func attachBackgroundTab_isNonActivating_andLandsInTheRunsAgentScope() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            let activeBefore = window.activeTabId
            let sessionBefore = window.session

            let task = makeRegistryTask(agentId: agentB.id, title: "Nightly digest")
            mgr.registerTaskForTesting(task)
            defer { mgr.finalizeTask(task.id) }

            #expect(window.attachBackgroundTab(for: task))
            #expect(!window.attachBackgroundTab(for: task), "already shown → no duplicate")

            #expect(window.activeTabId == activeBefore, "does not steal focus")
            #expect(window.session === sessionBefore)
            #expect(window.tabs.count == 2)
            #expect(window.scopedTabs.count == 1, "invisible while Default is selected")
            #expect(task.chatSession?.windowState === window)

            window.switchAgent(to: agentB.id)
            #expect(window.session === task.chatSession, "picking B shows the run")
            #expect(window.scopedTabs.count == 1)
            #expect(window.tabs.count == 1, "Default's blank tab was dropped")
        }
    }

    @Test func closingABackgroundRunsTab_unlinksTheViewButKeepsTheRun() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            let task = makeRegistryTask(agentId: agentB.id, title: "Long job")
            mgr.registerTaskForTesting(task)
            defer { mgr.finalizeTask(task.id) }
            window.attachBackgroundTab(for: task)
            let runTab = try #require(window.tabs.first { $0.session === task.chatSession })

            window.closeTab(id: runTab.id)

            #expect(window.tabs.count == 1)
            #expect(mgr.taskState(for: task.id) === task, "the run stays registered")
            #expect(task.status == .running)
            #expect(task.chatSession?.windowState == nil, "view link severed")
            #expect(task.chatSession === runTab.session, "the registry still owns the live session")
        }
    }

    @Test func closingAFinishedRunsTab_dismissesTheTask() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            let task = makeRegistryTask(
                agentId: agentB.id,
                title: "Done job",
                status: .completed(summary: "ok")
            )
            mgr.registerTaskForTesting(task)
            window.attachBackgroundTab(for: task)
            let runTab = try #require(window.tabs.first { $0.session === task.chatSession })

            window.closeTab(id: runTab.id)

            #expect(mgr.taskState(for: task.id) == nil, "closing the tab is the dismiss gesture")
            #expect(window.tabs.count == 1)
        }
    }

    @Test func inboundSharedRun_attachesAsReadOnlyTab_closingMidRunKeepsIt_closingFinishedDismisses()
        async throws
    {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            // A teammate driving agent B: hosted through the shared bridge so
            // the tab appears via the same registration path production uses.
            let bridge = InboundSharedRunBridge.shared
            let context = WorkspaceSessionContext(
                workspaceId: "ws-acme",
                agentAddress: "0xshared",
                callerWallet: "0xcaller",
                callerName: "Alice"
            )
            let handle = bridge.begin(
                runKey: "run-\(UUID())",
                agentId: agentB.id,
                context: context,
                externalKey: "0xcaller:convo-tab",
                requestMessages: [ChatMessage(role: "user", content: "hello")],
                stop: {}
            )
            defer { ChatSessionsManager.shared.delete(id: handle.taskId) }
            let task = try #require(mgr.taskState(for: handle.taskId))
            #expect(window.attachBackgroundTab(for: task), "the hosted run is tab-worthy")
            let runTab = try #require(window.tabs.first { $0.session === task.chatSession })
            #expect(window.tabs.count == 2)
            #expect(window.scopedTabs.count == 1, "lands in B's scope, Default keeps focus")

            window.switchAgent(to: agentB.id)
            #expect(window.session === task.chatSession)
            #expect(
                window.composerLock
                    == .teammateConversation(callerName: "Alice", agentName: agentB.displayName, isWorkspace: true),
                "read-only: the composer is replaced by the hosted-run notice"
            )

            // Turns the host produces land in the visible tab.
            bridge.appendMessages(handle, [ChatMessage(role: "assistant", content: "hi Alice")])
            #expect(window.session.turns.map(\.content) == ["hello", "hi Alice"])

            // Closing mid-run only unlinks the view; the run keeps going.
            window.closeTab(id: runTab.id)
            #expect(mgr.taskState(for: task.id) === task)
            #expect(task.status == .running)
            #expect(task.chatSession?.windowState == nil)

            // It comes back as a tab; closing the FINISHED run dismisses it,
            // but the History row stays.
            bridge.finish(handle, success: true, summary: "Completed")
            #expect(window.attachBackgroundTab(for: task))
            let again = try #require(window.tabs.first { $0.session === task.chatSession })
            window.closeTab(id: again.id)
            #expect(mgr.taskState(for: task.id) == nil, "closing the finished tab is the dismiss gesture")
            #expect(ChatSessionStore.load(id: handle.taskId)?.turns.count == 2)
            #expect(ChatSessionsManager.shared.sessions(for: agentB.id).contains { $0.id == handle.taskId })
        }
    }

    @Test func focusTab_bringsARunsTabForward() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            addTurn(window.session, "default work")

            let task = makeRegistryTask(agentId: Agent.defaultId, title: "Same agent run", source: .http)
            mgr.registerTaskForTesting(task)
            defer { mgr.finalizeTask(task.id) }
            window.attachBackgroundTab(for: task)
            #expect(window.scopedTabs.count == 2, "same agent: the run shows beside the chat")
            #expect(window.session !== task.chatSession)

            #expect(window.focusTab(forSessionId: task.id))
            #expect(window.session === task.chatSession)
            #expect(!window.focusTab(forSessionId: UUID()))
        }
    }
}
