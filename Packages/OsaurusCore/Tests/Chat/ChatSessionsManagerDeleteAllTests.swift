//
//  ChatSessionsManagerDeleteAllTests.swift
//  osaurusTests
//
//  Pins the ownership contract of `ChatSessionsManager.deleteAll(for:)`,
//  the bulk wipe behind the agent detail "Delete All Data" flow and agent
//  deletion. The wipe matches strictly, the same rule as `sessions(for:)`:
//  a per-agent wipe removes only that agent's sessions, and a Default-agent
//  wipe removes only unowned (nil-agent) sessions, never another agent's
//  history.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionsManagerDeleteAllTests {

    @Test
    func deleteAll_removesOnlyTheAgentsOwnSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            manager.refresh()  // isolated store starts empty

            let agentA = UUID()
            let agentB = UUID()
            let a1 = manager.createNew(agentId: agentA)
            let a2 = manager.createNew(agentId: agentA)
            let b1 = manager.createNew(agentId: agentB)
            let unownedSession = manager.createNew(agentId: nil)
            manager.currentSessionId = a1

            await manager.deleteAll(for: agentA)

            let remaining = Set(manager.sessions.map(\.id))
            #expect(!remaining.contains(a1))
            #expect(!remaining.contains(a2))
            #expect(remaining.contains(b1))
            #expect(remaining.contains(unownedSession))
            // The wiped agent owned the selected session, so the selection
            // must clear rather than dangle.
            #expect(manager.currentSessionId == nil)

            // Disk agrees with the in-memory list once the async batch
            // (awaited above) has run: a full reload shows the same rows.
            manager.refresh()
            let reloaded = Set(manager.sessions.map(\.id))
            #expect(reloaded == Set([b1, unownedSession]))
        }
    }

    @Test
    func deleteAll_forDefaultAgent_removesOnlyUnownedSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            manager.refresh()

            let agentB = UUID()
            let b1 = manager.createNew(agentId: agentB)
            let unownedSession = manager.createNew(agentId: nil)

            await manager.deleteAll(for: Agent.defaultId)

            let remaining = Set(manager.sessions.map(\.id))
            #expect(!remaining.contains(unownedSession))
            #expect(remaining.contains(b1))

            manager.refresh()
            #expect(Set(manager.sessions.map(\.id)) == Set([b1]))
        }
    }

    /// The window's History list and the sidebar agree on what the
    /// Orchestrator owns: its own and untagged chats, not other agents'.
    @Test
    func sessionsForDefaultAgentMatchTheSidebar() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            manager.refresh()

            let agentB = UUID()
            let b1 = manager.createNew(agentId: agentB)
            let tagged = manager.createNew(agentId: Agent.defaultId)
            let unowned = manager.createNew(agentId: nil)

            for agentId in [nil, Agent.defaultId] {
                #expect(Set(manager.sessions(for: agentId).map(\.id)) == Set([tagged, unowned]))
            }
            #expect(manager.sessions(for: agentB).map(\.id) == [b1])
            #expect(
                Set(manager.sessions(for: Agent.defaultId).map(\.id))
                    == Set(ChatSessionSidebar.agentHistorySessions(manager.sessions, agentId: Agent.defaultId).map(\.id))
            )
        }
    }
}
