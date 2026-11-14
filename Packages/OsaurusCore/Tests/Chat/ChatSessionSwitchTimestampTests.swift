//
//  ChatSessionSwitchTimestampTests.swift
//  osaurusTests
//
//  Switching conversations must not bump the outgoing chat's `updatedAt`.
//  `load(from:)` and `reset()` call `stop()`, which runs run cleanup and a
//  save even when nothing is streaming; with the Default agent that cleanup
//  used to finish an Orchestrator turn, mark the session dirty, and re-stamp
//  the sidebar time to "Now".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionSwitchTimestampTests {
    private static func idleConversation(updatedAt: Date) -> ChatSessionData {
        ChatSessionData(
            title: "Earlier chat",
            createdAt: updatedAt,
            updatedAt: updatedAt,
            turns: [
                ChatTurnData(role: .user, content: "Hello"),
                ChatTurnData(role: .assistant, content: "Hi"),
            ]
        )
    }

    @Test("switching away from an idle Default-agent chat keeps its updatedAt")
    func loadingAnotherSession_keepsOutgoingTimestamp() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let earlier = Date().addingTimeInterval(-3 * 3600)
            let outgoing = Self.idleConversation(updatedAt: earlier)
            session.load(from: outgoing)

            var savedUpdatedAt: [UUID: Date] = [:]
            session.onSessionChanged = {
                if let id = session.sessionId { savedUpdatedAt[id] = session.updatedAt }
            }

            session.load(from: Self.idleConversation(updatedAt: earlier))

            if let saved = savedUpdatedAt[outgoing.id] {
                #expect(saved == earlier, "switching chats re-stamped the outgoing chat's updatedAt")
            }
            let row = ChatSessionsManager.shared.sessions.first { $0.id == outgoing.id }
            #expect(row == nil || row?.updatedAt == earlier)
        }
    }

    @Test("opening a chat from a blank New Chat does not persist the blank one")
    func loadingFromBlankNewChat_persistsNothing() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.reset()
            let before = Set(ChatSessionsManager.shared.sessions.map(\.id))
            let target = Self.idleConversation(updatedAt: Date().addingTimeInterval(-3600))

            var blankSaves = 0
            session.onSessionChanged = {
                if session.sessionId != target.id { blankSaves += 1 }
            }

            session.load(from: target)

            #expect(blankSaves == 0, "the blank New Chat was saved when another chat was opened")
            let added = Set(ChatSessionsManager.shared.sessions.map(\.id)).subtracting(before)
            #expect(added.isEmpty, "a row appeared for the blank New Chat")
        }
    }

    @Test("only a never-touched New Chat counts as untouched")
    func untouchedTab_isNotAHistoryRow() {
        let blank = ChatSession()
        #expect(ChatSessionSidebar.isUntouchedChat(ChatTab(id: UUID(), session: blank)))

        let started = ChatSession()
        started.turns = [ChatTurn(role: .user, content: "hi")]
        #expect(!ChatSessionSidebar.isUntouchedChat(ChatTab(id: UUID(), session: started)))

        let saved = ChatSession()
        saved.sessionId = UUID()
        #expect(!ChatSessionSidebar.isUntouchedChat(ChatTab(id: UUID(), session: saved, isHibernated: true)))
    }

    @Test("starting a new chat from an idle Default-agent chat keeps its updatedAt")
    func resetFromLoadedSession_keepsTimestamp() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let earlier = Date().addingTimeInterval(-3 * 3600)
            let outgoing = Self.idleConversation(updatedAt: earlier)
            session.load(from: outgoing)

            var savedUpdatedAt: Date?
            session.onSessionChanged = {
                if session.sessionId == outgoing.id { savedUpdatedAt = session.updatedAt }
            }

            session.reset()

            if let savedUpdatedAt {
                #expect(savedUpdatedAt == earlier, "New Chat re-stamped the outgoing chat's updatedAt")
            }
        }
    }
}
