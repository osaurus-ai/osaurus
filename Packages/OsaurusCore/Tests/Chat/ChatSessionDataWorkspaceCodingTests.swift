//
//  ChatSessionDataWorkspaceCodingTests.swift
//  osaurusTests
//
//  Pins the workspace identity a persisted chat session can carry:
//  `WorkspaceSessionContext` round-trips through `ChatSessionData`'s
//  Codable, legacy rows without the field still decode, the conversation
//  store keeps it, and `ChatSessionsManager` keys teammate-agent chats by
//  address instead of by the local agent that hosted the tab.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatSessionDataWorkspaceCodingTests {

    private static let address = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01"

    private func makeSession(
        workspace: WorkspaceSessionContext?,
        agentId: UUID? = nil,
        source: SessionSource = .chat
    ) -> ChatSessionData {
        ChatSessionData(
            id: UUID(),
            title: "Team chat",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: [
                ChatTurnData(role: .user, content: "hello"),
                ChatTurnData(role: .assistant, content: "hi"),
            ],
            agentId: agentId,
            source: source,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil,
            workspace: workspace
        )
    }

    // MARK: - WorkspaceSessionContext

    @Test func context_lowercasesAddressesAndDerivesCallerLabel() {
        let teammateSide = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
        #expect(teammateSide.agentAddress == Self.address.lowercased())
        #expect(teammateSide.isServedForTeammate == false)
        #expect(teammateSide.callerLabel == nil)

        let named = WorkspaceSessionContext(
            workspaceId: "ws-1",
            agentAddress: Self.address,
            callerWallet: "0xCALLER00000000000000000000000000000000AA",
            callerName: "Alice"
        )
        #expect(named.isServedForTeammate)
        #expect(named.callerWallet == "0xcaller00000000000000000000000000000000aa")
        #expect(named.callerLabel == "0xcall…00aa")

        let handled = WorkspaceSessionContext(
            workspaceId: "ws-1",
            agentAddress: Self.address,
            callerWallet: "0xCALLER00000000000000000000000000000000AA",
            callerName: "Alice",
            callerHandle: "alice"
        )
        #expect(handled.callerLabel == "@alice")

        let unnamed = WorkspaceSessionContext(
            workspaceId: "ws-1",
            agentAddress: Self.address,
            callerWallet: "0xCALLER00000000000000000000000000000000AA"
        )
        #expect(unnamed.callerLabel == "0xcall…00aa")
    }

    @Test func context_jsonColumnCodecRoundTrips() throws {
        let context = WorkspaceSessionContext(
            workspaceId: "ws-9",
            agentAddress: Self.address,
            callerWallet: "0xcaller",
            callerName: "Bob"
        )
        let json = try #require(context.encodedJSON())
        #expect(json.contains("\"workspaceId\":\"ws-9\""))
        #expect(WorkspaceSessionContext.decode(json: json) == context)
        #expect(WorkspaceSessionContext.decode(json: nil) == nil)
        #expect(WorkspaceSessionContext.decode(json: "") == nil)
        #expect(WorkspaceSessionContext.decode(json: "not json") == nil)
    }

    // MARK: - ChatSessionData Codable

    @Test func sessionData_roundTripsWorkspaceContext() throws {
        let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
        let original = makeSession(workspace: context)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)

        #expect(decoded.workspace == context)
        #expect(decoded.remoteAgentAddress == Self.address.lowercased())
        #expect(decoded.isWorkspaceAgentChat)
    }

    @Test func sessionData_legacyPayloadWithoutWorkspaceDecodesAsLocal() throws {
        // A row written before the field existed: no `workspace` key at all.
        let legacy = makeSession(workspace: nil)
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        payload.removeValue(forKey: "workspace")
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)
        #expect(decoded.workspace == nil)
        #expect(decoded.remoteAgentAddress == nil)
        #expect(decoded.isWorkspaceAgentChat == false)
    }

    @Test func sessionData_hostServedRowIsNotATeammateAgentChat() {
        // Host side: served FOR a teammate → stays under the local shared
        // agent (not filtered out of its list), even though it has an address.
        let served = makeSession(
            workspace: WorkspaceSessionContext(
                workspaceId: "ws-1",
                agentAddress: Self.address,
                callerWallet: "0xcaller",
                callerName: "Alice",
                callerHandle: "alice"
            ),
            agentId: UUID(),
            source: .workspace
        )
        #expect(served.isWorkspaceAgentChat == false)
        #expect(served.remoteAgentAddress == Self.address.lowercased())
        #expect(served.source.originLabel(workspace: served.workspace) == "for @alice · Workspace")
    }

    // MARK: - Store round trip

    @Test @MainActor func store_persistsWorkspaceContext() async throws {
        try await ChatHistoryTestStorage.run {
            let store = SyncConversationStore.shared
            let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
            var session = makeSession(workspace: context)
            session.turns = [ChatTurnData(role: .user, content: "hi teammate agent")]
            ChatSessionStore.save(session)

            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.workspace == context)
            #expect(loaded.remoteAgentAddress == Self.address.lowercased())

            var local = makeSession(workspace: nil)
            local.turns = [ChatTurnData(role: .user, content: "local chat")]
            ChatSessionStore.save(local)
            #expect(store.loadSession(id: local.id)?.workspace == nil)
        }
    }

    // MARK: - ChatSessionsManager filtering

    @Test @MainActor func sessionsManager_keysTeammateChatsByAddressNotLocalAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let localAgent = UUID()
            let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)

            // Teammate-agent chat hosted by the Default tab.
            let teamChat = makeSession(workspace: context, agentId: Agent.defaultId)
            // Ordinary local chat with a custom agent.
            let localChat = makeSession(workspace: nil, agentId: localAgent)
            // Host-side row served for a teammate under the local shared agent.
            let served = makeSession(
                workspace: WorkspaceSessionContext(
                    workspaceId: "ws-1",
                    agentAddress: Self.address,
                    callerWallet: "0xcaller",
                    callerName: "Alice"
                ),
                agentId: localAgent,
                source: .workspace
            )
            defer {
                manager.delete(id: teamChat.id)
                manager.delete(id: localChat.id)
                manager.delete(id: served.id)
            }

            manager.save(teamChat)
            manager.save(localChat)
            manager.save(served)

            let allLocal = manager.sessions(for: nil).map(\.id)
            #expect(!allLocal.contains(teamChat.id), "team-agent chats must not appear in the Default 'all' list")
            #expect(allLocal.contains(localChat.id))
            #expect(allLocal.contains(served.id), "host-served rows stay under the shared agent")

            let forLocalAgent = manager.sessions(for: localAgent).map(\.id)
            #expect(forLocalAgent.contains(localChat.id))
            #expect(forLocalAgent.contains(served.id))
            #expect(!forLocalAgent.contains(teamChat.id))

            let byAddress = manager.sessions(forRemoteAgentAddress: Self.address.uppercased()).map(\.id)
            #expect(byAddress == [teamChat.id], "address lookup is case-insensitive and excludes host-served rows")
        }
    }
}
