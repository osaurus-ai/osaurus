//
//  ChatSessionsManagerDeleteAllTests.swift
//  osaurusTests
//
//  Pins the ownership contract of `ChatSessionsManager.deleteAll(for:)`,
//  the bulk wipe behind the agent detail "Delete All Data" flow and agent
//  deletion. Unlike `sessions(for:)` — where the Default agent means "show
//  everything" — the wipe must match strictly: a per-agent wipe removes
//  only that agent's sessions, and a Default-agent wipe removes only
//  unowned (nil-agent) sessions, never another agent's history.
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

            // `sessions(for:)` returns EVERYTHING for the Default agent;
            // the wipe must not inherit that meaning.
            await manager.deleteAll(for: Agent.defaultId)

            let remaining = Set(manager.sessions.map(\.id))
            #expect(!remaining.contains(unownedSession))
            #expect(remaining.contains(b1))

            manager.refresh()
            #expect(Set(manager.sessions.map(\.id)) == Set([b1]))
        }
    }
}
