//
//  SessionSourcePersistenceTests.swift
//  osaurusTests
//
//  Verifies the audit dimension stays intact end-to-end:
//
//  - `ExecutionContext` propagates `source` / `sourcePluginId` /
//    `externalSessionKey` onto the seeded `ChatSession`.
//  - `ChatSession.toSessionData()` round-trips those onto `ChatSessionData`.
//  - `init(reattaching:)` reuses the existing session id + restores
//    persisted source metadata so subsequent dispatches accrete into the
//    same row instead of creating a fresh one.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SessionSourcePersistenceTests {

    @Test
    func executionContext_propagatesPluginOriginToChatSession() {
        let agentId = UUID()
        let key = "telegram-chat-99"
        let context = ExecutionContext(
            agentId: agentId,
            title: "Telegram message",
            source: .plugin,
            sourcePluginId: "com.example.telegram",
            externalSessionKey: key
        )

        #expect(context.chatSession.source == .plugin)
        #expect(context.chatSession.sourcePluginId == "com.example.telegram")
        #expect(context.chatSession.externalSessionKey == key)
        // Dispatch task id must equal the context id so HTTP / plugin
        // pollers can deep-link to the persisted session row.
        #expect(context.chatSession.dispatchTaskId == context.id)
        #expect(context.chatSession.sessionId == context.id)
    }

    @Test
    func executionContext_propagatesHttpOriginToChatSession() {
        let context = ExecutionContext(
            agentId: Agent.defaultId,
            source: .http,
            externalSessionKey: "http-thread-abc"
        )
        #expect(context.chatSession.source == .http)
        #expect(context.chatSession.sourcePluginId == nil)
        #expect(context.chatSession.externalSessionKey == "http-thread-abc")
    }

    @Test
    func chatSession_toSessionData_roundtripsAllOriginFields() {
        let context = ExecutionContext(
            agentId: Agent.defaultId,
            title: "T",
            source: .plugin,
            sourcePluginId: "p1",
            externalSessionKey: "k1"
        )
        let data = context.chatSession.toSessionData()

        #expect(data.id == context.id)
        #expect(data.source == .plugin)
        #expect(data.sourcePluginId == "p1")
        #expect(data.externalSessionKey == "k1")
        #expect(data.dispatchTaskId == context.id)
    }

    @Test
    func chatSession_toSessionData_omitsDispatchIdForPlainChat() {
        // Sanity check that the audit dimension stays clean: a session that
        // never went through `ExecutionContext` (i.e. user-driven UI chat)
        // does not get tagged with a dispatch id.
        let session = ChatSession()
        session.sessionId = UUID()
        let data = session.toSessionData()
        #expect(data.source == .chat)
        #expect(data.dispatchTaskId == nil)
        #expect(data.sourcePluginId == nil)
        #expect(data.externalSessionKey == nil)
    }

    @Test
    func chatSession_resetClearsScheduledOriginForNextManualChat() {
        let scheduleId = UUID()
        let dispatchId = UUID()
        let session = ChatSession()
        session.source = .schedule
        session.externalSessionKey = scheduleId.uuidString
        session.dispatchTaskId = dispatchId
        session.sessionId = dispatchId
        session.title = "Scheduled report"

        session.reset()

        #expect(session.source == .chat)
        #expect(session.sourcePluginId == nil)
        #expect(session.externalSessionKey == nil)
        #expect(session.dispatchTaskId == nil)
        #expect(session.sessionId == nil)
        #expect(session.turns.isEmpty)
    }

    @Test
    func chatSession_firstSaveAfterResetPersistsManualChatOrigin() async throws {
        try await ChatHistoryTestStorage.run {
            let scheduleId = UUID()
            let dispatchId = UUID()
            let session = ChatSession()
            session.source = .schedule
            session.externalSessionKey = scheduleId.uuidString
            session.dispatchTaskId = dispatchId
            session.sessionId = dispatchId

            session.reset()
            session.turns = [ChatTurn(role: .user, content: "manual follow-up")]
            session.save()

            let data = session.toSessionData()
            #expect(data.source == .chat)
            #expect(data.sourcePluginId == nil)
            #expect(data.externalSessionKey == nil)
            #expect(data.dispatchTaskId == nil)
        }
    }

    @Test
    func executionContext_reattach_restoresIdAndOriginAndTurns() async {
        let originalId = UUID()
        let agentId = UUID()
        let existing = ChatSessionData(
            id: originalId,
            title: "Existing thread",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            selectedModel: nil,
            turns: [
                ChatTurnData(role: .user, content: "first user msg"),
                ChatTurnData(role: .assistant, content: "first reply"),
            ],
            agentId: agentId,
            source: .plugin,
            sourcePluginId: "com.example.telegram",
            externalSessionKey: "telegram-chat-77",
            dispatchTaskId: originalId
        )

        let context = ExecutionContext(reattaching: existing)

        // Reusing the existing id is the contract that lets pollers find
        // the live task at the same `task_id` after reattach.
        #expect(context.id == originalId)
        #expect(context.chatSession.sessionId == originalId)
        #expect(context.chatSession.source == .plugin)
        #expect(context.chatSession.sourcePluginId == "com.example.telegram")
        #expect(context.chatSession.externalSessionKey == "telegram-chat-77")
        #expect(context.chatSession.dispatchTaskId == originalId)
        #expect(context.chatSession.turns.count == 2)
        #expect(context.chatSession.turns.first?.content == "first user msg")
    }
}
