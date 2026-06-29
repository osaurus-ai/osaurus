//
//  ChatSessionStoreTranscriptRecoveryTests.swift
//  osaurus
//
//  Regression coverage for recovering chat-history sessions whose turn rows
//  are missing while Memory still has transcript turns for the same session.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatSessionStoreTranscriptRecoveryTests {
    @Test func emptySessionHydratesTurnsFromMemoryTranscript() throws {
        let db = MemoryDatabase()
        try db.openInMemory()
        defer { db.close() }

        let sessionId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let agentId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        try db.insertTranscriptTurn(
            agentId: agentId.uuidString,
            conversationId: sessionId.uuidString,
            chunkIndex: 1,
            role: "assistant",
            content: "Yes, from the transcript fallback.",
            tokenCount: 6,
            title: "Recovered chat",
            createdAt: "2026-06-28 12:00:05"
        )
        try db.insertTranscriptTurn(
            agentId: agentId.uuidString,
            conversationId: sessionId.uuidString,
            chunkIndex: 0,
            role: "user",
            content: "Can you recover this?",
            tokenCount: 4,
            title: "Recovered chat",
            createdAt: "2026-06-28T12:00:00.123Z"
        )

        let session = ChatSessionData(
            id: sessionId,
            title: "Recovered chat",
            turns: [],
            agentId: agentId
        )

        let recovered = ChatSessionStore.recoverTranscriptTurnsIfNeeded(
            session,
            memoryDatabase: db
        )

        #expect(recovered.turns.map(\.role) == [.user, .assistant])
        #expect(
            recovered.turns.map(\.content) == [
                "Can you recover this?",
                "Yes, from the transcript fallback.",
            ]
        )
        #expect(recovered.turns[0].createdAt != nil)
        #expect(recovered.turns[1].createdAt != nil)
    }

    @Test func transcriptRecoveryDoesNotOpenClosedMemoryDatabase() throws {
        let db = MemoryDatabase()
        let session = ChatSessionData(id: UUID(), turns: [])

        let recovered = ChatSessionStore.recoverTranscriptTurnsIfNeeded(
            session,
            memoryDatabase: db
        )

        #expect(recovered.turns.isEmpty)
        #expect(!db.isOpen)
    }

    @Test func existingChatHistoryTurnsWinOverTranscriptFallback() throws {
        let db = MemoryDatabase()
        try db.openInMemory()
        defer { db.close() }

        let sessionId = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        try db.insertTranscriptTurn(
            agentId: Agent.defaultId.uuidString,
            conversationId: sessionId.uuidString,
            chunkIndex: 0,
            role: "user",
            content: "transcript should not replace this",
            tokenCount: 5
        )

        let existingTurn = ChatTurnData(role: .user, content: "chat history wins")
        let session = ChatSessionData(id: sessionId, turns: [existingTurn])

        let recovered = ChatSessionStore.recoverTranscriptTurnsIfNeeded(
            session,
            memoryDatabase: db
        )

        #expect(recovered.turns.map(\.content) == ["chat history wins"])
    }

    @Test func transcriptRecoverySkipsBlankAndUnknownRoles() throws {
        let db = MemoryDatabase()
        try db.openInMemory()
        defer { db.close() }

        let sessionId = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        try db.insertTranscriptTurn(
            agentId: Agent.defaultId.uuidString,
            conversationId: sessionId.uuidString,
            chunkIndex: 0,
            role: "developer",
            content: "unsupported role",
            tokenCount: 2
        )
        try db.insertTranscriptTurn(
            agentId: Agent.defaultId.uuidString,
            conversationId: sessionId.uuidString,
            chunkIndex: 1,
            role: "assistant",
            content: "   ",
            tokenCount: 0
        )

        let session = ChatSessionData(id: sessionId, turns: [])

        let recovered = ChatSessionStore.recoverTranscriptTurnsIfNeeded(
            session,
            memoryDatabase: db
        )

        #expect(recovered.turns.isEmpty)
    }
}
