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

    /// Assistant tool-call turns must be preserved in the MLX chat sequence,
    /// even when the assistant produced no prose content. Tool results are
    /// labeled with the function name so the model can correlate them.
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
        #expect(asst.content.contains("<tool_call>"))
        #expect(asst.content.contains("\"name\": \"get_weather\""))
        #expect(asst.content.contains("\"city\":\"Tokyo\""))

        let tool = mapped[1]
        #expect(tool.role == .tool)
        #expect(tool.content.contains("[tool: get_weather]"))
        #expect(tool.content.contains("\"temp\":72"))
    }

    /// Mixed assistant turns (text content + tool_calls) must keep both —
    /// the prose AND the tool-call serialization. Today's HTTPHandler agent
    /// loop produces these on every iteration after a "reasoning + tool" turn.
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
        #expect(asst.content.contains("Let me search for that."))
        #expect(asst.content.contains("<tool_call>"))
        #expect(asst.content.contains("\"name\": \"search\""))
    }

    /// Multi-turn tool conversation: full round-trip preserves the
    /// assistant -> tool -> assistant -> tool -> user sequence with each
    /// tool result labelled by its originating call's function name.
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
        #expect(mapped[1].content.contains("get_weather"))
        #expect(mapped[2].role == .tool)
        #expect(mapped[2].content.contains("[tool: get_weather]"))
        #expect(mapped[3].role == .assistant)
        #expect(mapped[3].content.contains("Now the time."))
        #expect(mapped[3].content.contains("get_time"))
        #expect(mapped[4].role == .tool)
        #expect(mapped[4].content.contains("[tool: get_time]"))
        #expect(mapped[5].role == .user)
    }
}
