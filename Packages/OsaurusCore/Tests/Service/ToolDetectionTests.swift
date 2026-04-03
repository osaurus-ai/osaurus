//
//  ToolDetectionTests.swift
//  osaurusTests
//
//  Tests that StreamAccumulator correctly detects tool calls across all
//  supported ToolCallFormat variants by delegating to the upstream
//  ToolCallProcessor (mlx-swift-lm / MLXLMCommon).
//
//  Previously this file tested the now-deleted ToolDetection.swift helper.
//  Detection logic now lives entirely in the upstream library and is exercised
//  here end-to-end through StreamAccumulator.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

// MARK: - Helpers

/// Builds an AsyncStream<TokenGeneration> that yields one .token event per
/// character of `text` (using Unicode scalar values, matching StubTokenizer).
private func tokenStream(for text: String) -> AsyncStream<TokenGeneration> {
    AsyncStream { continuation in
        for scalar in text.unicodeScalars {
            continuation.yield(.token(Int(scalar.value)))
        }
        continuation.finish()
    }
}

/// Drains a StreamAccumulator and returns all emitted events.
private func collectEvents(
    text: String,
    tool: OsaurusCore.Tool,
    format: ToolCallFormat,
    stopSequences: [String] = []
) async throws -> [ModelRuntimeEvent] {
    let toolsSpec = [tool.toTokenizerToolSpec()]
    let acc = StreamAccumulator.accumulate(
        events: tokenStream(for: text),
        tokenizer: StubTokenizer(),
        stopSequences: stopSequences,
        tools: [tool],
        toolCallFormat: format,
        toolsSpec: toolsSpec
    )
    var events: [ModelRuntimeEvent] = []
    for await event in acc { events.append(event) }
    return events
}

/// Returns the single toolInvocation event from a stream, or nil.
private func detectToolCall(
    text: String,
    tool: OsaurusCore.Tool,
    format: ToolCallFormat,
    stopSequences: [String] = []
) async throws -> (name: String, argsJSON: String)? {
    let events = try await collectEvents(
        text: text,
        tool: tool,
        format: format,
        stopSequences: stopSequences
    )
    for event in events {
        if case .toolInvocation(let name, let args) = event { return (name, args) }
    }
    return nil
}

private func makeTool(_ name: String, params: [String: OsaurusCore.JSONValue] = [:]) -> OsaurusCore.Tool {
    OsaurusCore.Tool(
        type: "function",
        function: ToolFunction(
            name: name,
            description: "Test tool \(name)",
            parameters: .object(params)
        )
    )
}

// MARK: - JSON format (Qwen2 / Qwen3 / Llama / most models)
// Format: <tool_call>{"name":"fn","arguments":{...}}</tool_call>

@Suite("ToolDetection - JSON format (.json)")
struct ToolDetectionJSONFormatTests {

    @Test func detectsBasicJsonToolCall() async throws {
        let text = #"<tool_call>{"name":"get_weather","arguments":{"city":"Paris"}}</tool_call>"#
        let result = try await detectToolCall(text: text, tool: makeTool("get_weather"), format: .json)
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Paris") == true)
    }

    @Test func detectsJsonToolCallWithWhitespace() async throws {
        let text = """
            <tool_call>
            {"name": "search", "arguments": {"query": "swift concurrency"}}
            </tool_call>
            """
        let result = try await detectToolCall(text: text, tool: makeTool("search"), format: .json)
        #expect(result?.name == "search")
        #expect(result?.argsJSON.contains("swift concurrency") == true)
    }

    @Test func detectsJsonToolCallWithPreamble() async throws {
        let text = """
            I'll check the weather for you.
            <tool_call>{"name":"get_weather","arguments":{"city":"Tokyo"}}</tool_call>
            """
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .json
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Tokyo") == true)
    }

    @Test func emitsTextBeforeToolCall() async throws {
        let text = #"Hello! <tool_call>{"name":"fn","arguments":{}}</tool_call>"#
        let events = try await collectEvents(text: text, tool: makeTool("fn"), format: .json)
        let tokens = events.compactMap { if case .tokens(let s) = $0 { return s } else { return nil } }
        // Some text before the tool call should be visible
        #expect(!tokens.joined().isEmpty)
        // And the tool invocation should be the last event
        if case .toolInvocation(let n, _) = events.last {
            #expect(n == "fn")
        } else {
            Issue.record("Expected last event to be toolInvocation, got \(String(describing: events.last))")
        }
    }

    @Test func returnsNilForNoToolCall() async throws {
        let text = "Just a normal response with no tool calls."
        let result = try await detectToolCall(text: text, tool: makeTool("get_weather"), format: .json)
        #expect(result == nil)
    }

    @Test func detectsNestedArguments() async throws {
        let text =
            #"<tool_call>{"name":"create_task","arguments":{"task":{"title":"Buy milk","priority":1}}}</tool_call>"#
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("create_task"),
            format: .json
        )
        #expect(result?.name == "create_task")
        #expect(result?.argsJSON.contains("Buy milk") == true)
    }

    @Test func detectsToolCallInStreamedOutput() async throws {
        // In real usage, the model only generates its current response in the stream.
        // History is in the prompt, not the generated output.  The first (and only)
        // <tool_call> block in the stream is the intended tool call.
        let current = #"<tool_call>{"name":"search","arguments":{"query":"swift async"}}</tool_call>"#

        let result = try await detectToolCall(
            text: current,
            tool: makeTool("search"),
            format: .json
        )
        #expect(result?.name == "search")
        #expect(result?.argsJSON.contains("swift async") == true)
    }

    @Test func detectsFirstToolCallInStream() async throws {
        // If the stream (unusually) contains multiple tool call blocks back-to-back,
        // the accumulator fires on the FIRST complete call and stops generation.
        let first = #"<tool_call>{"name":"get_weather","arguments":{"city":"A"}}</tool_call>"#
        let second = #"<tool_call>{"name":"search","arguments":{"query":"x"}}</tool_call>"#
        let text = first + "\n" + second

        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .json
        )
        // Fires on the first complete tool call found in the stream.
        #expect(result?.name == "get_weather")
    }

    @Test func detectsJsonToolCallChunkedStreaming() async throws {
        // Simulate the model emitting the tool call one small chunk at a time.
        let full = #"<tool_call>{"name":"get_weather","arguments":{"city":"Berlin"}}</tool_call>"#
        // tokenStream already streams character-by-character; this verifies streaming works.
        let result = try await detectToolCall(text: full, tool: makeTool("get_weather"), format: .json)
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Berlin") == true)
    }

    @Test func noToolCallEventWhenToolsNil() async throws {
        let text = #"<tool_call>{"name":"get_weather","arguments":{}}</tool_call>"#
        // Pass nil tools — processor should never be created.
        let acc = StreamAccumulator.accumulate(
            events: tokenStream(for: text),
            tokenizer: StubTokenizer(),
            stopSequences: [],
            tools: nil,
            toolCallFormat: .json
        )
        var events: [ModelRuntimeEvent] = []
        for await e in acc { events.append(e) }
        let hasInvocation = events.contains { if case .toolInvocation = $0 { return true } else { return false } }
        #expect(!hasInvocation)
        // The raw text should be emitted as tokens instead.
        let allText = events.compactMap { if case .tokens(let s) = $0 { return s } else { return nil } }.joined()
        #expect(!allText.isEmpty)
    }
}

// MARK: - xmlFunction format (Qwen3.5 / Nemotron)
// Format: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>

@Suite("ToolDetection - xmlFunction format (.xmlFunction)")
struct ToolDetectionXMLFunctionFormatTests {

    @Test func detectsBasicXmlFunctionCall() async throws {
        let text = """
            <tool_call>
            <function=get_weather>
            <parameter=city>Paris</parameter>
            </function>
            </tool_call>
            """
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .xmlFunction
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Paris") == true)
    }

    @Test func detectsXmlFunctionWithMultipleParams() async throws {
        let text = """
            <tool_call>
            <function=get_weather>
            <parameter=city>Tokyo</parameter>
            <parameter=unit>celsius</parameter>
            </function>
            </tool_call>
            """
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .xmlFunction
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Tokyo") == true)
        #expect(result?.argsJSON.contains("celsius") == true)
    }

    @Test func detectsXmlFunctionNoArguments() async throws {
        let text = "<tool_call>\n<function=get_current_datetime>\n</function>\n</tool_call>"
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_current_datetime"),
            format: .xmlFunction
        )
        #expect(result?.name == "get_current_datetime")
        // argsJSON should be an empty object
        #expect(result?.argsJSON == "{}" || result?.argsJSON == "{ }")
    }

    @Test func detectsXmlFunctionWithPreamble() async throws {
        let text = """
            I'll check the weather for you.
            <tool_call>
            <function=get_weather>
            <parameter=city>Sydney</parameter>
            </function>
            </tool_call>
            """
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .xmlFunction
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Sydney") == true)
    }

    @Test func detectsXmlFunctionInlineOnOneLine() async throws {
        let text = "<tool_call><function=search><parameter=query>swift</parameter></function></tool_call>"
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("search"),
            format: .xmlFunction
        )
        #expect(result?.name == "search")
        #expect(result?.argsJSON.contains("swift") == true)
    }

    @Test func detectsXmlFunctionChunkedStreaming() async throws {
        // Character-by-character streaming — verifies the processor buffers correctly.
        let text = "<tool_call>\n<function=get_weather>\n<parameter=city>London</parameter>\n</function>\n</tool_call>"
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .xmlFunction
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("London") == true)
    }

    @Test func doesNotFireOnPlainJson_xmlFunctionFormat() async throws {
        // If the model emits plain JSON tool call syntax but the format is .xmlFunction,
        // it should NOT be detected (wrong format — format mismatch means no tool call).
        let text = #"<tool_call>{"name":"get_weather","arguments":{"city":"Paris"}}</tool_call>"#
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .xmlFunction
        )
        // XMLFunctionParser expects <function=name> inside; plain JSON won't match.
        #expect(result == nil)
    }
}

// MARK: - Stop-sequence interaction with tool calls

@Suite("ToolDetection - stop sequence interaction")
struct ToolDetectionStopSequenceTests {

    @Test func jsonToolCallDetectedWhenStopSequenceIsEndTag() async throws {
        // The stop sequence is </tool_call> — generation halts after the closing tag.
        // The processor must still detect the tool call from the buffered content.
        let text = #"<tool_call>{"name":"get_weather","arguments":{"city":"Rome"}}</tool_call>"#
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .json,
            stopSequences: ["</tool_call>"]
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Rome") == true)
    }

    @Test func stopSequenceTruncatesNormalTextWhenNoToolCall() async throws {
        let text = "Hello there! STOP rest ignored"
        let acc = StreamAccumulator.accumulate(
            events: tokenStream(for: text),
            tokenizer: StubTokenizer(),
            stopSequences: ["STOP"],
            tools: nil,
            toolCallFormat: .json
        )
        var out = ""
        for await e in acc { if case .tokens(let s) = e { out += s } }
        #expect(out == "Hello there! ")
    }

    @Test func toolCallDetectedBeforeStopSequenceInSameBuffer() async throws {
        // Tool call appears, then a stop sequence — tool call wins.
        let text = #"<tool_call>{"name":"fn","arguments":{}}</tool_call>END"#
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("fn"),
            format: .json,
            stopSequences: ["END"]
        )
        #expect(result?.name == "fn")
    }
}

// MARK: - EOS-triggered detection (Mistral format)
// Mistral's end tag is the EOS token itself — it never appears as text.
// processEOS() must flush the buffer.

@Suite("ToolDetection - EOS flush (.mistral)")
struct ToolDetectionEOSTests {

    @Test func mistralToolCallDetectedAtEOS() async throws {
        // Mistral emits [TOOL_CALLS]fn [ARGS]{...} — no closing text tag,
        // the EOS token terminates it. processEOS() must extract the call.
        let text = #"[TOOL_CALLS]get_weather [ARGS]{"city": "Berlin"}"#
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .mistral
        )
        #expect(result?.name == "get_weather")
        #expect(result?.argsJSON.contains("Berlin") == true)
    }

    @Test func mistralNoToolCallForPlainText() async throws {
        let text = "Just a normal response."
        let result = try await detectToolCall(
            text: text,
            tool: makeTool("get_weather"),
            format: .mistral
        )
        #expect(result == nil)
    }
}

// MARK: - Argument serialisation round-trip

@Suite("ToolDetection - argument serialisation")
struct ToolDetectionArgumentSerializationTests {

    @Test func argsJSONIsValidJSON() async throws {
        let text = #"<tool_call>{"name":"fn","arguments":{"a":"hello","b":42}}</tool_call>"#
        let result = try await detectToolCall(text: text, tool: makeTool("fn"), format: .json)
        #expect(result != nil)
        let data = result!.argsJSON.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["a"] as? String == "hello")
        #expect(obj?["b"] as? Int == 42)
    }

    @Test func argsJSONForEmptyArguments() async throws {
        let text = #"<tool_call>{"name":"fn","arguments":{}}</tool_call>"#
        let result = try await detectToolCall(text: text, tool: makeTool("fn"), format: .json)
        #expect(result?.argsJSON == "{}")
    }

    @Test func xmlFunctionArgsJSONIsValidJSON() async throws {
        let text = "<tool_call><function=fn><parameter=city>Paris</parameter></function></tool_call>"
        let result = try await detectToolCall(text: text, tool: makeTool("fn"), format: .xmlFunction)
        #expect(result != nil)
        let data = result!.argsJSON.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["city"] as? String == "Paris")
    }
}
