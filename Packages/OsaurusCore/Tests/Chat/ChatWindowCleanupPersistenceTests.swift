//
//  ChatWindowCleanupPersistenceTests.swift
//  osaurus
//
//  Closing a chat window during model load silently destroyed the just-sent
//  message: cleanup()'s stop() took the mid-prepare draft-restore rollback
//  (which removes the user turn to put its text back in a composer that is
//  being destroyed), and the close callback's later save() then found empty
//  turns and bailed — no persisted trace that the send ever happened.
//  cleanup() now persists BEFORE stop(), the same guard switchAgent and
//  startNewChat already had.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatWindowCleanupPersistenceTests {

    @Test("cleanup persists the pending user turn before stop can roll it back")
    func cleanupPersistsBeforeStop() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let session = window.session
            session.turns = [ChatTurn(role: .user, content: "close me mid-load")]

            window.cleanup()

            let sessionId = try #require(session.sessionId, "save() must have minted an id")
            // saveAsync updates the in-memory manager synchronously; the
            // persisted store row follows. Assert via the manager's view.
            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(persisted.turns.contains { $0.role == .user && $0.content == "close me mid-load" })
        }
    }

    @Test("cleanup on an empty session persists nothing and does not mint an id")
    func cleanupOnEmptySessionIsInert() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            window.cleanup()
            #expect(window.session.sessionId == nil)
        }
    }
}
