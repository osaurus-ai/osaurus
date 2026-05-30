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

    @Test("malformed live DSV4 DSML aliases route to tools without visible leakage")
    func malformedLiveDSMLAliasesRouteToToolsWithoutVisibleLeakage() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml)
        var events: [Generation] = []

        func route(_ text: String) {
            events.append(
                contentsOf: routeGenerationText(
                    text,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }

        for raw in [
            "<\u{FF5C}DSML\u{FF5C}tool_ccalls>\n",
            "<\u{FF5C}DSML\u{FF5C}invoke name=\"file_read\">\n",
            "<\u{FF5C}DSML\u{FF5C}parameter name=\"path\" string=\"true\">/Users/eric/Desktop/testmandel/mandelbrot.py</\u{FF5C}DSML\u{FF5C}parameter>\n",
            "</\u{FF5C}DSML\u{FF5C}inv>\n",
            "</\u{FF5C}DSML\u{FF5C}tool_cs>",
        ] {
            route(raw)
        }
        if let visible = toolCallProcessor.processEOS() {
            route(visible)
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("DSML"), "Malformed DSML must not leak as visible text: \(visible)")
        #expect(!visible.contains("tool_ccalls"))
        #expect(!visible.contains("tool_cs"))
        #expect(!visible.contains("invoke name"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "file_read")
        #expect(
            call.function.arguments["path"]
                == .string("/Users/eric/Desktop/testmandel/mandelbrot.py")
        )
    }

    @Test("live DSV4 tool_crs alias after bare tool marker routes to a tool call")
    func liveToolCRSAliasAfterBareToolMarkerRoutesToToolCall() throws {
        let dsml = "\u{FF5C}DSML\u{FF5C}"
        let toolCallProcessor = ToolCallProcessor(format: .dsml, tools: lineCountToolSchema())
        var events: [Generation] = []
        let output = """
            -line_count
            <\(dsml)tool_crs>
            <\(dsml)invoke name="line_count">
            <\(dsml)parameter name="text" string="true">alpha
            beta
            gamma</\(dsml)parameter>
            </\(dsml)inv>
            </\(dsml)tool_crs>
            """

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("DSML"), "tool_crs DSML must not leak as visible text: \(visible)")
        #expect(!visible.contains("tool_crs"))
        #expect(!visible.contains("invoke name"))
        #expect(!visible.contains("line_count"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "line_count")
        #expect(call.function.arguments["text"] == .string("alpha\nbeta\ngamma"))
    }

    @Test("ZAYA XML tool parser decodes live HTML line breaks")
    func zayaXMLToolParserDecodesLiveHTMLLineBreaks() throws {
        let toolCallProcessor = ToolCallProcessor(format: .zayaXml, tools: lineCountToolSchema())
        var events: [Generation] = []
        let output = #"""
            <zyphra_tool_call>
            <function=line_count>
            <parameter=text>one<br>two</parameter>
            </function>
            </zyphra_tool_call>
            """#

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("zyphra_tool_call"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "line_count")
        #expect(call.function.arguments["text"] == .string("one\ntwo"))
    }

    @Test("Gemma4 parser routes live Zyphra multiline tool envelope without visible leakage")
    func gemma4ParserRoutesLiveZyphraMultilineToolEnvelopeWithoutVisibleLeakage() throws {
        let toolCallProcessor = ToolCallProcessor(format: .gemma4, tools: lineCountToolSchema())
        var events: [Generation] = []
        let output = #"""
            <zyphra_tool_call>
            <function=line_count
            <parameter=text
            >red
            green
            blue
            </parameter>
            </function>
            </zyphra_tool_call>
            """#

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("zyphra_tool_call"))
        #expect(!visible.contains("function=line_count"))
        #expect(!visible.contains("parameter=text"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "line_count")
        #expect(call.function.arguments["text"] == .string("red\ngreen\nblue"))
    }

    @Test("live DSV4 bare-name JSON split after tool marker routes to a tool call")
    func liveBareNameJSONAfterToolMarkerRoutesToToolCall() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml, tools: lineCountToolSchema())
        var events: [Generation] = []
        let output = #"line_count{"text":"alpha\nbeta\gamma"}"#

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("line_count"))
        #expect(!visible.contains(#"{"text":"#))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "line_count")
        #expect(call.function.arguments["text"] == .string("alpha\nbeta\\gamma"))
    }

    @Test("incomplete DSV4 DSML protocol opener at EOS does not leak to chat")
    func incompleteDSMLProtocolOpenerAtEOSDoesNotLeakToChat() throws {
        let dsml = "\u{FF5C}DSML\u{FF5C}"
        let toolCallProcessor = ToolCallProcessor(format: .dsml, tools: fileReadToolSchema())
        var events: [Generation] = []
        let output = "\n\n<\(dsml)tool_c"

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(calls.isEmpty)
        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("DSML"))
        #expect(!visible.contains("tool_c"))
    }

    @Test("malformed live DSV4 aliases route every folder and git tool without leakage")
    func malformedLiveAliasesRouteFolderAndGitToolsWithoutLeakage() throws {
        let fixtures: [DSMLToolFixture] = [
            .init(
                name: "file_tree",
                parameters: [
                    .init(name: "path", value: ".", string: true, expected: .string(".")),
                    .init(name: "max_depth", value: "2", string: false, expected: .int(2)),
                ]
            ),
            .init(
                name: "file_read",
                parameters: [
                    .init(name: "path", value: "mandelbrot.py", string: true, expected: .string("mandelbrot.py")),
                    .init(name: "start_line", value: "38", string: false, expected: .int(38)),
                    .init(name: "end_line", value: "41", string: false, expected: .int(41)),
                ]
            ),
            .init(
                name: "file_write",
                parameters: [
                    .init(
                        name: "path",
                        value: "osaurus_probe.txt",
                        string: true,
                        expected: .string("osaurus_probe.txt")
                    ),
                    .init(name: "content", value: "alpha\nbeta", string: true, expected: .string("alpha\nbeta")),
                ]
            ),
            .init(
                name: "file_edit",
                parameters: [
                    .init(
                        name: "path",
                        value: "osaurus_probe.txt",
                        string: true,
                        expected: .string("osaurus_probe.txt")
                    ),
                    .init(name: "old_string", value: "alpha", string: true, expected: .string("alpha")),
                    .init(name: "new_string", value: "beta", string: true, expected: .string("beta")),
                ]
            ),
            .init(
                name: "file_search",
                parameters: [
                    .init(name: "pattern", value: "np.clip", string: true, expected: .string("np.clip")),
                    .init(name: "path", value: "mandelbrot.py", string: true, expected: .string("mandelbrot.py")),
                    .init(name: "max_results", value: "3", string: false, expected: .int(3)),
                ]
            ),
            .init(
                name: "shell_run",
                parameters: [
                    .init(name: "command", value: "printf ok", string: true, expected: .string("printf ok")),
                    .init(name: "timeout", value: "5", string: false, expected: .int(5)),
                ]
            ),
            .init(name: "git_status", parameters: []),
            .init(
                name: "git_diff",
                parameters: [
                    .init(name: "path", value: "mandelbrot.py", string: true, expected: .string("mandelbrot.py")),
                    .init(name: "staged", value: "false", string: false, expected: .bool(false)),
                ]
            ),
            .init(
                name: "git_commit",
                parameters: [
                    .init(name: "message", value: "probe commit", string: true, expected: .string("probe commit"))
                ]
            ),
        ]

        for fixture in fixtures {
            let toolCallProcessor = ToolCallProcessor(format: .dsml)
            var events: [Generation] = []

            func route(_ text: String) {
                events.append(
                    contentsOf: routeGenerationText(
                        text,
                        channel: .content,
                        through: toolCallProcessor
                    )
                )
            }

            for raw in liveAliasDSMLLines(for: fixture) {
                route(raw)
            }
            if let visible = toolCallProcessor.processEOS() {
                route(visible)
            }
            events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

            let visible = events.compactMap(\.chunk).joined()
            let calls = events.compactMap(\.toolCall)

            #expect(
                visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(fixture.name) DSML leaked visible text: \(visible)"
            )
            #expect(!visible.contains("DSML"), "\(fixture.name) leaked DSML marker: \(visible)")
            #expect(!visible.contains("tool_ccalls"), "\(fixture.name) leaked start alias: \(visible)")
            #expect(!visible.contains("tool_cs"), "\(fixture.name) leaked end alias: \(visible)")
            #expect(calls.count == 1, "\(fixture.name) should emit one tool call")

            let call = calls.first
            #expect(call?.function.name == fixture.name)
            for parameter in fixture.parameters {
                assertArgument(
                    call?.function.arguments[parameter.name],
                    matches: parameter.expected,
                    tool: fixture.name,
                    parameter: parameter.name
                )
            }
        }
    }

    @Test("DSV4 top-level JSON tool fallback routes only schema-valid calls")
    func topLevelJSONToolFallbackRoutesOnlySchemaValidCalls() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml, tools: fileReadToolSchema())
        var events: [Generation] = []
        let output = """
            {"tool":"file_read","path":"mandelbrot.py","start_line":38,"end_line":41}
            """

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "file_read")
        #expect(call.function.arguments["path"] == .string("mandelbrot.py"))
        #expect(call.function.arguments["start_line"] == .int(38))
        #expect(call.function.arguments["end_line"] == .int(41))
    }

    @Test("DSV4 malformed JSON tool-shaped answer is quarantined without visible leakage")
    func malformedJSONToolShapedAnswerIsQuarantinedWithoutVisibleLeakage() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml, tools: fileReadToolSchema())
        var events: [Generation] = []
        let output = """
            {"tool":"file_read","r":"np.clip(esc * 4.0 - 1.0, 0.0, 1.0)","g":"np.clip(1.0 - np.abs(esc * 2.0 - 1.0), 0.0, 1.0)","b":"np.clip(1.0 - esc * 2.0, 0.0, 1.0)"}
            """

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("\"tool\":\"file_read\""))
        #expect(!visible.contains("np.clip"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "file_read")
        #expect(call.function.arguments["path"] == nil)
        #expect(call.function.arguments["_error"] == .string("invalid_tool_arguments"))
        #expect(call.function.arguments["_field"] == .string("path"))
        #expect(call.function.arguments["r"] == nil)
    }

    @Test("DSV4 schema-less JSON tool fallback routes built-in tool attempts without visible leakage")
    func schemaLessJSONToolFallbackRoutesBuiltInToolAttemptsWithoutVisibleLeakage() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml)
        var events: [Generation] = []
        let output = """
            {"tool":"file_read","r":"np.clip(esc * 4.0 - 1.0, 0.0, 1.0)","g":"np.clip(1.0 - np.abs(esc * 2.0 - 1.0), 0.0, 1.0)","b":"np.clip(1.0 - esc * 2.0, 0.0, 1.0)"}
            """

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("\"tool\":\"file_read\""))
        #expect(!visible.contains("np.clip"))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.function.name == "file_read")
        #expect(call.function.arguments["path"] == nil)
        #expect(
            call.function.arguments["r"]
                == .string("np.clip(esc * 4.0 - 1.0, 0.0, 1.0)")
        )
        #expect(
            call.function.arguments["g"]
                == .string("np.clip(1.0 - np.abs(esc * 2.0 - 1.0), 0.0, 1.0)")
        )
        #expect(
            call.function.arguments["b"]
                == .string("np.clip(1.0 - esc * 2.0, 0.0, 1.0)")
        )
    }

    @Test("DSV4 truncated schema-less JSON tool attempt is quarantined without visible leakage")
    func truncatedSchemaLessJSONToolAttemptIsQuarantinedWithoutVisibleLeakage() throws {
        let toolCallProcessor = ToolCallProcessor(format: .dsml)
        var events: [Generation] = []
        let output = """
            {"tool":"file_read","r":"np.clip(esc * 4.0 - 1.0, 0.0, 1.0)","g":"np.clip(1.0 - np.abs(esc * 2.0 - 1.0), 0.0, 1.0)","b":"np.clip(1.0 - esc * 2.0, 0.0, 1.
            """

        for ch in output {
            events.append(
                contentsOf: routeGenerationText(
                    String(ch),
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        if let visible = toolCallProcessor.processEOS() {
            events.append(
                contentsOf: routeGenerationText(
                    visible,
                    channel: .content,
                    through: toolCallProcessor
                )
            )
        }
        events.append(contentsOf: drainToolCallEvents(from: toolCallProcessor))

        let visible = events.compactMap(\.chunk).joined()
        let calls = events.compactMap(\.toolCall)

        #expect(calls.isEmpty)
        #expect(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!visible.contains("\"tool\":\"file_read\""))
        #expect(!visible.contains("np.clip"))
    }

    private struct DSMLToolFixture {
        let name: String
        let parameters: [DSMLParameterFixture]
    }

    private struct DSMLParameterFixture {
        let name: String
        let value: String
        let string: Bool
        let expected: DSMLExpectedArgument
    }

    private enum DSMLExpectedArgument {
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    private func liveAliasDSMLLines(for fixture: DSMLToolFixture) -> [String] {
        let dsml = "\u{FF5C}DSML\u{FF5C}"
        var lines = [
            "<\(dsml)tool_ccalls>\n",
            "<\(dsml)invoke name=\"\(fixture.name)\">\n",
        ]
        lines += fixture.parameters.map { parameter in
            "<\(dsml)parameter name=\"\(parameter.name)\" string=\"\(parameter.string ? "true" : "false")\">\(parameter.value)</\(dsml)parameter>\n"
        }
        lines += [
            "</\(dsml)inv>\n",
            "</\(dsml)tool_cs>",
        ]
        return lines
    }

    private func assertArgument(
        _ actual: (any Sendable)?,
        matches expected: DSMLExpectedArgument,
        tool: String,
        parameter: String
    ) {
        switch expected {
        case .string(let value):
            #expect(actual as? MLXLMCommon.JSONValue == .string(value), "\(tool).\(parameter) mismatch")
        case .int(let value):
            #expect(actual as? MLXLMCommon.JSONValue == .int(value), "\(tool).\(parameter) mismatch")
        case .bool(let value):
            #expect(actual as? MLXLMCommon.JSONValue == .bool(value), "\(tool).\(parameter) mismatch")
        }
    }

    private func fileReadToolSchema() -> [[String: any Sendable]] {
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"] as [String: any Sendable],
                "start_line": ["type": "integer"] as [String: any Sendable],
                "end_line": ["type": "integer"] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["path"],
        ]
        let function: [String: any Sendable] = [
            "name": "file_read",
            "parameters": parameters,
        ]
        return [
            [
                "type": "function",
                "function": function,
            ] as [String: any Sendable]
        ]
    }

    private func lineCountToolSchema() -> [[String: any Sendable]] {
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"] as [String: any Sendable]
            ] as [String: any Sendable],
            "required": ["text"],
        ]
        let function: [String: any Sendable] = [
            "name": "line_count",
            "parameters": parameters,
        ]
        return [
            [
                "type": "function",
                "function": function,
            ] as [String: any Sendable]
        ]
    }
}
