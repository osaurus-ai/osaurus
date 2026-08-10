//
//  ChatSessionDispatchModelTests.swift
//  osaurusTests
//
//  Pins the model contract for headless dispatched runs (channel /
//  schedule / HTTP / plugin): each dispatch follows the agent's CURRENT
//  default model, overriding the model persisted on a reattached
//  conversation session. The persisted model is only a fallback when the
//  agent's default isn't available in the picker, and window chats
//  (`source == .chat`) are never overridden — a manual pick must survive.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionDispatchModelTests {

    private func localItem(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }

    /// Agent with a configured default model. Callers must run `cleanup`.
    private func makeAgent(defaultModel: String) -> (agent: Agent, cleanup: () async -> Void) {
        let agent = Agent(name: "Dispatch Model Test Agent \(UUID().uuidString)")
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: defaultModel)
        return (agent, { _ = await AgentManager.shared.delete(id: agent.id) })
    }

    /// Drain the session's initial `ModelPickerItemCache.$items` snapshot
    /// application (queued as a main-actor task at init) so it can't clobber
    /// the items a test applies afterwards.
    private func drainInitialCacheSnapshot() async {
        for _ in 0 ..< 3 { await Task.yield() }
    }

    /// Mirror `ExecutionContext`'s reattach flow: picker items load first,
    /// then the persisted conversation (with its saved model) is restored.
    private func makeReattachedSession(
        agentId: UUID,
        source: SessionSource,
        persistedModel: String,
        items: [ModelPickerItem]
    ) async -> ChatSession {
        let session = ChatSession()
        session.agentId = agentId
        await drainInitialCacheSnapshot()
        session.applyPickerItems(items)
        session.load(
            from: ChatSessionData(
                selectedModel: persistedModel,
                agentId: agentId,
                source: source
            )
        )
        return session
    }

    /// A channel conversation that persisted an older model switches to the
    /// agent's current default on the next dispatch.
    @Test func channelDispatchAdoptsAgentCurrentDefault() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/new-default")
        let session = await makeReattachedSession(
            agentId: agent.id,
            source: .channel,
            persistedModel: "mlx-test/old-model",
            items: [localItem("mlx-test/old-model"), localItem("mlx-test/new-default")]
        )
        #expect(session.selectedModel == "mlx-test/old-model")

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/new-default")
        await cleanup()
    }

    /// When the agent's default isn't in the picker (remote catalog still
    /// loading, model uninstalled), the persisted conversation model stays —
    /// the override must never leave the session without a usable model.
    @Test func unavailableAgentDefaultKeepsPersistedModel() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/uninstalled-default")
        let session = await makeReattachedSession(
            agentId: agent.id,
            source: .channel,
            persistedModel: "mlx-test/old-model",
            items: [localItem("mlx-test/old-model")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/old-model")
        await cleanup()
    }

    /// Window chats are exempt: a user's manual model pick in an open chat
    /// must not be snapped back to the agent default.
    @Test func windowChatSelectionIsNeverOverridden() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/new-default")
        let session = await makeReattachedSession(
            agentId: agent.id,
            source: .chat,
            persistedModel: "mlx-test/manual-pick",
            items: [localItem("mlx-test/manual-pick"), localItem("mlx-test/new-default")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/manual-pick")
        await cleanup()
    }

    /// Non-channel headless sources (schedules, HTTP dispatch) get the same
    /// agent-default-wins behavior.
    @Test func scheduleDispatchAdoptsAgentCurrentDefault() async {
        let (agent, cleanup) = makeAgent(defaultModel: "mlx-test/new-default")
        let session = await makeReattachedSession(
            agentId: agent.id,
            source: .schedule,
            persistedModel: "mlx-test/old-model",
            items: [localItem("mlx-test/old-model"), localItem("mlx-test/new-default")]
        )

        session.applyAgentDefaultModelForDispatch()

        #expect(session.selectedModel == "mlx-test/new-default")
        await cleanup()
    }
}
