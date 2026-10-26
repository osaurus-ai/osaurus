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

    @Test func diskReloadHistoryReplaysOpaqueSignedAndReasoningOnlyTurns() async throws {
        try await ChatHistoryTestStorage.run {
            let native = try ResponsesHistoryFixture.turn()
            let items = try ResponsesHistoryFixture.items()
            let opaqueItem = try #require(items.last)
            let opaqueOnly = ChatTurnData(
                role: .assistant, content: "", responsesOutputItems: [opaqueItem]
            )
            var signedOnly = ChatTurnData(role: .assistant, content: "")
            signedOnly.anthropicThinkingBlocks = try ResponsesHistoryFixture.signedBlocks()
            let reasoningOnly = ChatTurnData(role: .assistant, content: "", thinking: "Retained earlier reasoning")
            var excluded = try ResponsesHistoryFixture.turn()
            excluded.modelContextExcluded = true
            try #require(excluded.id != native.id, "Excluded fixture is a distinct SQL row, not an update of the native row")
            let session = ChatSessionData(turns: [
                ChatTurnData(role: .system, content: "Not replayed"), native, opaqueOnly, signedOnly, reasoningOnly, excluded,
            ])
            let disk = ChatHistoryDatabase()
            try disk.open()
            try disk.saveSession(session)
            disk.close()
            // No store/manager save or pending overlay was populated. The
            // production continuation reader must reopen the committed row.
            let history = await RemoteSessionContinuation.history(for: session.id)
            try #require(history.count == 4)
            let replay = try #require(history.first)
            #expect(replay.reasoning_content == native.thinking)
            #expect(replay.reasoning_item_id == native.reasoningItemId && replay.reasoning_encrypted == native.reasoningEncrypted)
            #expect(replay.responses_output_items == native.responsesOutputItems)
            #expect(replay.tool_calls?.map(\.id) == ["call_b", "call_a"])
            #expect(replay.tool_calls?.first?.function.arguments == #"{"count":"7"}"#)
            #expect(history[1].content == "" && history[1].responses_output_items == opaqueOnly.responsesOutputItems)
            #expect(history[2].content == "" && history[2].anthropic_thinking_blocks == signedOnly.anthropicThinkingBlocks)
            #expect(history[3].content == "" && history[3].reasoning_content == "Retained earlier reasoning")
        }
    }

    /// What the model was sent ahead of a user message stays out of the
    /// stored turn's text, and goes back in front when the chat is continued.
    @Test func injectedBlocksStayOutOfTheStoredTurn() throws {
        let prefix = "[Memory]\nfact\n[/Memory]\n\n"
        let turns = ChatHistoryWriter.turns(from: [
            ChatMessage(role: "user", content: prefix + "hi"),
            ChatMessage(role: "assistant", content: prefix + "quoted back"),
        ])
        #expect(turns[0].content == "hi")
        #expect(turns[0].injectedContextPrefix == prefix)
        #expect(turns[1].content == prefix + "quoted back")
        #expect(turns[1].injectedContextPrefix == nil)

        let message = try #require(RemoteSessionContinuation.message(from: turns[0]))
        #expect(message.content == prefix + "hi")
    }

    @Test func runRequestCarriesTheChatToContinue() throws {
        let json = #"{"messages":[{"role":"user","content":"hi"}],"model":"","osaurus_session_id":"abc"}"#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.osaurus_session_id == "abc")
        // Never forwarded to a provider.
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("osaurus_session_id"))
    }

    @Test func runRequestCanStartAChat() throws {
        let json = #"""
            {"messages":[{"role":"user","content":"hi"}],"model":"",
             "osaurus_session_id":"abc","osaurus_create_session":true}
            """#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.osaurus_create_session == true)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("osaurus_create_session"))
    }

    @MainActor @Test func aChatThePhoneStartedIsAnOrdinaryChatShownAsThePhones() {
        let started = ChatSessionData(externalSessionKey: RemoteSessionContinuation.phoneChatKey)
        #expect(started.workspace == nil)
        #expect(RemoteSessionContinuation.isFromPairedPhone(started))
        #expect(HTTPHandler.summary(for: started, fromPhone: true).origin == "ios")
        // The marker only counts on an ordinary chat.
        let other = ChatSessionData(source: .http, externalSessionKey: RemoteSessionContinuation.phoneChatKey)
        #expect(!RemoteSessionContinuation.isFromPairedPhone(other))
        #expect(!RemoteSessionContinuation.isFromPairedPhone(ChatSessionData()))
    }

    @MainActor @Test func onlyThePairedKeyCountsAsThePhone() {
        #expect(!RemoteSessionContinuation.isPairedPhoneKey(nil))
        guard let paired = MobilePairingService.shared.pairedKeyNonce else { return }
        #expect(RemoteSessionContinuation.isPairedPhoneKey(paired.uppercased()))
        #expect(!RemoteSessionContinuation.isPairedPhoneKey(paired + "x"))
    }

    @Test func truncatingAnUnknownChatChangesNothing() {
        #expect(RemoteSessionContinuation.truncate(UUID(), fromTurnId: UUID()) == .sessionNotFound)
    }
}
