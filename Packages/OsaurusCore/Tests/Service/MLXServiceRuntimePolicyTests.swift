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

        #expect(throws: MLXService.RuntimePolicyError.self) {
            try MLXService.validateRuntimePolicy(
                modelName: "gemma-4-31b-it-jang_4m",
                modelId: "OsaurusAI/Gemma-4-31B-it-JANG_4M",
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
}
