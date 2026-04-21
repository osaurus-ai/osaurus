//
//  ExecutionContextSourceTaggingTests.swift
//  osaurusTests
//
//  Phase 2 of the chat-sessions refactor aligned `ExecutionContext.id` with
//  `ChatSession.sessionId` and propagates `source` / `sourcePluginId` /
//  `externalSessionKey` from the dispatch request onto the underlying
//  ChatSession so the persisted history row carries the right origin tag.
//  These tests freeze that contract.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ExecutionContextSourceTaggingTests {

    @Test
    func init_withDefaults_marksSessionAsChat() {
        let context = ExecutionContext(agentId: Agent.defaultId)
        #expect(context.chatSession.source == .chat)
        #expect(context.chatSession.sourcePluginId == nil)
        #expect(context.chatSession.externalSessionKey == nil)
        // ID alignment: persisted session id == dispatch task id.
        #expect(context.chatSession.sessionId == context.id)
        #expect(context.chatSession.dispatchTaskId == context.id)
    }

    @Test
    func init_withPluginSource_propagatesAllMetadata() {
        let id = UUID()
        let context = ExecutionContext(
            id: id,
            agentId: Agent.defaultId,
            title: "Telegram dispatch",
            source: .plugin,
            sourcePluginId: "com.example.telegram",
            externalSessionKey: "telegram-chat-42"
        )
        #expect(context.chatSession.source == .plugin)
        #expect(context.chatSession.sourcePluginId == "com.example.telegram")
        #expect(context.chatSession.externalSessionKey == "telegram-chat-42")
        #expect(context.chatSession.sessionId == id)
        #expect(context.chatSession.dispatchTaskId == id)
        #expect(context.chatSession.title == "Telegram dispatch")
    }

    @Test
    func init_withHttpSource_setsHttpAndAlignsIds() {
        let context = ExecutionContext(
            agentId: Agent.defaultId,
            source: .http,
            externalSessionKey: "X-Session-Id-value"
        )
        #expect(context.chatSession.source == .http)
        #expect(context.chatSession.sourcePluginId == nil)
        #expect(context.chatSession.externalSessionKey == "X-Session-Id-value")
        #expect(context.chatSession.sessionId == context.id)
    }

    @Test
    func toSessionData_carriesSourceFields() {
        let id = UUID()
        let context = ExecutionContext(
            id: id,
            agentId: Agent.defaultId,
            source: .schedule,
            sourcePluginId: nil,
            externalSessionKey: "schedule-uuid"
        )
        // Force at least one turn so save() has something to persist
        // when callers go through the real flow.
        context.chatSession.turns.append(
            ChatTurn(role: .user, content: "scheduled prompt")
        )
        let data = context.chatSession.toSessionData()
        #expect(data.source == .schedule)
        #expect(data.externalSessionKey == "schedule-uuid")
        #expect(data.id == id)
        #expect(data.dispatchTaskId == id)
    }
}
