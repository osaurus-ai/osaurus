//
//  HTTPChatCompletionsEmptyToolTaskTests.swift
//

import Testing

@testable import OsaurusCore

struct HTTPChatCompletionsEmptyToolTaskTests {

    @Test func emptyNoToolResponseAfterToolHistoryIsRejected() {
        let toolCall = ToolCall(
            id: "call_read",
            type: "function",
            function: ToolCallFunction(name: "file_read", arguments: #"{"path":"notes.md"}"#)
        )
        let activeToolTranscript = [
            ChatMessage(role: "user", content: "Read notes.md and summarize it."),
            ChatMessage(role: "assistant", content: nil, tool_calls: [toolCall], tool_call_id: nil),
            ChatMessage(role: "tool", content: "notes", tool_calls: nil, tool_call_id: "call_read"),
        ]

        let emptyFinal = ChatMessage(role: "assistant", content: " \n ", tool_calls: nil, tool_call_id: nil)
        #expect(
            HTTPHandler.emptyToolTaskCompletionError(
                requestMessages: activeToolTranscript,
                responseMessage: emptyFinal
            ) != nil
        )

        let textFinal = ChatMessage(role: "assistant", content: "Summary: notes")
        #expect(
            HTTPHandler.emptyToolTaskCompletionError(
                requestMessages: activeToolTranscript,
                responseMessage: textFinal
            ) == nil
        )

        let ordinaryEmpty = ChatMessage(role: "assistant", content: "")
        #expect(
            HTTPHandler.emptyToolTaskCompletionError(
                requestMessages: [ChatMessage(role: "user", content: "Hello")],
                responseMessage: ordinaryEmpty
            ) == nil
        )
    }
}
