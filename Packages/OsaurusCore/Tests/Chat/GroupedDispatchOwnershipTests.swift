import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct GroupedDispatchOwnershipTests {
    private func stored(agentId: UUID, source: SessionSource) -> ChatSessionData {
        let id = UUID()
        return ChatSessionData(
            id: id,
            title: "Grouped ownership",
            turns: [ChatTurnData(role: .user, content: "first"), ChatTurnData(role: .assistant, content: "answer")],
            agentId: agentId,
            source: source,
            sourcePluginId: source == .plugin ? "test.grouped" : nil,
            externalSessionKey: "group-\(id)",
            dispatchTaskId: id
        )
    }

    private func request(_ data: ChatSessionData) -> DispatchRequest {
        DispatchRequest(
            prompt: "next",
            agentId: data.agentId,
            showToast: false,
            sourcePluginId: data.sourcePluginId,
            source: data.source,
            externalSessionKey: data.externalSessionKey,
            loadIntent: .background
        )
    }

    @Test(arguments: [SessionSource.schedule, .watcher, .http, .plugin, .delegation], [false, true])
    func lookupReusesActiveOrInactiveWindowOwner(source: SessionSource, inactive: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let data = stored(agentId: UUID(), source: source)
            ChatSessionStore.save(data)
            let window = ChatWindowState(windowId: UUID(), agentId: data.agentId!, sessionData: data)
            defer { window.cleanup() }
            let original = window.session
            original.turns.append(ChatTurn(role: .user, content: "newer unsaved live turn"))
            if inactive { window.newTab() }
            try ChatWindowManager.shared.withRegisteredWindowStateForTesting(window) {
                let manager = BackgroundTaskManager.makeForTesting()
                let candidate = try #require(manager.lookupReattachableSession(for: request(data)))
                #expect(candidate.live === original)
                let context = ExecutionContext(reattaching: candidate.data, reusing: candidate.live)
                #expect(context.chatSession === original)
                #expect(original.turns.last?.content == "newer unsaved live turn")
                context.chatSession.turns.append(ChatTurn(role: .assistant, content: "new dispatch result"))
                context.chatSession.save()
                window.cleanup()
                #expect(
                    ChatSessionStore.load(id: data.id)?.turns.map(\.content)
                        == ["first", "answer", "newer unsaved live turn", "new dispatch result"]
                )
            }
        }
    }

    @Test(arguments: [false, true])
    func prepareNeverRehydratesTranscriptOrDraft(reuseLive: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let data = stored(agentId: UUID(), source: .delegation)
            let live = ChatSession()
            live.load(from: data)
            let budget = DelegatedRunContract(responseTokens: 128, assistantTurns: 2, contextPositions: 2048)
            let context = ExecutionContext(
                reattaching: data,
                reusing: reuseLive ? live : nil,
                loadIntent: .background,
                delegationBudget: budget,
                delegationModel: "priced-child"
            )
            let session = context.chatSession
            session.turns.append(ChatTurn(role: .user, content: "arrived before preparation"))
            session.input = "unsent draft"
            await context.prepare()
            #expect(session.turns.last?.content == "arrived before preparation")
            #expect(session.input == "unsent draft")
            #expect(session.loadIntent == .background)
            #expect(session.delegationBudget == budget)
            #expect(session.delegationModel == "priced-child")
        }
    }

    @Test(arguments: ["streaming", "clarify", "compaction"])
    func busyLiveOwnerIsNotReattached(kind: String) async throws {
        try await ChatHistoryTestStorage.run {
            let data = stored(agentId: UUID(), source: .schedule)
            ChatSessionStore.save(data)
            let live = ChatSession()
            live.load(from: data)
            LiveChatSessionRegistry.shared.register(live, id: data.id)
            defer {
                LiveChatSessionRegistry.shared.unregister(id: data.id)
                live.isStreaming = false
                live.awaitingClarify = nil
                live.compactionState = .idle
            }
            switch kind {
            case "streaming": live.isStreaming = true
            case "clarify": live.awaitingClarify = ClarifyPayload(question: "which?")
            default: live.compactionState = .running(.summarizing)
            }
            #expect(BackgroundTaskManager.makeForTesting().lookupReattachableSession(for: request(data)) == nil)
            #expect(live.turns.count == 2)
        }
    }

    @Test
    func dispatchReservesOwnerBeforePreparationAndHonorsCancellation() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Agent(name: "Grouped dispatch test", autonomousExec: AutonomousExecConfig(enabled: false))
            AgentManager.shared.add(agent)
            let data = stored(agentId: agent.id, source: .schedule)
            ChatSessionStore.save(data)
            let live = ChatSession()
            live.load(from: data)
            live.input = "retain this draft"
            LiveChatSessionRegistry.shared.register(live, id: data.id)
            defer { LiveChatSessionRegistry.shared.unregister(id: data.id) }
            let manager = BackgroundTaskManager.makeForTesting()
            defer { manager.finalizeTask(data.id) }
            // The registration callback runs synchronously, before preparation.
            // Cancel there: no prompt or generation may be started afterwards.
            var registrations = 0
            let subscriber = manager.taskRegistered.sink { state in
                registrations += 1
                #expect(state.chatSession === live)
                #expect(manager.lookupReattachableSession(for: request(data)) == nil)
                manager.cancelTask(state.id)
            }
            defer { subscriber.cancel() }
            let visibleRequest = DispatchRequest(
                prompt: "must not start",
                agentId: agent.id,
                source: .schedule,
                externalSessionKey: data.externalSessionKey
            )
            let handle = await manager.dispatchChat(visibleRequest)
            #expect(handle?.id == data.id)
            #expect(registrations == 1)
            #expect(manager.backgroundTasks[data.id]?.status == .cancelled)
            #expect(live.turns.map(\.content) == ["first", "answer"])
            #expect(live.input == "retain this draft")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test
    func repeatedRunDoesNotInheritTerminalObserverOrTimer() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = BackgroundTaskManager.makeForTesting()
            let context = ExecutionContext(agentId: UUID(), source: .schedule)
            @MainActor func state() -> BackgroundTaskState {
                BackgroundTaskState(
                    id: context.id,
                    taskTitle: "repeat",
                    agentId: context.agentId,
                    chatSession: context.chatSession,
                    executionContext: context,
                    status: .running,
                    currentStep: "Running"
                )
            }
            defer { manager.finalizeTask(context.id) }
            let first = state()
            manager.registerTaskThroughProductionPathForTesting(first)
            manager.observeChatTask(first, session: context.chatSession)
            context.chatSession.isStreaming = true
            context.chatSession.isStreaming = false
            #expect(first.status.isTerminal)
            #expect(manager.hasPendingAutoFinalizeForTesting(context.id))
            let second = state()
            manager.registerTaskThroughProductionPathForTesting(second)
            manager.observeChatTask(second, session: context.chatSession)
            #expect(second.status == .running)
            #expect(!manager.hasPendingAutoFinalizeForTesting(context.id))
            context.chatSession.isStreaming = true
            context.chatSession.isStreaming = false
            #expect(second.status.isTerminal)
        }
    }
}
