//
//  ChatHistoryWriterWorkspaceTests.swift
//  osaurusTests
//
//  Host-side history for workspace runs: when a teammate drives one of this
//  instance's shared agents over `/agents/{id}/run`, the sharer's Osaurus
//  persists the conversation under that agent with `source == .workspace`,
//  grouped by the stable `callerWallet:session_id` key so every turn of one
//  conversation lands in one row, tagged with the caller for History.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatHistoryWriterWorkspaceTests {

    private static let agentAddress = "0xShared0000000000000000000000000000000001"
    private static let callerWallet = "0xCaller0000000000000000000000000000000002"

    private func context(callerName: String? = "Alice") -> WorkspaceSessionContext {
        WorkspaceSessionContext(
            workspaceId: "ws-acme",
            agentAddress: Self.agentAddress,
            callerWallet: Self.callerWallet,
            callerName: callerName
        )
    }

    private func persist(
        agentId: UUID,
        externalKey: String,
        messages: [ChatMessage],
        context: WorkspaceSessionContext
    ) {
        ChatHistoryWriter.persist(
            source: .workspace,
            sourcePluginId: ChatHistoryWriter.workspacePseudoPluginId,
            agentId: agentId,
            externalKey: externalKey,
            finalMessages: messages,
            model: "host-model",
            workspace: context
        )
    }

    private func find(agentId: UUID, externalKey: String) -> ChatSessionData? {
        guard
            let hit = ChatHistoryDatabase.shared.findSession(
                pluginId: ChatHistoryWriter.workspacePseudoPluginId,
                externalKey: externalKey,
                agentId: agentId
            )
        else { return nil }
        return ChatHistoryDatabase.shared.loadSession(id: hit.id)
    }

    @Test func persist_writesWorkspaceRowUnderSharedAgentWithCallerTag() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let key = "\(Self.callerWallet.lowercased()):convo-1"

            persist(
                agentId: agentId,
                externalKey: key,
                messages: [
                    ChatMessage(role: "system", content: "You are helpful."),
                    ChatMessage(role: "user", content: "Summarize the roadmap"),
                    ChatMessage(role: "assistant", content: "Here is the summary."),
                ],
                context: context()
            )

            let row = try #require(find(agentId: agentId, externalKey: key))
            #expect(row.source == .workspace)
            #expect(row.agentId == agentId, "served rows live under the local shared agent")
            #expect(row.sourcePluginId == ChatHistoryWriter.workspacePseudoPluginId)
            #expect(row.externalSessionKey == key)
            #expect(row.turns.map(\.role) == [.user, .assistant], "system prompt is not part of history")
            #expect(row.workspace == context())
            #expect(row.workspace?.isServedForTeammate == true)
            #expect(row.isWorkspaceAgentChat == false, "host copy is not a teammate-agent chat")
            #expect(row.source.originLabel(workspace: row.workspace) == "for Alice · Workspace")
            #expect(row.title != "New Chat")
        }
    }

    @Test func persist_groupsTurnsOfOneConversationIntoOneRow() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let key = "\(Self.callerWallet.lowercased()):convo-2"
            let firstTurn = [
                ChatMessage(role: "user", content: "hello"),
                ChatMessage(role: "assistant", content: "hi there"),
            ]
            persist(agentId: agentId, externalKey: key, messages: firstTurn, context: context())
            let first = try #require(find(agentId: agentId, externalKey: key))

            // Second `/run` for the same teammate + session_id carries the
            // full transcript again; the row is updated, not duplicated.
            let secondTurn =
                firstTurn + [
                    ChatMessage(role: "user", content: "and now?"),
                    ChatMessage(role: "assistant", content: "still here"),
                ]
            persist(agentId: agentId, externalKey: key, messages: secondTurn, context: context())
            let second = try #require(find(agentId: agentId, externalKey: key))

            #expect(second.id == first.id)
            #expect(second.turns.count == 4)
            #expect(second.turns.last?.content == "still here")
            #expect(second.updatedAt >= first.updatedAt)

            let rows = ChatHistoryDatabase.shared.loadAllMetadata().filter { $0.externalSessionKey == key }
            #expect(rows.count == 1)
        }
    }

    @Test func persist_separatesDifferentCallersAndSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let messages = [
                ChatMessage(role: "user", content: "q"),
                ChatMessage(role: "assistant", content: "a"),
            ]
            let aliceKey = "\(Self.callerWallet.lowercased()):convo-3"
            let aliceOtherSession = "\(Self.callerWallet.lowercased()):convo-4"
            let bobWallet = "0xbob000000000000000000000000000000000000003"
            let bobKey = "\(bobWallet):convo-3"

            persist(agentId: agentId, externalKey: aliceKey, messages: messages, context: context())
            persist(agentId: agentId, externalKey: aliceOtherSession, messages: messages, context: context())
            persist(
                agentId: agentId,
                externalKey: bobKey,
                messages: messages,
                context: WorkspaceSessionContext(
                    workspaceId: "ws-acme",
                    agentAddress: Self.agentAddress,
                    callerWallet: bobWallet,
                    callerName: "Bob"
                )
            )

            let alice = try #require(find(agentId: agentId, externalKey: aliceKey))
            let aliceOther = try #require(find(agentId: agentId, externalKey: aliceOtherSession))
            let bob = try #require(find(agentId: agentId, externalKey: bobKey))
            #expect(Set([alice.id, aliceOther.id, bob.id]).count == 3)
            #expect(bob.workspace?.callerLabel == "Bob")
            #expect(alice.workspace?.callerLabel == "Alice")
        }
    }

    @Test func persist_skipsSystemOnlyTranscripts() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let key = "\(Self.callerWallet.lowercased()):convo-empty"
            try ChatHistoryDatabase.shared.open()
            persist(
                agentId: agentId,
                externalKey: key,
                messages: [ChatMessage(role: "system", content: "only a prompt")],
                context: context()
            )
            #expect(find(agentId: agentId, externalKey: key) == nil)
        }
    }

    @Test func persist_notifiesSessionsManagerSoHostSidebarUpdatesLive() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let agentId = UUID()
            let key = "\(Self.callerWallet.lowercased()):convo-live"
            var notifiedSessionId: UUID?
            let token = NotificationCenter.default.addObserver(
                forName: ChatHistoryWriter.didPersistExternallyNotification,
                object: nil,
                queue: .main
            ) { note in notifiedSessionId = note.userInfo?["sessionId"] as? UUID }
            defer { NotificationCenter.default.removeObserver(token) }

            persist(
                agentId: agentId,
                externalKey: key,
                messages: [
                    ChatMessage(role: "user", content: "ping"),
                    ChatMessage(role: "assistant", content: "pong"),
                ],
                context: context()
            )

            // The notification hops to the main queue.
            var waited = 0
            while notifiedSessionId == nil && waited < 2_000 {
                try await Task.sleep(for: .milliseconds(20))
                waited += 20
            }
            let row = try #require(find(agentId: agentId, externalKey: key))
            #expect(notifiedSessionId == row.id, "the writer announces the exact row it wrote")

            // `ChatSessionsManager` subscribes to that notification in
            // production (the subscription is deliberately disarmed under
            // tests to avoid cross-suite reloads), so prove the reload it
            // performs surfaces the row under the shared agent.
            #expect(!manager.sessions(for: agentId).contains { $0.id == row.id })
            manager.refresh()
            let visible = manager.sessions(for: agentId).first { $0.id == row.id }
            #expect(visible != nil, "the host's sidebar/History shows the served row under the shared agent")
            #expect(visible?.source == .workspace)
            #expect(visible?.workspace?.callerLabel == "Alice")
            #expect(
                manager.sessions(forRemoteAgentAddress: Self.agentAddress).isEmpty,
                "host copies are not teammate-agent chats"
            )
            manager.delete(id: row.id)
        }
    }
}
