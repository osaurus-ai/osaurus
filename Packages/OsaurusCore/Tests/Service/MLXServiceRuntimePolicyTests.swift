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

    @Test func serverSettingRejectsVideoWhenDisabled() {
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
                runtime: runtime
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

        // Dense text Gemma-4 (no `-it`): the `-it` instruct bundles are the
        // Gemma-4 VLMs and map to image-only, while the dense LLM distillations
        // such as `Gemma-4-31B-JANG_4M` are text-only and must reject images.
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
            runtime: VMLXServerRuntimeSettings()
        )
    }

    @Test func modelCapabilityRejectsAudioForQwenVL() {
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
                runtime: VMLXServerRuntimeSettings()
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

        // Name-only detection cannot see the weight map, so audio stays
        // rejected with the per-bundle gating message — NOT a blanket
        // "runtime unwired" claim. With an installed bundle directory,
        // capability comes from the weight map itself: 12B unified and
        // E-series checkpoints ship audio tensors; 26B-A4B/31B do not.
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
            #expect(description.contains("Gemma4 audio is enabled per-bundle"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func policyRejectsKnownBadZayaVLJANGTQKDiagnosticArtifact() {
        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "zaya1-vl-8b-jangtq_k",
                modelId: "JANGQ/ZAYA1-VL-8B-JANGTQ_K",
                messages: [ChatMessage(role: "user", content: "Compute 7 + 8 - 11.")],
                parameters: GenerationParameters(temperature: nil, maxTokens: 16),
                tools: [],
                runtime: VMLXServerRuntimeSettings()
            )
        }
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

    @Test func n2JANGTQMediaPreflightUsesBundleVisionConfig() throws {
        let bundle = try Self.makeMediaCapabilityBundle(
            modelType: "qwen3_5_moe",
            hasVisionConfig: true
        )
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

    @Test func mimoJANGTQMediaPreflightStaysBlockedUntilVMLXHasMediaRuntime() {
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
            Issue.record("MiMo media should remain blocked until vMLX ships MiMo media runtime support.")
        } catch let error as MLXService.RuntimePolicyError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("Image input is not advertised"))
            #expect(description.contains("Audio input is not advertised"))
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

    private static func makeMediaCapabilityBundle(
        modelType: String,
        hasVisionConfig: Bool
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-media-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config: [String: Any] = ["model_type": modelType]
        if hasVisionConfig {
            config["vision_config"] = ["image_size": 224]
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("config.json"))
        return directory
    }
}
