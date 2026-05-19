//
//  DSV4ParserPipelineTests.swift
//  OsaurusCoreTests
//

import Foundation
import MLXLMCommon
import Testing

@Suite("DSV4 parser pipeline")
struct DSV4ParserPipelineTests {
    @Test("think_xml reasoning and DSML tool calls route to separate events")
    func reasoningAndDSMLToolCallsStaySeparated() throws {
        var reasoningParser = try #require(
            ReasoningParser.forPrompt(
                stampName: "think_xml",
                promptTail: "<\u{FF5C}Assistant\u{FF5C}><think>"
            )
        )
        let toolCallProcessor = ToolCallProcessor(format: .dsml)
        var events: [Generation] = []

        func route(_ text: String, channel: GenerationTextChannel) {
            events.append(
                contentsOf: routeGenerationText(
                    text,
                    channel: channel,
                    through: toolCallProcessor
                )
            )
        }

        for raw in [
            "Need the weather</think>",
            "<\u{FF5C}DSML\u{FF5C}tool_calls>\n",
            "<\u{FF5C}DSML\u{FF5C}invoke name=\"get_weather\">\n",
            "<\u{FF5C}DSML\u{FF5C}parameter name=\"location\" string=\"true\">Paris</\u{FF5C}DSML\u{FF5C}parameter>\n",
            "</\u{FF5C}DSML\u{FF5C}invoke>\n",
            "</\u{FF5C}DSML\u{FF5C}tool_calls>",
        ] {
            for segment in reasoningParser.feed(raw) {
                switch segment {
                case .reasoning(let reasoning):
                    route(reasoning, channel: .reasoning)
                case .content(let content):
                    route(content, channel: .content)
                }
            }
        }
        for segment in reasoningParser.flush() {
            switch segment {
            case .reasoning(let reasoning):
                route(reasoning, channel: .reasoning)
            case .content(let content):
                route(content, channel: .content)
            }
        }
        if let visible = toolCallProcessor.processEOS() {
            route(visible, channel: .content)
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let reasoning = events.compactMap(\.reasoning).joined()
        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(reasoning == "Need the weather")
        #expect(visible.isEmpty, "DSML markup must not leak as visible text: \(visible)")
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments["location"] == .string("Paris"))
    }
}
