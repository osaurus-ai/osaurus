//
//  RemoteChatRequestEncodingTests.swift
//  osaurusTests
//
//  Pins the on-the-wire key-name choice between `max_tokens` and
//  `max_completion_tokens` for the openaiLegacy outbound path. Issue
//  #556 reported a 422 from Mistral ("Extra inputs are not permitted,
//  `max_completion_tokens`") because OpenAI-compatible third-party
//  providers reject OpenAI's newer parameter name. The encoder now
//  emits the widely-accepted `max_tokens` by default and only switches
//  to `max_completion_tokens` for the OpenAI reasoning-model families
//  (o-series, gpt-5+) that require it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RemoteChatRequest encoding")
struct RemoteChatRequestEncodingTests {

    @Test func encode_nonReasoningModel_usesMaxTokens() throws {
        let request = Self.makeRequest(model: "mistral-large-latest", maxTokens: 1024)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["max_tokens"] as? Int == 1024)
        #expect(payload["max_completion_tokens"] == nil)
    }

    @Test func encode_openAINonReasoningModel_usesMaxTokens() throws {
        let request = Self.makeRequest(model: "gpt-4o-mini", maxTokens: 512)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["max_tokens"] as? Int == 512)
        #expect(payload["max_completion_tokens"] == nil)
    }

    @Test func encode_openAIReasoningModel_usesMaxCompletionTokens() throws {
        let request = Self.makeRequest(model: "o1-mini", maxTokens: 2048)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["max_completion_tokens"] as? Int == 2048)
        #expect(payload["max_tokens"] == nil)
    }

    @Test func encode_gpt5ReasoningModel_usesMaxCompletionTokens() throws {
        let request = Self.makeRequest(model: "gpt-5-nano", maxTokens: 4096)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["max_completion_tokens"] as? Int == 4096)
        #expect(payload["max_tokens"] == nil)
    }

    @Test func encode_nilMaxTokens_omitsBothKeys() throws {
        let request = Self.makeRequest(model: "mistral-small-latest", maxTokens: nil)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["max_tokens"] == nil)
        #expect(payload["max_completion_tokens"] == nil)
    }

    @Test func openResponsesRequest_defaultSingleUserMessage_usesTextShorthand() throws {
        let request = Self.makeRequest(model: "gpt-5.2", maxTokens: 1024)
        let responsesRequest = request.toOpenResponsesRequest()
        let payload = try Self.encodeAsDictionary(responsesRequest)

        #expect(payload["input"] as? String == "hi")
    }

    @Test func openResponsesRequest_forcedInputItems_usesList() throws {
        let request = Self.makeRequest(model: "gpt-5.2", maxTokens: 1024)
        let responsesRequest = request.toCodexOpenResponsesRequest()
        let payload = try Self.encodeAsDictionary(responsesRequest)

        #expect(payload["input"] is [[String: Any]])
    }

    @Test func codexRequest_removesMaxOutputTokens() throws {
        let request = Self.makeRequest(model: "gpt-5.2", maxTokens: 1024)
        let payload = try Self.decodeAsDictionary(request.toCodexOpenResponsesRequest().toCodexOAuthPayloadData())

        #expect(payload["input"] is [[String: Any]])
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["store"] as? Bool == false)
    }

    @Test func azureProvider_usesAPIKeyHeader() throws {
        let providerId = UUID()
        defer { RemoteProviderKeychain.deleteAPIKey(for: providerId) }

        let provider = RemoteProvider(
            id: providerId,
            name: "Azure OpenAI Foundry",
            host: "example-resource.cognitiveservices.azure.com",
            basePath: "/openai/v1",
            authType: .apiKey,
            providerType: .azureOpenAI
        )

        #expect(RemoteProviderKeychain.saveAPIKey("azure-secret", for: providerId))

        let headers = provider.resolvedHeaders()
        #expect(headers["api-key"] == "azure-secret")
        #expect(headers["Authorization"] == nil)
    }

    @Test func azureProvider_defaultURLUsesOpenAIPath() throws {
        let provider = RemoteProvider(
            name: "Azure OpenAI Foundry",
            host: "example-resource.cognitiveservices.azure.com",
            basePath: "/openai/v1",
            authType: .apiKey,
            providerType: .azureOpenAI
        )

        #expect(
            provider.url(for: provider.providerType.chatEndpoint)?.absoluteString
                == "https://example-resource.cognitiveservices.azure.com/openai/v1/chat/completions"
        )
    }

    @Test func remoteProvider_mergesManualModelIdsWithDiscoveredModels() throws {
        let provider = RemoteProvider(
            name: "Custom",
            host: "api.example.com",
            providerType: .openaiLegacy,
            manualModelIds: [" gpt-5.4 ", "", "prod-chat", "GPT-5.4"]
        )

        #expect(provider.mergedModelIds(discovered: ["gpt-4.1", "prod-chat"]) == ["gpt-4.1", "prod-chat", "gpt-5.4"])
    }

    @Test func remoteProvider_decodingDefaultsManualModelIdsToEmptyArray() throws {
        let json = """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "name": "Custom",
              "host": "localhost",
              "providerProtocol": "http",
              "basePath": "/v1",
              "customHeaders": {},
              "authType": "none",
              "providerType": "openai",
              "enabled": true,
              "autoConnect": true,
              "timeout": 60,
              "secretHeaderKeys": []
            }
            """

        let provider = try JSONDecoder().decode(RemoteProvider.self, from: Data(json.utf8))

        #expect(provider.manualModelIds == [])
    }

    @Test func azureProvider_disablesOpenAICompatibleReasoningObject() throws {
        #expect(
            RemoteProviderService.allowsChatCompletionsReasoningObject(
                providerType: .azureOpenAI,
                host: "example-resource.cognitiveservices.azure.com"
            ) == false
        )
        #expect(
            RemoteProviderService.allowsChatCompletionsReasoningObject(
                providerType: .openaiLegacy,
                host: "api.openai.com"
            )
                == false
        )
        #expect(
            RemoteProviderService.allowsChatCompletionsReasoningObject(
                providerType: .openaiLegacy,
                host: "api.deepseek.com"
            )
                == true
        )
    }

    @Test func azureProvider_routesReasoningRequestsThroughResponses() throws {
        let request = Self.makeRequest(
            model: "gpt-5.5",
            maxTokens: 1024,
            reasoningEffort: "medium"
        )

        #expect(
            RemoteProviderService.effectiveRequestProviderType(
                configuredProviderType: .azureOpenAI,
                request: request
            ) == .openResponses
        )
    }

    @Test func azureProvider_routesToolRequestsThroughResponses() throws {
        let request = Self.makeRequest(
            model: "gpt-5.5",
            maxTokens: 1024,
            reasoningEffort: nil,
            tools: [Self.weatherTool]
        )

        #expect(
            RemoteProviderService.effectiveRequestProviderType(
                configuredProviderType: .azureOpenAI,
                request: request
            ) == .openResponses
        )
    }

    @Test func azureProvider_keepsPlainRequestsOnChatCompletions() throws {
        let request = Self.makeRequest(model: "gpt-4.1", maxTokens: 1024)

        #expect(
            RemoteProviderService.effectiveRequestProviderType(
                configuredProviderType: .azureOpenAI,
                request: request
            ) == .azureOpenAI
        )
    }

    @Test func azureProvider_usesOnlyManualDeploymentIdsForModels() throws {
        let provider = RemoteProvider(
            name: "Azure OpenAI Foundry",
            host: "example-resource.cognitiveservices.azure.com",
            providerType: .azureOpenAI,
            manualModelIds: [" prod-chat ", "", "gpt-5.5", "PROD-CHAT"]
        )

        #expect(provider.mergedModelIds(discovered: ["gpt-4.1", "gpt-5.5"]) == ["prod-chat", "gpt-5.5"])
    }

    // MARK: - Fixtures

    private static func makeRequest(
        model: String,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [Tool]? = nil
    ) -> RemoteChatRequest {
        RemoteChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.7,
            max_completion_tokens: maxTokens,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: tools,
            tool_choice: nil,
            reasoning_effort: reasoningEffort,
            reasoning: nil,
            modelOptions: [:],
            veniceParameters: nil
        )
    }

    private static let weatherTool = Tool(
        type: "function",
        function: ToolFunction(
            name: "get_weather",
            description: "Get weather",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "location": .object(["type": .string("string")])
                ]),
            ])
        )
    )

    private static func encodeAsDictionary(_ request: RemoteChatRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    private static func encodeAsDictionary(_ request: OpenResponsesRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    private static func decodeAsDictionary(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    private enum DecodeAsDictionaryError: Error { case notAnObject }
}
