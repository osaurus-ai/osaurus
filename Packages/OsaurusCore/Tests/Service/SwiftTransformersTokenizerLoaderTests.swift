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

    @Test func zayaVLLocalTokenizerRendersTextOnlyToolsFromOsaurusFallback() async throws {
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
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to count lines for."),
                        ])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use line_count on red\ngreen\nblue.",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("<tools>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<name>line_count</name>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<name>text</name>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<type>string</type>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<required>[\"text\"]</required>"), "Decoded: \(decoded)")
        #expect(decoded.contains("MUST be a tool call"), "Decoded: \(decoded)")
        #expect(decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(decoded.contains("Use line_count on red\ngreen\nblue."), "Decoded: \(decoded)")
    }

    @Test func zayaTextLocalTokenizerRendersZyphraToolsNotGemmaFallback() async throws {
        let defaultPath = "/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ_K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_ZAYA_TEXT_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to count lines for."),
                        ])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use line_count on this exact text: red\ngreen\nblue",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("<tools>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<name>line_count</name>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<zyphra_tool_call>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<function=line_count>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<parameter=text>\nred\ngreen\nblue\n</parameter>"), "Decoded: \(decoded)")
        #expect(decoded.contains("MUST be a tool call"), "Decoded: \(decoded)")
        #expect(!decoded.contains("native Gemma function call"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<|tool_call>call:FUNCTION_NAME"), "Decoded: \(decoded)")
    }

    @Test func zayaVLLocalTokenizerKeepsRequiredToolReminderInCurrentUserTurn() async throws {
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
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to count lines for."),
                        ])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let finalUser = "Now use line_count on exactly this new text, preserving newlines:\none\ntwo"
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use line_count on this text:\nred\ngreen\nblue"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_lines_1",
                            "type": "function",
                            "function": [
                                "name": "line_count",
                                "arguments": ["text": "red\ngreen\nblue"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable]
                    ],
                ] as [String: any Sendable],
                ["role": "tool", "tool_call_id": "call_lines_1", "content": #"{"lines":3}"#],
                ["role": "user", "content": "How many lines were counted? Do not call another tool."],
                ["role": "assistant", "content": "Three lines were counted."],
                ["role": "user", "content": finalUser],
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)
        let reminder = "The current assistant response MUST be a tool call."
        let finalUserRange = try #require(decoded.range(of: finalUser))
        let afterFinalUser = decoded[finalUserRange.upperBound...]

        #expect(afterFinalUser.contains(reminder), "Decoded: \(decoded)")
        #expect(decoded.contains("<parameter=text>\none\ntwo\n</parameter>"), "Decoded: \(decoded)")
        #expect(!decoded.contains("Previous tool result available."), "Decoded: \(decoded)")
        #expect(!decoded.contains(#"<zyphra_tool_response>\n{"lines":3}"#), "Decoded: \(decoded)")
        #expect(!decoded.contains("Use line_count on this text:\nred\ngreen\nblue"), "Decoded: \(decoded)")
        #expect(!decoded.contains("How many lines were counted? Do not call another tool."), "Decoded: \(decoded)")
        #expect(!decoded.contains("Three lines were counted."), "Decoded: \(decoded)")
        #expect(!afterFinalUser.contains("<|im_start|>system\n<IMPORTANT>"), "Decoded: \(decoded)")
        #expect(decoded.hasSuffix("<|im_start|>assistant\n"), "Decoded: \(decoded)")
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

    @Test func gemma4FallbackCompactsClosedToolHistoryForLaterRequiredToolTurn() async throws {
        let defaultPath = "/Users/eric/models/OsaurusAI/gemma-4-12B-it-MXFP4"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_GEMMA4_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let finalUser = "Now use line_count on this exact text: one\ntwo"
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use the line_count tool on this exact text: red\ngreen\nblue"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_line_count_1",
                            "type": "function",
                            "function": [
                                "name": "line_count",
                                "arguments": ["text": "red\ngreen\nblue"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable]
                    ],
                ] as [String: any Sendable],
                ["role": "tool", "content": "{\"lines\":3}", "tool_call_id": "call_line_count_1"],
                ["role": "user", "content": "How many lines were counted?"],
                ["role": "assistant", "content": "The text contains 3 lines."],
                ["role": "user", "content": finalUser],
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains(finalUser), "Decoded: \(decoded)")
        #expect(decoded.contains("The current assistant response MUST be a function call."), "Decoded: \(decoded)")
        #expect(
            decoded.contains("For multiline string values, represent each line break with the two characters \\n"),
            "Decoded: \(decoded)"
        )
        #expect(decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(
            decoded.contains(#"<|tool_call>call:line_count{text:<|"|>one\ntwo<|"|>}<tool_call|>"#),
            "Decoded: \(decoded)"
        )
        #expect(!decoded.contains("<zyphra_tool_call>"), "Decoded: \(decoded)")
        #expect(!decoded.contains("red\ngreen\nblue"), "Decoded: \(decoded)")
        #expect(!decoded.contains("The text contains 3 lines."), "Decoded: \(decoded)")
        #expect(!decoded.contains("call_line_count_1"), "Decoded: \(decoded)")
        #expect(!decoded.contains("Tool result: {\"lines\":3}"), "Decoded: \(decoded)")
    }

    @Test func gemma4FallbackRendersFirstTurnRequiredMultilineToolShape() async throws {
        let defaultPath = "/Users/eric/models/OsaurusAI/gemma-4-12B-it-MXFP4"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_GEMMA4_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )

        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use the line_count tool on this exact text: red\ngreen\nblue",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("The current assistant response MUST be a function call."), "Decoded: \(decoded)")
        #expect(
            decoded.contains("For multiline string values, represent each line break with the two characters \\n"),
            "Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(#"<|tool_call>call:line_count{text:<|"|>red\ngreen\nblue<|"|>}<tool_call|>"#),
            "Decoded: \(decoded)"
        )
        let unescapedActualNewlineValue = "<|" + "\"|>red\ngreen\nblue<|" + "\"|>"
        #expect(!decoded.contains(unescapedActualNewlineValue), "Decoded: \(decoded)")
        #expect(!decoded.contains("<zyphra_tool_call>"), "Decoded: \(decoded)")
    }

    @Test func nemotronRequiredToolChoiceUsesNemotronFallbackNotGemmaFallback() async throws {
        let defaultPath = "/Users/eric/models/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_NEMOTRON_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )

        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use the line_count tool on exactly this text, preserving newlines:\nalpha\nbeta\ngamma",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("<tools>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<name>line_count</name>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<required>[\"text\"]</required>"), "Decoded: \(decoded)")
        #expect(decoded.contains("MUST be a tool call"), "Decoded: \(decoded)")
        #expect(decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(decoded.contains("<function=line_count>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<parameter=text>"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<|tool_call>call:line_count"), "Decoded: \(decoded)")
        #expect(!decoded.contains("For multiline string values, represent each line break"), "Decoded: \(decoded)")
    }

    @Test func nemotronRequiredToolChoiceCompactsClosedToolHistoryForLaterRequiredToolTurn() async throws {
        let defaultPath = "/Users/eric/models/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_NEMOTRON_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let finalUser = "Now use line_count on exactly this new text, preserving newlines:\none\ntwo"
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use the line_count tool on exactly this text, preserving newlines:\nalpha\nbeta\ngamma",
                ],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_line_count_1",
                            "type": "function",
                            "function": [
                                "name": "line_count",
                                "arguments": ["text": "alpha\nbeta\ngamma"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable]
                    ],
                ] as [String: any Sendable],
                ["role": "tool", "content": "{\"lines\":3}", "tool_call_id": "call_line_count_1"],
                [
                    "role": "user",
                    "content": "Answer visibly in one short sentence: how many lines were counted? Do not call a tool.",
                ],
                ["role": "assistant", "content": "The line_count tool counted 3 lines."],
                ["role": "user", "content": finalUser],
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains(finalUser), "Decoded: \(decoded)")
        #expect(decoded.contains("<tools>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<name>line_count</name>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<required>[\"text\"]</required>"), "Decoded: \(decoded)")
        #expect(decoded.contains("MUST be a tool call"), "Decoded: \(decoded)")
        #expect(decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(decoded.contains("<function=line_count>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<parameter=text>"), "Decoded: \(decoded)")
        #expect(!decoded.contains("alpha\nbeta\ngamma"), "Decoded: \(decoded)")
        #expect(!decoded.contains("call_line_count_1"), "Decoded: \(decoded)")
        #expect(!decoded.contains("The line_count tool counted 3 lines."), "Decoded: \(decoded)")
        #expect(!decoded.contains("{\"lines\":3}"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<|tool_call>call:line_count"), "Decoded: \(decoded)")
    }

    @Test func gemma3nLocalTokenizerDoesNotInventRequiredToolContractFromFallback() async throws {
        let defaultPath = "/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_GEMMA3N_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to count lines for."),
                        ])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )

        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use line_count on alpha\nbeta\ngamma.",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(!decoded.contains("<|tool>declaration:line_count"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<|tool_call>call:FUNCTION_NAME"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<|tool_call>call:line_count"), "Decoded: \(decoded)")
        #expect(!decoded.contains("MUST be a function call"), "Decoded: \(decoded)")
        #expect(!decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(decoded.contains("Use line_count on alpha\nbeta\ngamma."), "Decoded: \(decoded)")
        #expect(!decoded.contains("<start_function_call>"), "Decoded: \(decoded)")
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
            agentId: Agent.defaultId,
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
                executionMode: .sandbox(hostRead: nil)
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
        #expect(decoded.contains("capabilities_discover"), "Decoded: \(decoded)")
    }

    @Test func loaderNormalizesRawGemmaSensitiveToolSchemas() throws {
        let parameters: [String: any Sendable] = [
            "type": ["object", "null"] as [any Sendable],
            "additionalProperties": false,
            "properties": [
                "set": [
                    "type": "object",
                    "additionalProperties": true,
                ] as [String: any Sendable],
                "metadata": [
                    "type": ["object", "null"] as [any Sendable],
                    "properties": [
                        "type": [
                            "type": "string",
                            "description": "A real property named type.",
                        ] as [String: any Sendable],
                        "tags": [
                            "type": ["array", "null"] as [any Sendable],
                            "items": [
                                "type": "string"
                            ] as [String: any Sendable],
                        ] as [String: any Sendable],
                        "closed": false,
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["set"] as [any Sendable],
        ]
        let rawTool: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": "db_update",
                "description": "Update rows.",
                "parameters": parameters,
            ] as [String: any Sendable],
        ]

        let tools = try #require(
            SwiftTransformersTokenizerLoader.normalizedToolsForChatTemplate([rawTool])
        )
        let function = try #require(tools[0]["function"] as? [String: any Sendable])
        let normalizedParameters = try #require(function["parameters"] as? [String: any Sendable])
        let properties = try #require(normalizedParameters["properties"] as? [String: any Sendable])
        let set = try #require(properties["set"] as? [String: any Sendable])
        let metadata = try #require(properties["metadata"] as? [String: any Sendable])
        let metadataProperties = try #require(metadata["properties"] as? [String: any Sendable])
        let propertyNamedType = try #require(metadataProperties["type"] as? [String: any Sendable])
        let tags = try #require(metadataProperties["tags"] as? [String: any Sendable])
        let closed = try #require(metadataProperties["closed"] as? [String: any Sendable])

        #expect(normalizedParameters["type"] as? String == "object")
        #expect(normalizedParameters["nullable"] as? Bool == true)
        #expect(normalizedParameters["additionalProperties"] == nil)
        #expect(set["additionalProperties"] == nil)
        #expect(metadata["type"] as? String == "object")
        #expect(metadata["nullable"] as? Bool == true)
        #expect(propertyNamedType["type"] as? String == "string")
        #expect(tags["type"] as? String == "array")
        #expect(tags["nullable"] as? Bool == true)
        #expect(closed["type"] as? String == "string")
        #expect(
            collectArrayTypedSchemaPaths(tools as Any).isEmpty,
            "Array-valued schema type paths: \(collectArrayTypedSchemaPaths(tools as Any))"
        )
        #expect(
            collectBooleanAdditionalPropertiesPaths(tools as Any).isEmpty,
            "Boolean additionalProperties paths: \(collectBooleanAdditionalPropertiesPaths(tools as Any))"
        )
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

    @Test func nemotronLocalTokenizerDoesNotRouteThroughDSV4Template() async throws {
        let defaultPath = "/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_NEMOTRON_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                [
                    "role": "user",
                    "content": "Use line_count on red\ngreen\nblue.",
                ]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: ["enable_thinking": false, "tool_choice": "required"]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("<|im_start|>"), "Nemotron should keep its ChatML template. Decoded: \(decoded)")
        #expect(decoded.contains("<tools>"), "Nemotron should render XML tools. Decoded: \(decoded)")
        #expect(decoded.contains("<tool_call>"), "Nemotron should show XML tool call contract. Decoded: \(decoded)")
        #expect(
            decoded.contains("line_count"),
            "Nemotron should include the requested tool schema. Decoded: \(decoded)"
        )
        #expect(
            decoded.contains("one available tool and no prose before the tool result"),
            "Nemotron required tool_choice must use the strict fallback contract, not the permissive native template. Decoded: \(decoded)"
        )
        #expect(
            !decoded.contains("optional reasoning for your function call"),
            "Nemotron required tool_choice must not keep the native template's optional reasoning-before-tool allowance. Decoded: \(decoded)"
        )
        #expect(
            !decoded.contains("<\u{FF5C}DSML\u{FF5C}tool_calls>")
                && !decoded.contains("$TOOL_NAME")
                && !decoded.contains("<\u{FF5C}Assistant\u{FF5C}>"),
            "Nemotron must not be misrouted through the DSV4 DSML template. Decoded: \(decoded)"
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
            decoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think>"),
            "DSV4 required/named tool_choice must keep the ordinary assistant tail; the action task rail can leak as visible model text after tool-result history. Decoded: \(decoded)"
        )
        #expect(
            !decoded.contains("<\u{FF5C}action\u{FF5C}>"),
            "DSV4 required/named tool_choice must not inject the action task token after live repeat rows showed it can leak as visible text. Decoded: \(decoded)"
        )
    }

    @Test func dsv4RequiredToolChoiceCompactsClosedToolHistoryBeforeNextToolCall() async throws {
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
        let lineCountTool = Tool(
            type: "function",
            function: ToolFunction(
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let priorLineCountCall: [String: any Sendable] = [
            "id": "call_line_count_1",
            "type": "function",
            "function": [
                "name": "line_count",
                "arguments": ["text": "red\ngreen\nblue"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use line_count on red green blue."],
                ["role": "assistant", "content": "", "tool_calls": [priorLineCountCall]],
                ["role": "tool", "content": "{\"lines\":3}", "tool_call_id": "call_line_count_1"],
                ["role": "user", "content": "How many lines were counted?"],
                ["role": "assistant", "content": "The line_count tool counted 3 lines."],
                ["role": "user", "content": "Now use line_count on this exact text: one\ntwo"],
            ],
            tools: [lineCountTool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)
        let conversationSegment =
            decoded.components(separatedBy: "<\u{FF5C}User\u{FF5C}>").dropFirst().joined(
                separator: "<\u{FF5C}User\u{FF5C}>"
            )

        #expect(
            !conversationSegment.contains("<\u{FF5C}DSML\u{FF5C}invoke name=\"line_count\">"),
            "Closed historical DSV4 tool calls must not be replayed before a later required tool call. Decoded: \(decoded)"
        )
        #expect(
            !conversationSegment.contains("red\ngreen\nblue"),
            "Closed historical DSV4 tool arguments must not be replayed before a later required tool call. Decoded: \(decoded)"
        )
        #expect(
            !conversationSegment.contains("<tool_result>{\"lines\":3}</tool_result>"),
            "Closed historical DSV4 tool results must not poison the next required tool-call turn. Decoded: \(decoded)"
        )
        #expect(decoded.contains("The line_count tool counted 3 lines."))
        #expect(decoded.contains("Now use line_count on this exact text: one\ntwo"))
        #expect(decoded.contains("Use the `line_count` function."))
        #expect(
            decoded.hasSuffix("<\u{FF5C}Assistant\u{FF5C}></think>"),
            "DSV4 compacted history must still leave the ordinary assistant tail. Decoded: \(decoded)"
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

    @Test func downloadedFamilyTokenizersRenderCapabilitiesDiscoverToolSurface() async throws {
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

        let tool = CapabilitiesDiscoverTool().asOpenAITool().toTokenizerToolSpec()
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
                decoded.contains("capabilities_discover"),
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

    @Test func lfm2LocalTokenizerUsesStrictRequiredToolFallback() async throws {
        let defaultPath = "/Users/eric/.mlxstudio/models/JANGQ-AI/LFM2.5-8B-A1B-JANG_2L"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_LFM2_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use the line_count tool on this exact text: red\ngreen\nblue"]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("List of tools:"), "Decoded: \(decoded)")
        #expect(decoded.contains("line_count"), "Decoded: \(decoded)")
        #expect(decoded.contains("The API requires a tool call for the next assistant turn."), "Decoded: \(decoded)")
        #expect(decoded.contains("Function name: line_count"), "Decoded: \(decoded)")
        #expect(decoded.contains("Required arguments: text"), "Decoded: \(decoded)")
        #expect(
            decoded.contains("Respond with exactly this one assistant message and nothing else:"),
            "Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(#"<|tool_call_start|>["line_count", {"text":"red\ngreen\nblue"}]<|tool_call_end|>"#),
            "Decoded: \(decoded)"
        )
        #expect(decoded.contains("Copy the `text` value exactly from the current user request."), "Decoded: \(decoded)")
        #expect(
            decoded.contains("This value contains exactly 2 line break(s)."),
            "Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(
                #"In the native LFM tagged JSON call, each line break is represented by the two characters \n"#
            ),
            "Decoded: \(decoded)"
        )
        #expect(
            decoded.contains(#"the exact `text` value encoded with \n escapes is: red\ngreen\nblue"#),
            "Decoded: \(decoded)"
        )
        #expect(decoded.contains("Do not double any line break."), "Decoded: \(decoded)")
        #expect(
            decoded.contains(
                "Do not add a blank line, leading space, trailing newline, or any other character to the copied value."
            ),
            "Decoded: \(decoded)"
        )
        #expect(decoded.contains("Do not omit `text`"), "Decoded: \(decoded)")
        #expect(
            decoded.contains("Do not write reasoning, XML-style tool tags, markdown, or prose."),
            "Decoded: \(decoded)"
        )
        #expect(decoded.contains(#"["line_count", {"text":"red\ngreen\nblue"}]"#), "Decoded: \(decoded)")
        #expect(!decoded.contains("line_count(text='red\\ngreen\\nblue')"), "Decoded: \(decoded)")
        #expect(!decoded.contains("<tools>"), "Decoded: \(decoded)")
        #expect(!decoded.contains("</tool_call>"), "Decoded: \(decoded)")
        #expect(
            decoded.contains("Use the line_count tool on this exact text: red\ngreen\nblue"),
            "Decoded: \(decoded)"
        )
        #expect(
            !decoded.contains(#"Use the line_count tool on this exact text: red\ngreen\nblue"#),
            "Decoded: \(decoded)"
        )
        if let userRange = decoded.range(
            of: "Use the line_count tool on this exact text: red\ngreen\nblue"
        ) {
            let beforeUser = decoded[..<userRange.lowerBound]
            #expect(
                beforeUser.contains("The API requires a tool call for the next assistant turn."),
                "Required-tool instruction must be present in the LFM system preface. Decoded: \(decoded)"
            )
            #expect(
                beforeUser.contains(
                    #"<|tool_call_start|>["line_count", {"text":"red\ngreen\nblue"}]<|tool_call_end|>"#
                ),
                "Required-tool instruction must keep the exact multiline value in the LFM system preface. Decoded: \(decoded)"
            )
        }
        #expect(!decoded.contains("Today's date:"), "Decoded: \(decoded)")
        #expect(
            decoded.hasSuffix("<|im_start|>assistant\n"),
            "LFM required-tool turns must not inject a synthetic thinking rail. Decoded: \(decoded)"
        )
        #expect(!decoded.contains("<think>"), "Decoded: \(decoded)")
    }

    @Test func step37LocalTokenizerUsesRequiredToolFallbackAndClosesThinkingRail() async throws {
        let defaultPath = "/Volumes/EricsLLMDrive/jangq-ai/Step-3.7-Flash-JANGTQ_K"
        let modelPath = ProcessInfo.processInfo.environment["OSAURUS_STEP37_TEST_MODEL"] ?? defaultPath
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
                name: "line_count",
                description: "Count newline-separated text lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
        let tokenIds = try tokenizer.applyChatTemplate(
            messages: [
                ["role": "user", "content": "Use the line_count tool on this exact text: red\ngreen\nblue"]
            ],
            tools: [tool.toTokenizerToolSpec()],
            additionalContext: [
                "enable_thinking": false,
                "tool_choice": "required",
                "tool_choice_name": "line_count",
            ]
        )
        let decoded = tokenizer.decode(tokenIds: tokenIds, skipSpecialTokens: false)

        #expect(decoded.contains("# Tools"), "Decoded: \(decoded)")
        #expect(decoded.contains("The active API tool_choice is required"), "Decoded: \(decoded)")
        #expect(decoded.contains("Use the `line_count` function."), "Decoded: \(decoded)")
        #expect(decoded.contains("Required parameters for `line_count`: text."), "Decoded: \(decoded)")
        #expect(decoded.contains("<tool_call>\n<function=FUNCTION_NAME>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<parameter=ARGUMENT_NAME>"), "Decoded: \(decoded)")
        #expect(decoded.contains("<|im_start|>assistant\n<think>\n</think>\n\n"), "Decoded: \(decoded)")
        #expect(!decoded.hasSuffix("<|im_start|>assistant\n<think>\n"), "Decoded: \(decoded)")
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

private func collectBooleanAdditionalPropertiesPaths(_ value: Any, path: String = "$") -> [String] {
    if let object = value as? [String: Any] {
        var paths: [String] = []
        if let additionalProperties = object["additionalProperties"],
            isBooleanValue(additionalProperties)
        {
            paths.append("\(path).additionalProperties")
        }
        for (key, child) in object {
            paths.append(
                contentsOf: collectBooleanAdditionalPropertiesPaths(child, path: "\(path).\(key)")
            )
        }
        return paths
    }

    if let object = value as? [String: any Sendable] {
        var paths: [String] = []
        if let additionalProperties = object["additionalProperties"],
            isBooleanValue(additionalProperties)
        {
            paths.append("\(path).additionalProperties")
        }
        for (key, child) in object {
            paths.append(
                contentsOf: collectBooleanAdditionalPropertiesPaths(child, path: "\(path).\(key)")
            )
        }
        return paths
    }

    if let array = value as? [Any] {
        return array.enumerated().flatMap { index, child in
            collectBooleanAdditionalPropertiesPaths(child, path: "\(path)[\(index)]")
        }
    }

    if let array = value as? [any Sendable] {
        return array.enumerated().flatMap { index, child in
            collectBooleanAdditionalPropertiesPaths(child, path: "\(path)[\(index)]")
        }
    }

    return []
}

private func isBooleanValue(_ value: Any) -> Bool {
    if value is Bool { return true }
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}
