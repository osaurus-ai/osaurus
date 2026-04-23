//
//  FoundationMLXParityTests.swift
//  osaurusTests
//
//  Asserts that the same `ChatMessage[]` tool history produces semantically
//  equivalent model-visible context for both backends:
//  - Foundation goes through `OpenAIPromptBuilder.buildPrompt`.
//  - MLX goes through `ModelRuntime.mapOpenAIChatToMLX`.
//
//  Surface formatting differs (text-prompt vs structured Chat.Message), but
//  every multi-turn conversation must preserve the SAME information: each
//  tool result has a matching upstream assistant tool-call declaration, and
//  every tool name appears at least once in each backend's representation.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct FoundationMLXParityTests {

    /// Build a representative multi-turn tool conversation:
    /// system, user, assistant(content+tool_call), tool, assistant(content+tool_call), tool, user.
    private static func sampleHistory() -> [ChatMessage] {
        let weather = ToolCall(
            id: "c_weather",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")
        )
        let time = ToolCall(
            id: "c_time",
            type: "function",
            function: ToolCallFunction(name: "get_time", arguments: "{\"tz\":\"Asia/Tokyo\"}")
        )
        return [
            ChatMessage(role: "system", content: "You are a helpful agent."),
            ChatMessage(role: "user", content: "what's the weather and time in Tokyo?"),
            ChatMessage(
                role: "assistant",
                content: "Let me check the weather first.",
                tool_calls: [weather],
                tool_call_id: nil
            ),
            ChatMessage(
                role: "tool",
                content: "{\"f\":72}",
                tool_calls: nil,
                tool_call_id: "c_weather"
            ),
            ChatMessage(
                role: "assistant",
                content: "Now the time.",
                tool_calls: [time],
                tool_call_id: nil
            ),
            ChatMessage(
                role: "tool",
                content: "12:34",
                tool_calls: nil,
                tool_call_id: "c_time"
            ),
            ChatMessage(role: "user", content: "thanks"),
        ]
    }

    /// Both backends must preserve every tool name (as a call AND a result
    /// correlation). Foundation embeds tool names in the prompt string; MLX
    /// carries them as structured `Chat.Message.toolCalls[i].function.name`.
    @Test func bothBackendsPreserveToolNames() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)
        let mlxToolCallNames =
            mlxMapped
            .flatMap { $0.toolCalls ?? [] }
            .map(\.function.name)

        for toolName in ["get_weather", "get_time"] {
            #expect(
                foundationPrompt.contains(toolName),
                "Foundation prompt must mention \(toolName)"
            )
            #expect(
                mlxToolCallNames.contains(toolName),
                "MLX mapping must surface \(toolName) via Chat.Message.toolCalls"
            )
        }
    }

    /// Every `tool` role message must correlate back to its originating call.
    /// Foundation embeds a `Tool(<name>) result:` label in the prompt; MLX
    /// carries `Chat.Message.toolCallId`, which the Jinja template resolves
    /// against the preceding assistant's `message.tool_calls[i].id`.
    @Test func toolResultsAreCorrelatedToTheirCalls() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)

        // Foundation surface: textual label in the prompt.
        #expect(foundationPrompt.contains("Tool(get_weather) result:"))
        #expect(foundationPrompt.contains("Tool(get_time) result:"))

        // MLX surface: structured `toolCallId` matches each originating id.
        let toolMessages = mlxMapped.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        let toolIds = toolMessages.map(\.toolCallId)
        #expect(toolIds.contains("c_weather"))
        #expect(toolIds.contains("c_time"))
    }

    /// Both backends must preserve assistant prose alongside tool calls so
    /// the model's reasoning is not lost between turns.
    @Test func assistantProseAndToolCallsCoexist() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)

        #expect(foundationPrompt.contains("Let me check the weather first."))
        #expect(foundationPrompt.contains("Now the time."))

        // MLX: prose stays in `content`; calls live in `toolCalls`.
        let assistants = mlxMapped.filter { $0.role == .assistant }
        #expect(assistants.count == 2)

        #expect(assistants[0].content == "Let me check the weather first.")
        #expect(assistants[0].toolCalls?.first?.function.name == "get_weather")

        #expect(assistants[1].content == "Now the time.")
        #expect(assistants[1].toolCalls?.first?.function.name == "get_time")
    }

    /// Round-trip count: MLX mapping must not drop any role
    /// (system, user, assistant turns, tool turns, final user).
    @Test func mlxMappingRoundTripsAllRoles() throws {
        let mapped = ModelRuntime.mapOpenAIChatToMLX(Self.sampleHistory())
        #expect(mapped.count == 7)
        #expect(mapped[0].role == .system)
        #expect(mapped[1].role == .user)
        #expect(mapped[2].role == .assistant)
        #expect(mapped[3].role == .tool)
        #expect(mapped[4].role == .assistant)
        #expect(mapped[5].role == .tool)
        #expect(mapped[6].role == .user)
    }
}
