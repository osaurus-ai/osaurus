//
//  ToolDetectionTests.swift
//  osaurusTests
//
//  Tests for ToolDetection — verifies both plain JSON and Qwen XML-wrapped
//  <tool_call> formats are detected correctly.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Helpers

private func tool(_ name: String) -> Tool {
    Tool(
        type: "function",
        function: ToolFunction(
            name: name,
            description: "Test tool \(name)",
            parameters: .object([:])
        )
    )
}

// MARK: - Plain JSON format

@Suite("ToolDetectionTests")
struct ToolDetectionTests {

    // MARK: Plain JSON

    @Test func detectsPlainJsonNameFormat() {
        let text = """
        Sure! {"name": "get_weather", "arguments": {"city": "London"}}
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result?.0 == "get_weather")
        #expect(result?.1.contains("London") == true)
    }

    @Test func detectsPlainJsonToolNameFormat() {
        let text = """
        {"tool_name": "search", "arguments": {"query": "swift testing"}}
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("search")])
        #expect(result?.0 == "search")
    }

    @Test func returnsNilForUnknownToolName() {
        let text = """
        {"name": "unknown_tool", "arguments": {}}
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result == nil)
    }

    @Test func returnsNilForEmptyText() {
        let result = ToolDetection.detectInlineToolCall(in: "", tools: [tool("get_weather")])
        #expect(result == nil)
    }

    @Test func returnsNilForEmptyTools() {
        let text = """
        {"name": "get_weather", "arguments": {}}
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [])
        #expect(result == nil)
    }

    // MARK: Qwen XML format

    @Test func detectsQwenXmlToolCall() {
        let text = """
        <tool_call>
        {"name": "get_weather", "arguments": {"city": "Paris"}}
        </tool_call>
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result?.0 == "get_weather")
        #expect(result?.1.contains("Paris") == true)
    }

    @Test func detectsQwenXmlToolCallInlineFormat() {
        let text = #"<tool_call>{"name": "search", "arguments": {"q": "hello"}}</tool_call>"#
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("search")])
        #expect(result?.0 == "search")
    }

    @Test func detectsQwenXmlToolCallWithPreamble() {
        let text = """
        I'll help you check the weather.
        <tool_call>
        {"name": "get_weather", "arguments": {"city": "Tokyo", "unit": "celsius"}}
        </tool_call>
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result?.0 == "get_weather")
        #expect(result?.1.contains("Tokyo") == true)
    }

    @Test func returnsNilForXmlWithUnknownToolName() {
        let text = """
        <tool_call>
        {"name": "unknown_tool", "arguments": {}}
        </tool_call>
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result == nil)
    }

    @Test func detectsQwenXmlNestedArguments() {
        let text = """
        <tool_call>{"name": "create_task", "arguments": {"task": {"title": "Buy milk", "priority": 1}}}</tool_call>
        """
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("create_task")])
        #expect(result?.0 == "create_task")
        #expect(result?.1.contains("Buy milk") == true)
    }

    @Test func detectsQwenXmlStringArguments() {
        // Qwen sometimes emits arguments as a JSON-encoded string rather than an object
        let argsString = #"{"city": "Berlin"}"#
        let jsonEncoded = try! JSONSerialization.data(withJSONObject: ["name": "get_weather", "arguments": argsString])
        let inner = String(data: jsonEncoded, encoding: .utf8)!
        let text = "<tool_call>\(inner)</tool_call>"
        let result = ToolDetection.detectInlineToolCall(in: text, tools: [tool("get_weather")])
        #expect(result?.0 == "get_weather")
    }

    // MARK: History with prior tool calls

    @Test func detectsNewestToolCallWhenHistoryContainsPriorOne() {
        // Simulates a conversation where a previous turn already contained a <tool_call>
        // block (from a prior tool use). The current generation appends a NEW tool call
        // at the end. The fast path must match the LAST <tool_call> open tag, not the
        // first one from history.
        let previousTurn = """
        <tool_call>
        {"name": "get_weather", "arguments": {"city": "London"}}
        </tool_call>
        """
        let currentGeneration = """
        <tool_call>
        {"name": "search", "arguments": {"query": "swift concurrency"}}
        </tool_call>
        """
        let text = previousTurn + "\n" + currentGeneration
        let result = ToolDetection.detectInlineToolCall(
            in: text,
            tools: [tool("get_weather"), tool("search")]
        )
        // Must detect "search" (the newest), not "get_weather" (the historical one)
        #expect(result?.0 == "search")
        #expect(result?.1.contains("swift concurrency") == true)
    }

    @Test func detectsNewestToolCallWhenHistoryContainsMultiplePriorOnes() {
        // Multiple prior tool calls in history — still must find the last one.
        let history = """
        <tool_call>{"name": "get_weather", "arguments": {"city": "A"}}</tool_call>
        <tool_call>{"name": "get_weather", "arguments": {"city": "B"}}</tool_call>
        """
        let current = #"<tool_call>{"name": "search", "arguments": {"query": "x"}}</tool_call>"#
        let text = history + "\n" + current
        let result = ToolDetection.detectInlineToolCall(
            in: text,
            tools: [tool("get_weather"), tool("search")]
        )
        #expect(result?.0 == "search")
    }
}
