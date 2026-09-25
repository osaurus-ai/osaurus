//
//  MLXServiceRuntimePolicyTests.swift
//  OsaurusCoreTests
//
//  Local MLX service policy gates for the Server -> Settings runtime
//  contract. These tests are no-load: they prove request shape validation
//  happens before ModelRuntime can load or generate.
//

import Foundation
@preconcurrency import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("MLXService runtime policy gates")
struct MLXServiceRuntimePolicyTests {

    @Test func toolMetadataDistinguishesUnknownFormatFromExplicitlyUnsupported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tool-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"model_type":"mimo_v2"}"#.write(
            to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let metadata = [
            #"{"capabilities":{"tool_parser":"xml_function","supports_tools":true},"tool_calling":{"dialect":"xml_function","format":"<tool_call><function=NAME><parameter=ARG>VALUE</parameter></function></tool_call>"}}"#,
            #"{"tool_calling":{"dialect":"xml_function","format":"<tool_call><function=NAME>...</function></tool_call>"}}"#,
            #"{"tool_calling":{"parser":"future_parser","format":"example wire payload"}}"#,
            #"{"tool_calling":{"format":"xml_function"}}"#,
        ]
        for json in metadata {
            try json.write(to: root.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
            #expect(MLXService.supportsLocalToolCalling(
                modelName: "mimo-v2.6-flash-rl-jang_2l", modelId: "local/bundle", modelDirectory: root))
            try MLXService.validateRuntimePolicy(
                modelName: "mimo-v2.6-flash-rl-jang_2l", modelId: "local/bundle",
                messages: [ChatMessage(role: "user", content: "Count the lines with line_count.")],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [Self.lineCountTool()], runtime: VMLXServerRuntimeSettings(), modelDirectory: root)
        }
        try #"{"capabilities":{"supports_tools":false,"tool_parser":"xml_function"}}"#.write(
            to: root.appendingPathComponent("jang_config.json"), atomically: true, encoding: .utf8)
        #expect(!MLXService.supportsLocalToolCalling(
            modelName: "local-model", modelId: "local/bundle", modelDirectory: root))
    }

    @Test func serverSettingRejectsVideoWhenDisabled() throws {
        let bundle = try VisionBundleFixture.make(type: "qwen3_vl")
        defer { try? FileManager.default.removeItem(at: bundle) }
        var runtime = VMLXServerRuntimeSettings()
        runtime.multimodal.enableVideo = false

        let message = ChatMessage(
            role: "user",
            content: "watch this",
            contentParts: [
                .text("watch this"),
                .videoUrl(url: "data:video/mp4;base64,AAAA"),
            ]
        )

        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "qwen3-vl-30b",
                modelId: "Qwen/Qwen3-VL-30B-MLX",
                messages: [message],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: runtime,
                modelDirectory: bundle
            )
        }
    }

    @Test func modelCapabilityRejectsImageForTextOnlyModel() {
        let message = ChatMessage(
            role: "user",
            content: "describe this",
            contentParts: [
                .text("describe this"),
                .imageUrl(url: "data:image/png;base64,AAAA", detail: nil),
            ]
        )

        // A product name without installed component evidence cannot grant media.
        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "gemma-4-31b-jang_4m",
                modelId: "OsaurusAI/Gemma-4-31B-JANG_4M",
                messages: [message],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: VMLXServerRuntimeSettings()
            )
        }
    }

    @Test func modelCapabilityAllowsQwenVLImageAndVideo() throws {
        let bundle = try VisionBundleFixture.make(type: "qwen3_vl")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let message = ChatMessage(
            role: "user",
            content: "describe this",
            contentParts: [
                .text("describe this"),
                .imageUrl(url: "data:image/png;base64,AAAA", detail: nil),
                .videoUrl(url: "data:video/mp4;base64,AAAA"),
            ]
        )

        try MLXService.validateRuntimePolicy(
            modelName: "qwen3-vl-30b",
            modelId: "Qwen/Qwen3-VL-30B-MLX",
            messages: [message],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16),
            tools: [],
            runtime: VMLXServerRuntimeSettings(),
            modelDirectory: bundle
        )

        // A previous positive inspection cannot admit a changed installation.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("model.safetensors"))
        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "qwen3-vl-30b", modelId: "Qwen/Qwen3-VL-30B-MLX",
                messages: [message], parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [], runtime: VMLXServerRuntimeSettings(), modelDirectory: bundle
            )
        }
    }

    @Test func modelCapabilityRejectsAudioForQwenVL() throws {
        let bundle = try VisionBundleFixture.make(type: "qwen3_vl")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let message = ChatMessage(
            role: "user",
            content: "hear this",
            contentParts: [
                .text("hear this"),
                .audioInput(data: "AAAA", format: "wav"),
            ]
        )

        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "qwen3-vl-30b",
                modelId: "Qwen/Qwen3-VL-30B-MLX",
                messages: [message],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: VMLXServerRuntimeSettings(),
                modelDirectory: bundle
            )
        }
    }

    @Test func modelCapabilityGatesGemma4AudioOnBundleFacts() {
        let message = ChatMessage(
            role: "user",
            content: "hear this",
            contentParts: [
                .text("hear this"),
                .audioInput(data: "AAAA", format: "wav"),
            ]
        )

        // No name-based audio grant: an installed config and actual projection
        // header are required. Index strings alone are not component evidence.
        do {
            try MLXService.validateRuntimePolicy(
                modelName: "gemma-4-12b-it-mxfp4",
                modelId: "OsaurusAI/Gemma-4-12B-it-MXFP4",
                messages: [message],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: VMLXServerRuntimeSettings()
            )
            Issue.record("Gemma4 audio must stay rejected when bundle facts are unavailable.")
        } catch let error as MLXService.RuntimePolicyError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("Audio input is not backed by the installed bundle"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// The `zaya1-vl-8b-jangtq_k` hard block was removed: its stated reason
    /// ("proven first-token fidelity failure") was disproven live — the model
    /// streams coherent text with correct first tokens (the original failure was
    /// a since-fixed runtime issue, not the quant). It must now pass runtime
    /// policy like any other text-coherent bundle; this guards against silently
    /// re-introducing the stale block.
    @Test func policyNoLongerBlocksZayaVLJANGTQK() throws {
        try MLXService.validateRuntimePolicy(
            modelName: "zaya1-vl-8b-jangtq_k",
            modelId: "JANGQ/ZAYA1-VL-8B-JANGTQ_K",
            messages: [ChatMessage(role: "user", content: "Compute 7 + 8 - 11.")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16),
            tools: [],
            runtime: VMLXServerRuntimeSettings()
        )
    }

    @Test func policyRejectsGemma3nToolsInsteadOfLeakingTemplateMarkers() {
        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "gemma-3n-e2b-it-4bit",
                modelId: "mlx-community/gemma-3n-E2B-it-4bit",
                messages: [ChatMessage(role: "user", content: "Use line_count on alpha\nbeta.")],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [Self.lineCountTool()],
                runtime: VMLXServerRuntimeSettings()
            )
        }
    }

    @Test func localToolSupportFollowsBundleToolParserContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tool-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gemma3n = root.appendingPathComponent("gemma3n", isDirectory: true)
        try FileManager.default.createDirectory(at: gemma3n, withIntermediateDirectories: true)
        try #"{"model_type":"gemma3n_text"}"#.write(
            to: gemma3n.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            MLXService.supportsLocalToolCalling(
                modelName: "gemma-3n-e2b-it-4bit",
                modelId: "local/gemma3n",
                modelDirectory: gemma3n
            ) == false
        )

        let gemma4 = root.appendingPathComponent("gemma4", isDirectory: true)
        try FileManager.default.createDirectory(at: gemma4, withIntermediateDirectories: true)
        try #"{"model_type":"gemma4_text"}"#.write(
            to: gemma4.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            MLXService.supportsLocalToolCalling(
                modelName: "gemma-4-26b-a4b-it-jang_4m-crack",
                modelId: "local/gemma4",
                modelDirectory: gemma4
            ) == true
        )
    }

    @Test func vibeThinkerIsTreatedAsToolUnsupported() {
        // VibeThinker carries the standard Qwen2.5 Hermes tool template (so format
        // detection would call it tool-capable), but the reasoning fine-tune wraps
        // calls in a hallucinated `<assemble>` tag and never parses. It is gated to
        // text/reasoning-only regardless of quant variant.
        for id in [
            "OsaurusAI/VibeThinker-3B-MXFP8",
            "OsaurusAI/VibeThinker-3B-MXFP4",
            "OsaurusAI/VibeThinker-3B-JANG_4M",
        ] {
            #expect(
                MLXService.supportsLocalToolCalling(
                    modelName: "vibethinker-3b",
                    modelId: id
                ) == false
            )
        }
        // A real Qwen2.5 (same qwen2 model_type) stays tool-capable.
        #expect(
            MLXService.supportsLocalToolCalling(
                modelName: "qwen2.5-3b-instruct",
                modelId: "mlx-community/Qwen2.5-3B-Instruct"
            )
                == true
        )
    }

    @Test func policyRejectsVibeThinkerToolsInsteadOfHallucinatingAssembleTag() {
        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "vibethinker-3b-mxfp8",
                modelId: "OsaurusAI/VibeThinker-3B-MXFP8",
                messages: [ChatMessage(role: "user", content: "What's the weather in London?")],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [Self.lineCountTool()],
                runtime: VMLXServerRuntimeSettings()
            )
        }
    }

    @Test func stepToolSupportDoesNotRequireBundleMetadataPreflight() {
        #expect(
            MLXService.supportsLocalToolCalling(
                modelName: "JANGQ-AI/Step-3.7-Flash-JANGTQ_K",
                modelId: "step-3.7-flash-jangtq_k",
                modelDirectory: nil
            ) == true
        )
    }

    @Test func mimoAndN2TextToolPreflightDoesNotRequireMediaBundleProbe() throws {
        for (modelName, modelId) in [
            ("mimo-v2.5-jangtq_2", "JANGQ-AI/MiMo-V2.5-JANGTQ_2"),
            ("nex-n2-pro-jangtq2", "Nex-N2-Pro-JANGTQ2"),
        ] {
            try MLXService.validateRuntimePolicy(
                modelName: modelName,
                modelId: modelId,
                messages: [ChatMessage(role: "user", content: "Use line_count on alpha\nbeta.")],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [Self.lineCountTool()],
                runtime: VMLXServerRuntimeSettings()
            )
        }
    }

    @Test func n2JANGTQMediaPreflightUsesConfigAndWeights() throws {
        let bundle = try VisionBundleFixture.make(type: "qwen3_5_moe")
        defer { try? FileManager.default.removeItem(at: bundle) }

        let message = ChatMessage(
            role: "user",
            content: "describe this",
            contentParts: [
                .text("describe this"),
                .imageUrl(url: "data:image/png;base64,AAAA", detail: nil),
                .videoUrl(url: "data:video/mp4;base64,AAAA"),
            ]
        )

        try MLXService.validateRuntimePolicy(
            modelName: "nex-n2-pro-jangtq2",
            modelId: "Nex-N2-Pro-JANGTQ2",
            messages: [message],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16),
            tools: [],
            runtime: VMLXServerRuntimeSettings(),
            modelDirectory: bundle
        )
    }

    @Test func mimoNameAloneCannotAdmitMedia() {
        let message = ChatMessage(
            role: "user",
            content: "describe this",
            contentParts: [
                .text("describe this"),
                .imageUrl(url: "data:image/png;base64,AAAA", detail: nil),
                .audioInput(data: "AAAA", format: "wav"),
            ]
        )

        do {
            try MLXService.validateRuntimePolicy(
                modelName: "mimo-v2.5-jangtq_2",
                modelId: "JANGQ-AI/MiMo-V2.5-JANGTQ_2",
                messages: [message],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: VMLXServerRuntimeSettings()
            )
            Issue.record("Media must remain blocked without installed component evidence.")
        } catch let error as MLXService.RuntimePolicyError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("Image input is not advertised"))
            #expect(description.contains("Audio input is not backed by the installed bundle"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private static func lineCountTool() -> OsaurusCore.Tool {
        OsaurusCore.Tool(
            type: "function",
            function: ToolFunction(
                name: "line_count",
                description: "Count lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")]),
                ])
            )
        )
    }

}
