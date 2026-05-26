//
//  SwiftTransformersTokenizerLoaderTests.swift
//  OsaurusCoreTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SwiftTransformersTokenizerLoaderTests {
    @Test func qwen35LocalTokenizerExposesNoGenerationPromptPrefixForCacheBoundary() async throws {
        let defaultPath = "/Users/eric/models/Qwen3.5-35B-A3B-4bit"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_QWEN35_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            ),
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("chat_template.jinja").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        guard let controllable = tokenizer as? any GenerationPromptControllableTokenizer else {
            Issue.record("SwiftTransformersTokenizerLoader must expose no-generation chat-template rendering")
            return
        }

        let messages: [[String: any Sendable]] = [
            ["role": "user", "content": "Remember graphite-cache."],
            ["role": "assistant", "content": "Stored."],
            ["role": "user", "content": "What did I ask you to remember?"],
        ]
        let context: [String: any Sendable] = ["enable_thinking": false]
        let promptTokens = try controllable.applyChatTemplate(
            messages: messages,
            tools: nil,
            additionalContext: context,
            addGenerationPrompt: true
        )
        let historyTokens = try controllable.applyChatTemplate(
            messages: messages,
            tools: nil,
            additionalContext: context,
            addGenerationPrompt: false
        )

        #expect(!historyTokens.isEmpty)
        #expect(historyTokens.count < promptTokens.count)
        #expect(promptTokens.prefix(historyTokens.count).elementsEqual(historyTokens))
    }

    @Test func zayaVLLocalTokenizerRendersImagePlaceholderFromOsaurusFallback() async throws {
        let defaultPath = "/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_ZAYA_VL_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let content: [[String: any Sendable]] = [
            ["type": "image"],
            ["type": "text", "text": "Describe this image."],
        ]
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": content]],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("<|vision_start|>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<image>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<|vision_end|>"), "Decoded: \(decoded)")
    }

    @Test func gemma4LocalTokenizerRendersUnionToolSchemaTypeNatively() async throws {
        let defaultPath = "/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_GEMMA4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            ),
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("chat_template.jinja").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "write_probe_file",
                description: "Write a small probe file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .array([.string("string"), .string("null")]),
                            "description": .string("Optional path to write."),
                        ])
                    ]),
                    "required": .array([.string("path")]),
                ])
            )
        )

        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Create the probe file."]],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("write_probe_file"), "Decoded: \(decoded)")
        #expect(decoded.contains("Create the probe file."), "Decoded: \(decoded)")
    }

    @Test func gemma4LocalTokenizerRendersFirstTurnChatUIToolSurface() async throws {
        let defaultPath = "/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_GEMMA4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            ),
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("chat_template.jinja").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let snapshot = AgentConfigSnapshot(
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: "Gemma 4 26B A4B it JANG_4M CRACK",
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
        let resolvedTools = await MainActor.run {
            SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .sandbox
            )
        }
        let tokenizerTools = ModelRuntime.makeTokenizerTools(
            tools: resolvedTools,
            toolChoice: .auto
        )

        #expect(!(tokenizerTools?.isEmpty ?? true))
        let arrayTypedPaths = collectArrayTypedSchemaPaths(tokenizerTools as Any)
        #expect(arrayTypedPaths.isEmpty, "Array-valued schema type paths: \(arrayTypedPaths)")

        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Create a file named osaurus_live_probe.txt containing ok.",
                ]
            ],
            tools: tokenizerTools,
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("Create a file named osaurus_live_probe.txt"), "Decoded: \(decoded)")
        #expect(decoded.contains("capabilities_search"), "Decoded: \(decoded)")
    }

    @Test func dsv4LocalTokenizerUsesCanonicalNoChatTemplatePath() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Say ok."]],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(
            decoded.hasPrefix("<\u{FF5C}begin\u{2581}of\u{2581}sentence\u{FF5C}>"),
            "DSV4 bundles have no tokenizer chat_template; Osaurus must route through vmlx's canonical DSV4 encoder path. Decoded: \(decoded)"
        )
        #expect(
            decoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think>"),
            "DSV4 instruct mode must close the reasoning tag in the prompt tail. Decoded: \(decoded)"
        )

        let multiTurnTokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Turn 1."],
                ["role": "assistant", "content": "Answer 1."],
                ["role": "user", "content": "Turn 2."],
            ],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let multiTurnDecoded = tokenizer.decode(
            tokenIds: multiTurnTokenIds,
            skipSpecialTokens: false
        )
        #expect(
            multiTurnDecoded.contains(
                "<\u{FF5C}User\u{FF5C}>Turn 1.<\u{FF5C}Assistant\u{FF5C}></think>Answer 1.<\u{FF5C}end\u{2581}of\u{2581}sentence\u{FF5C}>"
            ),
            "DSV4 prior assistant turns must include the canonical closed-thinking transition. Decoded: \(multiTurnDecoded)"
        )
        #expect(
            multiTurnDecoded.hasSuffix(
                "<\u{FF5C}User\u{FF5C}>Turn 2.<\u{FF5C}Assistant\u{FF5C}></think>"
            ),
            "DSV4 final instruct tail must be closed-thinking. Decoded: \(multiTurnDecoded)"
        )
    }

    @Test func dsv4LocalTokenizerRendersDSMLToolsFromOsaurusToolSpec() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "get_weather",
                description: "Get weather for a city.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "location": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("location")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "system", "content": "Helpful assistant."],
                ["role": "user", "content": "Weather in Paris?"],
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: ["enable_thinking": false]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("## Tools"), "DSV4 canonical template path must render tools. Decoded: \(decoded)")
        #expect(
            decoded.contains("<\u{FF5C}DSML\u{FF5C}tool_calls>"),
            "DSV4 canonical template path must use DSML tool-call blocks. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains("<\u{FF5C}DSML\u{FF5C}invoke name=\"$TOOL_NAME\">"),
            "DSV4 canonical template path must teach DSML invocation syntax. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains("For tools with no parameters"),
            "DSV4 canonical template path must explain no-arg tool invocations. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(
                "<\u{FF5C}DSML\u{FF5C}invoke name=\"$TOOL_NAME_WITHOUT_PARAMETERS\">\n</\u{FF5C}DSML\u{FF5C}invoke>"
            ),
            "DSV4 canonical template path must show an empty DSML invoke for no-arg tools. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains("Do not emit JSON objects for tool calls"),
            "DSV4 canonical template path must reject JSON-shaped tool calls. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains("\"name\":\"get_weather\""),
            "DSV4 canonical template path must include the Osaurus-provided tool schema. Decoded: \(decoded)"
        )
        #expect(
            !decoded.contains("<available_tools>"),
            "DSV4 canonical template path must not use the generic tool dialect. Decoded: \(decoded)"
        )
    }

    @Test func dsv4LocalTokenizerPreservesAssistantToolHistory() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let toolCallArguments: [String: any Sendable] = [
            "city": "Paris",
            "units": "metric",
        ]
        let toolFunction: [String: any Sendable] = [
            "name": "get_weather",
            "arguments": toolCallArguments,
        ]
        let toolCall: [String: any Sendable] = [
            "id": "call_weather_1",
            "type": "function",
            "function": toolFunction,
        ]
        let toolHistoryTokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use the weather tool."],
                ["role": "assistant", "content": "", "tool_calls": [toolCall]],
                ["role": "tool", "content": "{\"temp_c\":18}", "tool_call_id": "call_weather_1"],
                ["role": "user", "content": "Summarize the result."],
            ],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let toolHistoryDecoded = tokenizer.decode(
            tokenIds: toolHistoryTokenIds,
            skipSpecialTokens: false
        )
        #expect(
            toolHistoryDecoded.contains("<\u{FF5C}DSML\u{FF5C}tool_calls>"),
            "DSV4 canonical template path must render assistant tool history as a DSML block. Decoded: \(toolHistoryDecoded)"
        )
        #expect(
            toolHistoryDecoded.contains("<\u{FF5C}DSML\u{FF5C}invoke name=\"get_weather\">"),
            "DSV4 canonical template path must preserve the assistant tool function name. Decoded: \(toolHistoryDecoded)"
        )
        #expect(
            toolHistoryDecoded.contains(
                "<\u{FF5C}DSML\u{FF5C}parameter name=\"city\" string=\"true\">Paris</\u{FF5C}DSML\u{FF5C}parameter>"
            ),
            "DSV4 canonical template path must preserve string arguments in DSML. Decoded: \(toolHistoryDecoded)"
        )
        #expect(
            toolHistoryDecoded.contains("<tool_result>{\"temp_c\":18}</tool_result>"),
            "DSV4 canonical template path must carry tool-role output into the follow-up prompt. Decoded: \(toolHistoryDecoded)"
        )
    }

    @Test func dsv4RequiredToolChoiceSurvivesToolResultHistory() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ2"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let fileReadTool = Tool(
            type: "function",
            function: ToolFunction(
                name: "file_read",
                description: "Read a file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")]),
                ])
            )
        )
        let lineCountCall: [String: any Sendable] = [
            "id": "call_line_count_1",
            "type": "function",
            "function": [
                "name": "line_count",
                "arguments": ["text": "alpha\nbeta\ngamma"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Count lines in alpha beta gamma."],
                ["role": "assistant", "content": "", "tool_calls": [lineCountCall]],
                ["role": "tool", "content": "{\"lines\":3}", "tool_call_id": "call_line_count_1"],
                [
                    "role": "user",
                    "content": "Now read /Users/eric/Desktop/testmandel/mandelbrot.py.",
                ],
            ],
            tools: [fileReadTool.toTokenizerToolSpec()],
            additionalContext: ["enable_thinking": false, "tool_choice": "required"]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(
            decoded.contains("<tool_result>{\"lines\":3}</tool_result>"),
            "DSV4 tool-history prompt must preserve the prior tool result. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(
                "<tool_result>{\"lines\":3}</tool_result>\n\nNow read /Users/eric/Desktop/testmandel/mandelbrot.py."
            ),
            "DSV4 must merge the prior tool result and the next user request into one content block. Decoded: \(decoded)"
        )
        #expect(
            decoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think><\u{FF5C}action\u{FF5C}>"),
            "DSV4 required/named tool_choice must preserve the action task after tool-result history. Decoded: \(decoded)"
        )
    }

    @Test func dsv4LocalTokenizerPreservesRawMaxPromptPath() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_DSV4_TEST_MODEL"] ?? defaultPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard
            FileManager.default.fileExists(
                atPath: modelURL.appendingPathComponent("tokenizer.json").path
            )
        else {
            return
        }

        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: modelURL)
        let maxTokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Return 42."]],
            tools: nil,
            additionalContext: ["enable_thinking": true, "reasoning_effort": "max"]
        )
        let maxDecoded = tokenizer.decode(tokenIds: maxTokenIds, skipSpecialTokens: false)

        #expect(
            maxDecoded.contains("Reasoning Effort: Absolute maximum"),
            "DSV4 raw max must preserve the canonical max-effort preface. Decoded: \(maxDecoded)"
        )
        #expect(
            maxDecoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}><think>"),
            "DSV4 raw max must leave the assistant thinking block open. Decoded: \(maxDecoded)"
        )

        let highTokenIds = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Return 42."]],
            tools: nil,
            additionalContext: ["enable_thinking": true, "reasoning_effort": "high"]
        )
        let highDecoded = tokenizer.decode(tokenIds: highTokenIds, skipSpecialTokens: false)
        #expect(
            !highDecoded.contains("Reasoning Effort: Absolute maximum"),
            "DSV4 high reasoning must not receive the raw max preface. Decoded: \(highDecoded)"
        )
    }

    @Test func downloadedFamilyTokenizersRenderCapabilitiesSearchToolSurface() async throws {
        let rows = [
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 26B JANG_4M CRACK",
                path: "/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK"
            ),
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 26B finished 4bit",
                path: "/Users/eric/osaurus_models/finished/gemma-4-26b-a4b-it-4bit"
            ),
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 31B JANG_4M candidate",
                path: "/Users/eric/models/dealign.ai/Gemma-4-31B-JANG_4M"
            ),
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 31B finished 4bit candidate",
                path: "/Users/eric/osaurus_models/finished/gemma-4-31b-a4b-it-4bit"
            ),
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 E2B finished 4bit",
                path: "/Users/eric/osaurus_models/finished/gemma-4-e2b-it-4bit"
            ),
            LocalTokenizerRow(
                family: "gemma4",
                label: "Gemma 4 E4B finished 4bit",
                path: "/Users/eric/osaurus_models/finished/gemma-4-e4b-it-4bit"
            ),
            LocalTokenizerRow(
                family: "qwen36-27b",
                label: "Qwen3.6 27B source",
                path: "/Users/eric/models/Sources/Qwen/Qwen3.6-27B"
            ),
            LocalTokenizerRow(
                family: "qwen36-27b",
                label: "Qwen3.6 27B JANG_4M CRACK",
                path: "/Users/eric/models/dealign.ai/Qwen3.6-27B-JANG_4M-CRACK"
            ),
            LocalTokenizerRow(
                family: "qwen36-27b",
                label: "Qwen3.6 27B MXFP4 CRACK",
                path: "/Users/eric/models/dealign.ai/Qwen3.6-27B-MXFP4-CRACK"
            ),
            LocalTokenizerRow(
                family: "qwen36-35b",
                label: "Qwen3.6 35B source",
                path: "/Users/eric/models/Sources/Qwen/Qwen3.6-35B-A3B"
            ),
            LocalTokenizerRow(
                family: "qwen36-35b",
                label: "Qwen3.6 35B JANGTQ CRACK",
                path: "/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK"
            ),
            LocalTokenizerRow(
                family: "qwen36-35b",
                label: "Qwen3.6 35B MXFP4 CRACK MTP",
                path: "/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-MXFP4-CRACK-MTP"
            ),
            LocalTokenizerRow(
                family: "qwen36-35b",
                label: "Qwen3.6 35B mxfp4 OsaurusAI",
                path: "/Users/eric/models/OsaurusAI/Qwen3.6-35B-A3B-mxfp4"
            ),
            LocalTokenizerRow(
                family: "minimax-m2",
                label: "MiniMax M2.7 Small JANGTQ",
                path: "/Users/eric/models/JANGQ/MiniMax-M2.7-Small-JANGTQ"
            ),
            LocalTokenizerRow(
                family: "minimax-m2",
                label: "MiniMax M2.7 JANGTQ_K CRACK",
                path: "/Users/eric/models/dealign.ai/MiniMax-M2.7-JANGTQ_K-CRACK"
            ),
            LocalTokenizerRow(
                family: "minimax-m2",
                label: "MiniMax M2.7 JANG_K CRACK",
                path: "/Users/eric/models/dealign.ai/MiniMax-M2.7-JANG_K-CRACK"
            ),
            LocalTokenizerRow(
                family: "dsv4",
                label: "DeepSeek V4 Flash JANG",
                path: "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANG"
            ),
            LocalTokenizerRow(
                family: "dsv4",
                label: "DeepSeek V4 Flash JANGTQ-K",
                path: "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K"
            ),
            LocalTokenizerRow(
                family: "dsv4",
                label: "DeepSeek V4 Flash JANGTQ2",
                path: "/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ2"
            ),
        ]

        let tool = CapabilitiesSearchTool().asOpenAITool().toTokenizerToolSpec()
        let availableRows = rows.filter(\.hasTokenizer)
        var renderedFamilies: Set<String> = []

        // CI does not carry Eric's downloaded model inventory. Keep this row as
        // a real local-family smoke when those tokenizer bundles exist, while
        // allowing ordinary CI to rely on the checked-in focused tokenizer
        // fixtures above.
        guard !availableRows.isEmpty else { return }

        for row in availableRows {
            let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: row.url)
            let tokenIds = try tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Search capabilities for file writing."]],
                tools: [tool],
                additionalContext: ["enable_thinking": false]
            )
            let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

            #expect(!decoded.isEmpty, "\(row.label) rendered an empty prompt")
            #expect(
                decoded.contains("capabilities_search"),
                "\(row.label) must render the Osaurus tool surface. Decoded: \(decoded)"
            )
            #expect(
                !decoded.contains("Runtime error") && !decoded.contains("upper filter"),
                "\(row.label) must not render a chat-template runtime error. Decoded: \(decoded)"
            )
            renderedFamilies.insert(row.family)
        }

        #expect(
            renderedFamilies == Set(availableRows.map(\.family)),
            "Every available downloaded tokenizer family should render. Available: \(availableRows.map(\.family)); rendered: \(renderedFamilies)"
        )
    }
}

private struct LocalTokenizerRow {
    let family: String
    let label: String
    let path: String

    var url: URL { URL(fileURLWithPath: path) }
    var hasTokenizer: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path)
    }
}

private func collectArrayTypedSchemaPaths(_ value: Any, path: String = "$") -> [String] {
    if let object = value as? [String: Any] {
        var paths: [String] = []
        if let type = object["type"], isArrayValue(type) {
            paths.append("\(path).type")
        }
        for (key, child) in object {
            paths.append(contentsOf: collectArrayTypedSchemaPaths(child, path: "\(path).\(key)"))
        }
        return paths
    }

    if let object = value as? [String: any Sendable] {
        var paths: [String] = []
        if let type = object["type"], isArrayValue(type) {
            paths.append("\(path).type")
        }
        for (key, child) in object {
            paths.append(contentsOf: collectArrayTypedSchemaPaths(child, path: "\(path).\(key)"))
        }
        return paths
    }

    if let array = value as? [Any] {
        return array.enumerated().flatMap { index, child in
            collectArrayTypedSchemaPaths(child, path: "\(path)[\(index)]")
        }
    }

    if let array = value as? [any Sendable] {
        return array.enumerated().flatMap { index, child in
            collectArrayTypedSchemaPaths(child, path: "\(path)[\(index)]")
        }
    }

    return []
}

private func isArrayValue(_ value: Any) -> Bool {
    value is [Any] || value is [any Sendable] || value is NSArray
}
