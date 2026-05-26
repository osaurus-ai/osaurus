//
//  ModelRuntimeFallbackTests.swift
//  osaurusTests
//
//  Tests for the remote-provider inline tool-call fallback (RemoteToolDetection).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelRuntimeFallbackTests {

    private func makeWeatherTool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "get_weather",
                description: nil,
                parameters: .object([
                    "city": .string("")
                ])
            )
        )
    }

    @Test func detectsFunctionObjectPattern() throws {
        let tools = [makeWeatherTool()]
        let text =
            "Leading text ... {\"function\":{\"name\":\"get_weather\",\"arguments\":{\"city\":\"SF\"}}} ... trailing"
        let detected = RemoteToolDetection.detectInlineToolCall(in: text, tools: tools)
        #expect(detected != nil)
        #expect(detected?.0 == "get_weather")
        #expect(detected?.1.contains("\"city\":\"SF\"") == true)
    }

    @Test func detectsToolNamePattern() throws {
        let tools = [makeWeatherTool()]
        let text = "prefix {\"tool_name\":\"get_weather\",\"arguments\":{\"city\":\"NYC\"}} suffix"
        let detected = RemoteToolDetection.detectInlineToolCall(in: text, tools: tools)
        #expect(detected != nil)
        #expect(detected?.0 == "get_weather")
        #expect(detected?.1.contains("\"city\":\"NYC\"") == true)
    }

    @Test func detectsToolFieldPatternWithTopLevelArguments() throws {
        let tools = [makeWeatherTool()]
        let text = "prefix {\"tool\":\"get_weather\",\"city\":\"Oslo\"} suffix"
        let detected = RemoteToolDetection.detectInlineToolCall(in: text, tools: tools)
        #expect(detected != nil)
        #expect(detected?.0 == "get_weather")
        #expect(detected?.1.contains("\"city\":\"Oslo\"") == true)
    }

    @Test func ignoresToolResultEnvelopeWithToolField() throws {
        let tools = [makeWeatherTool()]
        let text = #"{"ok":true,"result":{"text":"done"},"tool":"get_weather"}"#
        let detected = RemoteToolDetection.detectInlineToolCall(in: text, tools: tools)
        #expect(detected == nil)
    }
}
