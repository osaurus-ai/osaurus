//
//  ReopenedSessionHydrationTests.swift
//  osaurusTests
//
//  "Open in New Window" on a sidebar/history row handed the row's METADATA
//  session (turns: []) to the new window. The window showed an empty
//  transcript, the next send reached the model with no history, and the
//  incremental save then deleted every stored turn the window never had
//  (2026-09-06: a 50-turn research session became 2 turns). A window created
//  for a stored session must load that session's turns from disk.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ReopenedSessionHydrationTests {
    @MainActor
    @Test func windowCreatedFromAMetadataRowLoadsTheStoredTurns() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = Agent.defaultId
            let stored = ChatSessionData(
                id: UUID(),
                title: "Chocolate Iron Absorption Research",
                createdAt: Date(),
                updatedAt: Date(),
                selectedModel: "test-model",
                turns: [
                    ChatTurnData(role: .user, content: "Research chocolate and iron absorption."),
                    ChatTurnData(role: .assistant, content: "I'll search for sources."),
                    ChatTurnData(role: .user, content: "Keep going."),
                    ChatTurnData(role: .assistant, content: "The file is written."),
                ],
                agentId: agentId
            )
            ChatSessionStore.save(stored)

            // What the sidebar and the history panel actually hold.
            let metadata = try #require(ChatSessionStore.loadAll().first { $0.id == stored.id })
            #expect(metadata.turns.isEmpty, "the list row is metadata-only by design")

            let state = ChatWindowState(windowId: UUID(), agentId: agentId, sessionData: metadata)
            #expect(state.session.sessionId == stored.id)
            #expect(state.session.turns.count == 4, "the reopened window must carry the stored transcript")
            #expect(state.session.turns.last?.content == "The file is written.")

            // A brand-new, never-saved session keeps the data it was given.
            let fresh = ChatSessionData(
                id: UUID(), title: "New Chat", createdAt: Date(), updatedAt: Date(),
                selectedModel: nil, turns: [], agentId: agentId)
            let freshState = ChatWindowState(windowId: UUID(), agentId: agentId, sessionData: fresh)
            #expect(freshState.session.sessionId == fresh.id)
            #expect(freshState.session.turns.isEmpty)
        }
    }
}
