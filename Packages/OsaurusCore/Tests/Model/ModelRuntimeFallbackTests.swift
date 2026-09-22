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
    @Test(arguments: ["function", "tool_name", "tool", "name"], [false, true])
    func argumentsHandleEveryJSONShape(shape: String, wrapped: Bool) throws {
        let cases: [(String?, String?)] = [
            (nil, "{}"),
            ("null", "{}"),
            ("5", nil),
            ("true", nil),
            ("false", nil),
            (#""{\"city\":\"SF\"}""#, #"{"city":"SF"}"#),
            (#"[{"city":"SF"},null]"#, #"[{"city":"SF"},null]"#),
            (#"{"z":null,"city":"SF"}"#, #"{"city":"SF","z":null}"#),
        ]
        for (arguments, expected) in cases {
            let field = arguments.map { ",\"arguments\":\($0)" } ?? ""
            let json =
                shape == "function"
                ? "{\"function\":{\"name\":\"get_weather\"\(field)}}"
                : "{\"\(shape)\":\"get_weather\"\(field)}"
            let text = wrapped ? "<tool_call>\(json)</tool_call>" : "prefix \(json) suffix"
            let detected = RemoteToolDetection.detectInlineToolCall(in: text, tools: [makeWeatherTool()])
            #expect(detected?.1 == expected, "shape=\(shape), arguments=\(arguments ?? "missing"), wrapped=\(wrapped)")
            if expected != nil { #expect(detected?.0 == "get_weather") }
        }
    }

    @Test func invalidExplicitArgumentsDoNotFallThroughToTopLevelArguments() {
        let text = #"{"tool":"get_weather","arguments":5,"city":"Oslo"}"#
        #expect(RemoteToolDetection.detectInlineToolCall(in: text, tools: [makeWeatherTool()]) == nil)
    }

    @Test func parametersAliasPreservesStringsAndNull() {
        for (arguments, expected) in [("null", "{}"), (#""{\"city\":\"SF\"}""#, #"{"city":"SF"}"#)] {
            let text = "{\"tool\":\"get_weather\",\"parameters\":\(arguments)}"
            #expect(RemoteToolDetection.detectInlineToolCall(in: text, tools: [makeWeatherTool()])?.1 == expected)
        }
    }

}
