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

    /// Both backends must preserve every tool name (as a call AND a labelled result).
    @Test func bothBackendsPreserveToolNames() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)
        let mlxJoined = mlxMapped.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")

        for toolName in ["get_weather", "get_time"] {
            #expect(
                foundationPrompt.contains(toolName),
                "Foundation prompt must mention \(toolName)"
            )
            #expect(mlxJoined.contains(toolName), "MLX mapping must mention \(toolName)")
        }
    }

    /// Every `tool` role message must have a labelled correlation to its
    /// originating function in BOTH backends.
    @Test func toolResultsAreCorrelatedToTheirCalls() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)

        // Foundation labels tool messages with `Tool(<name>) result:`.
        #expect(foundationPrompt.contains("Tool(get_weather) result:"))
        #expect(foundationPrompt.contains("Tool(get_time) result:"))

        // MLX labels tool messages with `[tool: <name>]` prefix.
        let toolMessages = mlxMapped.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        let toolContents = toolMessages.map(\.content)
        #expect(toolContents.contains { $0.contains("[tool: get_weather]") })
        #expect(toolContents.contains { $0.contains("[tool: get_time]") })
    }

    /// Both backends must preserve assistant prose alongside tool calls so
    /// the model's reasoning is not lost between turns.
    @Test func assistantProseAndToolCallsCoexist() throws {
        let history = Self.sampleHistory()
        let foundationPrompt = OpenAIPromptBuilder.buildPrompt(from: history)
        let mlxMapped = ModelRuntime.mapOpenAIChatToMLX(history)

        #expect(foundationPrompt.contains("Let me check the weather first."))
        #expect(foundationPrompt.contains("Now the time."))

        let asstContents = mlxMapped.filter { $0.role == .assistant }.map(\.content)
        #expect(asstContents.contains { $0.contains("Let me check the weather first.") && $0.contains("get_weather") })
        #expect(asstContents.contains { $0.contains("Now the time.") && $0.contains("get_time") })
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
