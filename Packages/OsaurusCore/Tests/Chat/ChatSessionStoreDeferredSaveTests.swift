//
//  ChatSessionStoreDeferredSaveTests.swift
//  osaurus
//
//  Regression coverage for #1737: turn writes that were deferred while the
//  chat-history DB was closed must be re-flushed (not dropped), and loading an
//  orphaned conversation must heal its turns back onto disk.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ChatSessionStoreDeferredSaveTests {
    private func withOpenStores(
        memory: Bool = false,
        _ body: () throws -> Void
    ) throws {
        try ChatHistoryDatabase.shared.openInMemory()
        if memory { try MemoryDatabase.shared.openInMemory() }
        ChatSessionStore._markStorageOpenForTesting()
        defer {
            ChatSessionStore._resetForTesting()
            if memory { MemoryDatabase.shared.close() }
        }
        try body()
    }

    @Test func flushPersistsQueuedSavesToDatabase() throws {
        try withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Deferred chat",
                turns: [
                    ChatTurnData(role: .user, content: "queued question"),
                    ChatTurnData(role: .assistant, content: "queued answer"),
                ]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            #expect(ChatSessionStore._pendingSaveCountForTesting == 1)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            let loaded = ChatHistoryDatabase.shared.loadSession(id: session.id)
            #expect(loaded?.turns.map(\.content) == ["queued question", "queued answer"])
        }
    }

    @Test func deleteDropsQueuedSaveForSession() throws {
        try withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Cancelled deferred chat",
                turns: [ChatTurnData(role: .user, content: "cancelled before review")]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            #expect(ChatSessionStore._pendingSaveCountForTesting == 1)

            ChatSessionStore.delete(id: session.id)
            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            #expect(ChatHistoryDatabase.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func flushDeletesQueuedDeleteFromDatabase() throws {
        try withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Persisted before deferred delete",
                turns: [ChatTurnData(role: .user, content: "remove me later")]
            )
            try ChatHistoryDatabase.shared.saveSession(session)
            ChatSessionStore._enqueuePendingDeleteForTesting(session.id)
            #expect(ChatSessionStore._pendingDeleteCountForTesting == 1)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingDeleteCountForTesting == 0)
            #expect(ChatHistoryDatabase.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func pendingDeleteWinsOverQueuedSaveForSession() throws {
        try withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Cancelled deferred chat",
                turns: [ChatTurnData(role: .user, content: "do not restore")]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            ChatSessionStore._enqueuePendingDeleteForTesting(session.id)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            #expect(ChatSessionStore._pendingDeleteCountForTesting == 0)
            #expect(ChatHistoryDatabase.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func pendingDeleteRejectsDeferredSaveWhileDatabaseClosed() throws {
        let session = ChatSessionData(
            id: UUID(),
            title: "Cancelled while closed",
            turns: [ChatTurnData(role: .user, content: "do not queue")]
        )
        ChatSessionStore._resetForTesting()
        defer { ChatSessionStore._resetForTesting() }

        ChatSessionStore._enqueuePendingDeleteForTesting(session.id)
        ChatSessionStore.save(session)

        #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
        #expect(ChatSessionStore._pendingDeleteCountForTesting == 1)
    }

    @Test func loadHealsOrphanedTurnsBackToDisk() throws {
        try withOpenStores(memory: true) {
            let sessionId = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
            // Metadata row exists, but turns were lost (the #1737 state).
            try ChatHistoryDatabase.shared.saveSession(
                ChatSessionData(id: sessionId, title: "Orphaned chat", turns: [])
            )
            try MemoryDatabase.shared.insertTranscriptTurn(
                agentId: Agent.defaultId.uuidString,
                conversationId: sessionId.uuidString,
                chunkIndex: 0,
                role: "user",
                content: "are my turns gone?",
                tokenCount: 4
            )

            let loaded = ChatSessionStore.load(id: sessionId)
            #expect(loaded?.turns.map(\.content) == ["are my turns gone?"])

            // The heal should have written the recovered turns back, so a raw
            // DB read (no transcript fallback) now sees them too.
            let healed = ChatHistoryDatabase.shared.loadSession(id: sessionId)
            #expect(healed?.turns.map(\.content) == ["are my turns gone?"])
        }
    }
}
