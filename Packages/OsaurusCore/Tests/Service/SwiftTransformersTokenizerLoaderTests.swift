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
}
