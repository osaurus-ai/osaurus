//
//  ChatWindowStateIdentityTests.swift
//  osaurusTests
//
//  Pins `ChatWindowState.effectiveChatIdentity` — the identity that heads the
//  chat thread / empty state. The bug it fixes: a Mode 2 (remote agent)
//  conversation used to render the LOCAL agent's name ("Osaurus") and avatar in
//  the message thread. The identity must switch to the remote agent's name +
//  fetched mascot when a discovered/relay agent is selected, and fall back to
//  the local active agent otherwise.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateIdentityTests {

    private func makeCustomAgent(name: String, avatar: String?) -> Agent {
        Agent(
            name: "\(name)-\(UUID().uuidString.prefix(6))",
            systemPrompt: "identity",
            agentAddress: "test-identity-\(UUID().uuidString)",
            avatar: avatar
        )
    }

    // MARK: - Local (Mode 0)

    @Test("local agent → identity uses local name + avatar, isRemote false")
    func localIdentity_usesActiveAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "LocalCoder", avatar: "blue")
            AgentManager.shared.add(custom)

            let window = ChatWindowState(windowId: UUID(), agentId: custom.id)
            let identity = window.effectiveChatIdentity

            #expect(identity.isRemote == false)
            #expect(identity.name == custom.name)
            #expect(identity.mascotId == "blue")

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    // MARK: - Remote (Mode 2)

    @Test("discovered agent selected → identity uses remote name + pinned mascot, isRemote true")
    func remoteIdentity_usesDiscoveredAgent() async throws {
        try await ChatHistoryTestStorage.run {
            // Window opens on the local Default agent...
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            #expect(window.effectiveChatIdentity.isRemote == false)

            // ...then a discovered remote agent is selected and its mascot pinned
            // from live metadata (Mode 2). The thread identity must follow it.
            let discovered = DiscoveredAgent(
                id: UUID(),
                name: "Coco",
                agentDescription: "A friendly remote helper",
                address: "remote-addr",
                host: "127.0.0.1",
                resolvedIP: nil,
                port: 1234,
                supportsSecureChannel: true,
                serviceName: "coco._osaurus._tcp."
            )
            window.selectedDiscoveredAgent = discovered
            window.selectedDiscoveredAgentProviderId = UUID()
            window.pinnedRemoteAgentAvatar = "green"

            let identity = window.effectiveChatIdentity
            #expect(identity.isRemote == true)
            #expect(identity.name == "Coco")
            #expect(identity.mascotId == "green")
            // Remote agents never transfer a custom image — mascot/monogram only.
            #expect(identity.customAvatarPath == nil)
        }
    }

    @Test("remote selected without resolved peer → falls back to a remote label, never the local one")
    func remoteIdentity_fallsBackToRemoteLabel() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let localName = window.effectiveChatIdentity.name

            // Provider id set but no discovered/relay agent resolved yet (pure
            // ephemeral selection mid-connect): the identity must still report
            // remote — not silently fall through to the local "Osaurus" label.
            window.selectedDiscoveredAgentProviderId = UUID()
            window.pinnedRemoteAgentAvatar = nil

            let identity = window.effectiveChatIdentity
            #expect(identity.isRemote == true)
            #expect(identity.name != localName)
            #expect(identity.mascotId == nil)
        }
    }
}
