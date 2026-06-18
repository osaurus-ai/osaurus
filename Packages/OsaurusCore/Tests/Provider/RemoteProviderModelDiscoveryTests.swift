//
//  RemoteProviderModelDiscoveryTests.swift
//  osaurusTests
//
//  Covers OpenAI-compatible model discovery fallbacks for providers whose
//  `/models` endpoint is absent or not OpenAI-schema-compatible.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider model discovery")
struct RemoteProviderModelDiscoveryTests {

    @Test func openAICompatibleDiscovery_usesManualModelsWhenModelsEndpointIsMissing() throws {
        let provider = makeProvider(
            manualModelIds: [" MiniMax-Text-01 ", "", "minimax-text-01"]
        )
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 404,
            provider: provider
        )

        #expect(models == ["MiniMax-Text-01"])
    }

    @Test func openResponsesDiscovery_usesManualModelsWhenModelsSchemaIsIncompatible() throws {
        let provider = makeProvider(
            providerType: .openResponses,
            manualModelIds: ["direct-chat"]
        )
        let body = Data(#"{"models":["not-openai-shape"]}"#.utf8)

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["direct-chat"])
    }

    @Test func openAICompatibleDiscovery_doesNotFallbackForUnauthorizedModelsResponse() {
        let provider = makeProvider(manualModelIds: ["direct-chat"])
        let body = Data(#"{"error":{"message":"bad key"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 401,
                provider: provider
            )
        }
    }

    @Test func openAICompatibleDiscovery_doesNotFallbackWithoutManualModels() {
        let provider = makeProvider()
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 404,
                provider: provider
            )
        }
    }

    @Test func nonOpenAICompatibleDiscovery_doesNotUseManualModelsFallback() {
        let provider = makeProvider(providerType: .anthropic, manualModelIds: ["direct-chat"])
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 404,
                provider: provider
            )
        }
    }

    @Test func lemonadeModelsPath_canBeRepresentedByBasePath() throws {
        let provider = makeProvider(
            providerProtocol: .http,
            port: 8000,
            basePath: "/api/v1"
        )

        #expect(provider.url(for: "/models")?.absoluteString == "http://127.0.0.1:8000/api/v1/models")
    }

    @Test func modelDiscoveryRequest_carriesBoundedTimeoutAndProviderHeaders() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8000/v1/models"))

        let request = RemoteProviderService.modelDiscoveryRequest(
            url: url,
            headers: ["Authorization": "Bearer test", "X-Test": "one"],
            timeout: 45
        )

        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(request.value(forHTTPHeaderField: "X-Test") == "one")
    }

    @Test func modelDiscoveryTimeout_clampsInvalidAndTinyValues() {
        #expect(RemoteProviderService.modelDiscoveryTimeout(.infinity) == 30)
        #expect(RemoteProviderService.modelDiscoveryTimeout(0) == 1)
        #expect(RemoteProviderService.modelDiscoveryTimeout(10) == 10)
    }

    @Test func lemonadeModelsResponse_parsesOpenAIListWithExtraFields() throws {
        let provider = makeProvider(basePath: "/api/v1")
        let body = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "lemonade-chat",
                  "object": "model",
                  "created": 0,
                  "owned_by": "lemonade",
                  "context_length": 131072,
                  "capabilities": ["chat"]
                }
              ]
            }
            """.utf8
        )

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["lemonade-chat"])
    }

    @Test func lemonadeModelsResponse_ignoresFractionalSizeMetadata() throws {
        let provider = makeProvider(basePath: "/api/v1")
        let body = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "Cogito-v2-llama-109B-MoE-GGUF",
                  "object": "model",
                  "created": 1234567890,
                  "owned_by": "lemonade",
                  "size": 65.3,
                  "labels": ["vision"],
                  "checkpoint": "unsloth/cogito-v2-preview-llama-109B-MoE-GGUF:Q4_K_M"
                },
                {
                  "id": "Devstral-Small-2507-GGUF",
                  "object": "model",
                  "created": 1234567890,
                  "owned_by": "lemonade",
                  "size": 14.3,
                  "suggested": true
                }
              ]
            }
            """.utf8
        )

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["Cogito-v2-llama-109B-MoE-GGUF", "Devstral-Small-2507-GGUF"])
    }

    @Test func lemonadeIssuePayload_parsesMixedRecipesAndMissingSize() throws {
        let provider = makeProvider(basePath: "/api/v1")
        let body = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "checkpoint": "black-forest-labs/FLUX.2-klein-4B:flux-2-klein-4b.safetensors",
                  "checkpoints": {
                    "main": "black-forest-labs/FLUX.2-klein-4B:flux-2-klein-4b.safetensors",
                    "text_encoder": "Comfy-Org/vae-text-encorder-for-flux-klein-4b:split_files/text_encoders/qwen_3_4b.safetensors",
                    "vae": "Comfy-Org/vae-text-encorder-for-flux-klein-4b:split_files/vae/flux2-vae.safetensors"
                  },
                  "created": 1234567890,
                  "downloaded": true,
                  "id": "Flux-2-Klein-4B",
                  "image_defaults": {"cfg_scale": 1.0, "height": 1024, "steps": 4, "width": 1024},
                  "labels": ["image"],
                  "object": "model",
                  "owned_by": "lemonade",
                  "recipe": "sd-cpp",
                  "recipe_options": {"cfg_scale": 1.0, "height": 1024, "steps": 4, "width": 1024},
                  "size": 16.0,
                  "suggested": true
                },
                {
                  "checkpoint": "",
                  "checkpoints": {"main": ""},
                  "composite_models": ["gpt-oss-20b-mxfp4-GGUF", "SDXL-Turbo"],
                  "created": 1234567890,
                  "downloaded": true,
                  "id": "Lemonade Medium",
                  "labels": [],
                  "object": "model",
                  "owned_by": "lemonade",
                  "recipe": "experience",
                  "recipe_options": {},
                  "suggested": false
                },
                {
                  "checkpoint": "ggerganov/whisper.cpp:ggml-large-v3-turbo.bin",
                  "checkpoints": {
                    "main": "ggerganov/whisper.cpp:ggml-large-v3-turbo.bin",
                    "npu_cache": "amd/whisper-large-turbo-onnx-npu:ggml-large-v3-turbo-encoder-vitisai.rai"
                  },
                  "created": 1234567890,
                  "downloaded": true,
                  "id": "Whisper-Large-v3-Turbo",
                  "labels": ["audio", "transcription", "hot"],
                  "object": "model",
                  "owned_by": "lemonade",
                  "recipe": "whispercpp",
                  "recipe_options": {},
                  "size": 1.55,
                  "suggested": true
                }
              ]
            }
            """.utf8
        )

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["Flux-2-Klein-4B", "Lemonade Medium", "Whisper-Large-v3-Turbo"])
    }

    private func makeProvider(
        providerProtocol: RemoteProviderProtocol = .https,
        port: Int? = nil,
        basePath: String = "/v1",
        providerType: RemoteProviderType = .openaiLegacy,
        manualModelIds: [String] = []
    ) -> RemoteProvider {
        RemoteProvider(
            name: "Test Provider",
            host: "127.0.0.1",
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            authType: .none,
            providerType: providerType,
            manualModelIds: manualModelIds
        )
    }
}
