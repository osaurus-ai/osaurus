//
//  ModelRuntimeMappingTests.swift
//  osaurusTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct ModelRuntimeMappingTests {

    // MARK: - Multi-turn tool history fidelity
    //
    // `mapOpenAIChatToMLX` used to serialize assistant tool_calls into the
    // `content` string as Qwen-style `<tool_call>{...}</tool_call>` XML and
    // prefix tool results with `[tool: <name>]`. vmlx ≥ a99efeb added
    // structured `Chat.Message.toolCalls` / `toolCallId` fields and a
    // `DefaultMessageGenerator` that renders them into the Jinja dict under
    // `message.tool_calls`, so every template that reads
    // `message.tool_calls[i]` (MiniMax, Llama 3.1/3.2, Qwen 2.5, Mistral
    // Large, canonical OpenAI) now receives structured state instead of
    // string-embedded XML. These tests lock in the new structured flow.

    @Test func preservesAssistantToolCallTurns() throws {
        let toolCall = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(
                name: "get_weather",
                arguments: "{\"city\":\"Tokyo\"}"
            )
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let toolMsg = ChatMessage(
            role: "tool",
            content: "{\"temp\":72}",
            tool_calls: nil,
            tool_call_id: "call_1"
        )

        let mapped = ModelRuntime.mapOpenAIChatToMLX([assistant, toolMsg])

        #expect(mapped.count == 2, "assistant tool_call turn must not be dropped")

        let asst = mapped[0]
        #expect(asst.role == .assistant)
        // Content no longer carries the XML; structured field does.
        #expect(asst.content == "")
        #expect(asst.toolCalls?.count == 1)
        #expect(asst.toolCalls?.first?.function.name == "get_weather")
        if case .string(let city) = asst.toolCalls?.first?.function.arguments["city"] {
            #expect(city == "Tokyo")
        } else {
            Issue.record("expected arguments['city'] to decode as .string(\"Tokyo\")")
        }

        let tool = mapped[1]
        #expect(tool.role == .tool)
        // Tool content is now raw — no `[tool: name]` prefix; correlation
        // flows through `toolCallId` which the template binds to the
        // originating assistant call.
        #expect(tool.content == "{\"temp\":72}")
        #expect(tool.toolCallId == "call_1")
    }

    @Test func preservesMixedAssistantTurns() throws {
        let toolCall = ToolCall(
            id: "call_a",
            type: "function",
            function: ToolCallFunction(name: "search", arguments: "{\"q\":\"hi\"}")
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: "Let me search for that.",
            tool_calls: [toolCall],
            tool_call_id: nil
        )

        let mapped = ModelRuntime.mapOpenAIChatToMLX([assistant])
        #expect(mapped.count == 1)
        let asst = mapped[0]
        #expect(asst.role == .assistant)
        // Prose stays as content; tool call goes to structured field.
        #expect(asst.content == "Let me search for that.")
        #expect(asst.toolCalls?.count == 1)
        #expect(asst.toolCalls?.first?.function.name == "search")
    }

    @Test func multiTurnToolHistoryRoundTrip() throws {
        let user1 = ChatMessage(role: "user", content: "what's the weather and time?")
        let weather = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: "{}")
        )
        let asst1 = ChatMessage(role: "assistant", content: nil, tool_calls: [weather], tool_call_id: nil)
        let tool1 = ChatMessage(role: "tool", content: "{\"f\":72}", tool_calls: nil, tool_call_id: "c1")
        let time = ToolCall(
            id: "c2",
            type: "function",
            function: ToolCallFunction(name: "get_time", arguments: "{}")
        )
        let asst2 = ChatMessage(
            role: "assistant",
            content: "Now the time.",
            tool_calls: [time],
            tool_call_id: nil
        )
        let tool2 = ChatMessage(role: "tool", content: "12:34", tool_calls: nil, tool_call_id: "c2")
        let user2 = ChatMessage(role: "user", content: "thanks")

        let mapped = ModelRuntime.mapOpenAIChatToMLX([user1, asst1, tool1, asst2, tool2, user2])
        #expect(mapped.count == 6)
        #expect(mapped[0].role == .user)
        #expect(mapped[1].role == .assistant)
        #expect(mapped[1].toolCalls?.first?.function.name == "get_weather")
        #expect(mapped[2].role == .tool)
        #expect(mapped[2].toolCallId == "c1")
        #expect(mapped[3].role == .assistant)
        #expect(mapped[3].content == "Now the time.")
        #expect(mapped[3].toolCalls?.first?.function.name == "get_time")
        #expect(mapped[4].role == .tool)
        #expect(mapped[4].toolCallId == "c2")
        #expect(mapped[5].role == .user)
    }

    /// Empty assistant turn (no content AND no tool_calls) must still be
    /// dropped so downstream templates don't see a stray empty message.
    @Test func skipsFullyEmptyAssistantTurns() throws {
        let empty = ChatMessage(role: "assistant", content: nil, tool_calls: nil, tool_call_id: nil)
        let whitespace = ChatMessage(role: "assistant", content: "   \n  ", tool_calls: nil, tool_call_id: nil)
        let valid = ChatMessage(role: "user", content: "hello")
        let mapped = ModelRuntime.mapOpenAIChatToMLX([empty, whitespace, valid])
        #expect(mapped.count == 1)
        #expect(mapped[0].role == .user)
    }

    /// Malformed / non-object arguments must not crash the mapper — they
    /// decode to an empty dict and the tool call still emits.
    @Test func handlesMalformedArgumentsJson() throws {
        let toolCall = ToolCall(
            id: "c",
            type: "function",
            function: ToolCallFunction(name: "f", arguments: "not json")
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let mapped = ModelRuntime.mapOpenAIChatToMLX([assistant])
        #expect(mapped.count == 1)
        #expect(mapped[0].toolCalls?.count == 1)
        #expect(mapped[0].toolCalls?.first?.function.name == "f")
        #expect(mapped[0].toolCalls?.first?.function.arguments.isEmpty == true)
    }
}
