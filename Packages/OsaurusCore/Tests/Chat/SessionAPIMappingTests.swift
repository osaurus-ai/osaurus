//
//  SessionAPIMappingTests.swift
//  OsaurusCoreTests
//
//  Mapping the Mac's stored chat sessions onto the JSON the Osaurus Connect
//  phone reads (`GET /sessions`, `GET /sessions/{id}`).
//

import Foundation
import Testing

@testable import OsaurusCore

struct SessionAPIMappingTests {
    @Test func queryItemsParsesFiltersAndDecodesPercentEscapes() {
        let items = HTTPHandler.queryItems(from: "/sessions?agent_id=ABC&limit=25&title=hello%20there")
        #expect(items["agent_id"] == "ABC")
        #expect(items["limit"] == "25")
        #expect(items["title"] == "hello there")
        #expect(HTTPHandler.queryItems(from: "/sessions").isEmpty)
    }

    @Test func assistantTurnCarriesThinkingAndToolCalls() throws {
        let call = ToolCall(
            id: "call-1",
            type: "function",
            function: ToolCallFunction(name: "web_search", arguments: #"{"q":"x"}"#)
        )
        let turn = ChatTurnData(
            role: .assistant,
            content: "Here you go",
            toolCalls: [call],
            toolResults: ["call-1": "ok"],
            toolCallDurations: ["call-1": 1.25],
            thinkingDuration: 2.5,
            thinking: "weighing options",
            generationTokenCount: 42
        )
        let dto = try #require(HTTPHandler.turn(for: turn))
        #expect(dto.role == "assistant")
        #expect(dto.content == "Here you go")
        #expect(dto.thinking == "weighing options")
        #expect(dto.thinking_duration_ms == 2500)
        #expect(dto.token_count == 42)
        let calls = try #require(dto.tool_calls)
        #expect(calls.count == 1)
        #expect(calls[0].name == "web_search")
        #expect(calls[0].result == "ok")
        #expect(calls[0].duration_ms == 1250)
    }

    @Test func toolResultTurnsAreFoldedAway() {
        let turn = ChatTurnData(role: .tool, content: "raw result", toolCallId: "call-1")
        #expect(HTTPHandler.turn(for: turn) == nil)
    }

    @Test func userTurnReportsAttachmentsWithoutInliningThem() throws {
        let turn = ChatTurnData(role: .user, content: "look at this")
        let dto = try #require(HTTPHandler.turn(for: turn))
        #expect(dto.role == "user")
        #expect(dto.attachment_count == 0)
        #expect(dto.thinking == nil)
        #expect(dto.tool_calls == nil)
    }

    @Test func summaryCarriesTheHistoryListFields() {
        let session = ChatSessionData(
            title: "Bitcoin price",
            selectedModel: "qwen3",
            turns: [],
            pinned: true
        )
        let dto = HTTPHandler.summary(for: session)
        #expect(dto.id == session.id.uuidString)
        #expect(dto.title == "Bitcoin price")
        #expect(dto.selected_model == "qwen3")
        #expect(dto.pinned)
        #expect(!dto.archived)
        #expect(dto.source == "chat")
    }
}

@MainActor
struct RemoteSessionContinuationTests {
    @Test func storedTurnsBecomeModelMessages() throws {
        let call = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(name: "web_search", arguments: "{}")
        )
        let user = try #require(RemoteSessionContinuation.message(from: .init(role: .user, content: "hi")))
        #expect(user.role == "user")
        #expect(user.content == "hi")

        let assistant = try #require(
            RemoteSessionContinuation.message(from: .init(role: .assistant, content: "", toolCalls: [call]))
        )
        #expect(assistant.tool_calls?.count == 1)

        let toolTurn = try #require(
            RemoteSessionContinuation.message(
                from: .init(role: .tool, content: "result", toolCallId: "c1")
            )
        )
        #expect(toolTurn.tool_call_id == "c1")
    }

    @Test func emptyAndExcludedTurnsAreSkipped() {
        #expect(RemoteSessionContinuation.message(from: .init(role: .assistant, content: "")) == nil)
        #expect(RemoteSessionContinuation.message(from: .init(role: .system, content: "prompt")) == nil)
        #expect(
            RemoteSessionContinuation.message(
                from: .init(role: .user, content: "old", modelContextExcluded: true)
            ) == nil
        )
    }

    @Test func truncatingAnUnknownChatChangesNothing() {
        #expect(RemoteSessionContinuation.truncate(UUID(), fromTurnId: UUID()) == .sessionNotFound)
    }
}
