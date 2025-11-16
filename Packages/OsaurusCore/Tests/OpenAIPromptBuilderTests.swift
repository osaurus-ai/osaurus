//
//  OpenAIPromptBuilderTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct OpenAIPromptBuilderTests {

    @Test func builds_prompt_including_tool_calls_and_results() async throws {
        let toolCall = ToolCall(
            id: "call_abc123",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: "{\"city\":\"SF\"}")
        )

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are helpful.", tool_calls: nil, tool_call_id: nil),
            ChatMessage(role: "user", content: "Weather?", tool_calls: nil, tool_call_id: nil),
            ChatMessage(role: "assistant", content: nil, tool_calls: [toolCall], tool_call_id: nil),
            ChatMessage(
                role: "tool",
                content: "{\"temp_c\":18,\"summary\":\"Foggy\"}",
                tool_calls: nil,
                tool_call_id: "call_abc123"
            ),
        ]

        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)

        #expect(prompt.contains("System:"))
        #expect(prompt.contains("User:"))
        #expect(prompt.contains("Assistant (tool call):"))
        #expect(prompt.contains("function: get_weather"))
        #expect(prompt.contains("arguments: {\"city\":\"SF\"}"))
        #expect(prompt.contains("Tool(get_weather) result:"))
        #expect(prompt.contains("\"temp_c\":18"))
        #expect(prompt.hasSuffix("Assistant:"))
    }
}
