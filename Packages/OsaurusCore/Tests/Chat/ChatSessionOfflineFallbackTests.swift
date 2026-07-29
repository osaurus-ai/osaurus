//
//  ChatSessionOfflineFallbackTests.swift
//  osaurusTests
//
//  Pins the chat side of connectivity-driven offline mode: when the network
//  drops, `RemoteProviderManager` hides remote models from the picker source
//  and every session's `applyPickerItems` reconciliation falls the selection
//  back to an on-device chat model; when connectivity returns and remote
//  entries reappear, the agent's cloud default is restored automatically.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionOfflineFallbackTests {

    private func makeLocalItem() -> ModelPickerItem {
        ModelPickerItem(
            id: "mlx-test/local-chat",
            displayName: "Local Chat",
            source: .local
        )
    }

    private func makeRouterItem() -> ModelPickerItem {
        ModelPickerItem(
            id: "osaurus/deepseek-ai/deepseek-v4-flash",
            displayName: "Cloud Model",
            source: .remote(
                providerName: "Osaurus",
                providerId: RemoteProviderManager.osaurusRouterProviderId
            )
        )
    }

    /// Drain the session's initial `ModelPickerItemCache.$items` snapshot
    /// application (queued as a main-actor task at init) so it can't clobber
    /// the items the test applies afterwards.
    private func drainInitialCacheSnapshot() async {
        for _ in 0 ..< 3 { await Task.yield() }
    }

    /// Offline removes remote picker entries → the session falls back to the
    /// local chat model. Recovery restores the remote entries → the agent's
    /// cloud default is re-selected (the offline fallback never overwrote it).
    @Test func offlineRemovesRemoteSelection_recoveryRestoresIt() async {
        let local = makeLocalItem()
        let remote = makeRouterItem()

        let agent = Agent(name: "Offline Fallback Agent \(UUID().uuidString)")
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: remote.id)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let session = ChatSession()
        session.agentId = agent.id
        await drainInitialCacheSnapshot()

        // Online: the agent's cloud default is available and selected.
        session.applyPickerItems([local, remote])
        #expect(session.selectedModel == remote.id)

        // Offline rebuild: remote entries are gone → fall back to the local
        // chat model, never leaving the session without a model.
        session.applyPickerItems([local])
        #expect(session.selectedModel == local.id)

        // The fallback is session-only: the agent's durable default must
        // still be the cloud model so recovery can restore it.
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == remote.id)

        // Recovery rebuild: the cloud default reappears and wins again.
        session.applyPickerItems([local, remote])
        #expect(session.selectedModel == remote.id)
    }
}
