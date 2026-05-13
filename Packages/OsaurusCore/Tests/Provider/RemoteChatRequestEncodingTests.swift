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

    @Test func deepSeekProvider_dropsLocalInstructReasoningEffort() throws {
        #expect(
            RemoteProviderService.chatCompletionsReasoningEffort(
                providerType: .openaiLegacy,
                host: "api.deepseek.com",
                effort: "instruct"
            ) == nil
        )
    }

    @Test func deepSeekProvider_preservesAcceptedReasoningEfforts() throws {
        for effort in ["low", "medium", "high", "max", "xhigh"] {
            #expect(
                RemoteProviderService.chatCompletionsReasoningEffort(
                    providerType: .openaiLegacy,
                    host: "api.deepseek.com",
                    effort: effort
                ) == effort
            )
        }
    }

    @Test func remoteChatReasoningControls_deepSeekNormalizesAndFiltersEfforts() throws {
        let accepted = RemoteProviderService.remoteChatReasoningControls(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro",
            effort: "  MAX  "
        )
        #expect(accepted.effort == "max")
        #expect(accepted.thinking == nil)

        let direct = RemoteProviderService.remoteChatReasoningControls(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro",
            effort: "instruct"
        )
        #expect(direct.effort == nil)
        #expect(direct.thinking == ThinkingConfig(type: "disabled"))

        let unknown = RemoteProviderService.remoteChatReasoningControls(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro",
            effort: "reasoning"
        )
        #expect(unknown.effort == nil)
        #expect(unknown.thinking == nil)
    }

    // MARK: - `reasoning_content` echo (issue #959)

    @Test func chatMessage_encode_includesReasoningContentWhenPresent() throws {
        let message = ChatMessage(
            role: "assistant",
            content: "hi",
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: "let me think..."
        )

        let data = try JSONEncoder().encode(message)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(obj["reasoning_content"] as? String == "let me think...")
    }

    @Test func chatMessage_encode_omitsReasoningContentWhenNil() throws {
        let message = ChatMessage(role: "assistant", content: "hi", tool_calls: nil, tool_call_id: nil)

        let data = try JSONEncoder().encode(message)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(obj["reasoning_content"] == nil)
    }

    @Test func chatMessage_decode_roundTripsReasoningContent() throws {
        let json = """
            {"role":"assistant","content":"hi","reasoning_content":"thinking..."}
            """

        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        #expect(message.reasoning_content == "thinking...")
        #expect(message.content == "hi")
    }

    @Test func echoesReasoningContent_trueForDeepSeekHost() throws {
        #expect(
            RemoteProviderService.echoesReasoningContent(
                providerType: .openaiLegacy,
                host: "api.deepseek.com"
            ) == true
        )
    }

    @Test func echoesReasoningContent_falseForOtherOpenAICompatHosts() throws {
        for host in ["api.x.ai", "api.venice.ai", "openrouter.ai", "api.openai.com", "api.together.xyz"] {
            #expect(
                RemoteProviderService.echoesReasoningContent(
                    providerType: .openaiLegacy,
                    host: host
                ) == false
            )
        }
    }

    @Test func echoesReasoningContent_falseForNonOpenAICompatProviders() throws {
        for providerType: RemoteProviderType in [.anthropic, .openResponses, .openAICodex, .gemini, .osaurus] {
            #expect(
                RemoteProviderService.echoesReasoningContent(
                    providerType: providerType,
                    host: "api.deepseek.com"
                ) == false
            )
        }
    }

    @Test func strippingReasoningContent_clearsAssistantReasoningPreservingOtherFields() throws {
        let toolCall = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(name: "lookup", arguments: "{}")
        )
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "q"),
            ChatMessage(
                role: "assistant",
                content: "answer",
                tool_calls: [toolCall],
                tool_call_id: nil,
                reasoning_content: "private thought"
            ),
            ChatMessage(role: "tool", content: "result", tool_calls: nil, tool_call_id: "c1"),
        ]

        let stripped = RemoteProviderService.strippingReasoningContent(from: messages)

        #expect(stripped.count == 3)
        #expect(stripped[1].reasoning_content == nil)
        #expect(stripped[1].content == "answer")
        #expect(stripped[1].tool_calls?.first?.id == "c1")
        #expect(stripped[2].tool_call_id == "c1")
    }

    @Test func strippingReasoningContent_returnsMessagesUnchangedWhenNoneHaveReasoning() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "hi"),
            ChatMessage(role: "assistant", content: "hello", tool_calls: nil, tool_call_id: nil),
        ]

        let stripped = RemoteProviderService.strippingReasoningContent(from: messages)

        #expect(stripped.count == 2)
        #expect(stripped[0].reasoning_content == nil)
        #expect(stripped[1].reasoning_content == nil)
    }

    // MARK: - DSV4 remote effort translation
    //
    // `DSV4ReasoningProfile` defaults `reasoningEffort` to `"instruct"`, but
    // DeepSeek's public chat API rejects that value: `reasoning_effort` must
    // be one of `high`/`max` (plus the deprecated `low`/`medium`/`xhigh`
    // aliases). Reasoning is toggled separately via `thinking.type`. These
    // tests pin the wire translation so the regression in the bug report
    // ("unknown variant `instruct`") cannot return silently.

    @Test func dsv4RemoteEffort_deepSeekHost_translatesInstructToThinkingDisabled() throws {
        // Trims/case-normalizes before matching so persisted values like
        // "  INSTRUCT  " still translate correctly.
        for raw in ["instruct", "  INSTRUCT  "] {
            let translated = RemoteProviderService.dsv4RemoteEffort(
                host: "api.deepseek.com",
                model: "deepseek-v4-pro",
                effort: raw
            )

            #expect(translated.effort == nil)
            #expect(translated.thinking == ThinkingConfig(type: "disabled"))
        }
    }

    @Test func dsv4RemoteEffort_deepSeekHost_forwardsAcceptedEffortsUntouched() throws {
        for effort in ["high", "max", "low", "medium", "xhigh"] {
            let translated = RemoteProviderService.dsv4RemoteEffort(
                host: "api.deepseek.com",
                model: "deepseek-v4-pro",
                effort: effort
            )

            #expect(translated.effort == effort)
            #expect(translated.thinking == nil)
        }
    }

    @Test func dsv4RemoteEffort_normalizesAcceptedEffortCasing() throws {
        let translated = RemoteProviderService.dsv4RemoteEffort(
            host: "api.deepseek.com",
            model: "deepseek-v4-pro",
            effort: "  HIGH  "
        )

        #expect(translated.effort == "high")
        #expect(translated.thinking == nil)
    }

    @Test func dsv4RemoteEffort_nonDeepSeekHost_stripsInstructWithoutThinkingField() throws {
        // OpenRouter and other OpenAI-compat hosts that may serve DSV4 IDs
        // will also reject `"instruct"`, but the DeepSeek-only `thinking`
        // field must NOT be injected — strict schemas 422 on unknown keys.
        let translated = RemoteProviderService.dsv4RemoteEffort(
            host: "openrouter.ai",
            model: "deepseek/deepseek-v4-pro",
            effort: "instruct"
        )

        #expect(translated.effort == nil)
        #expect(translated.thinking == nil)
    }

    @Test func dsv4RemoteEffort_stripsDirectRailAliasesForAllRemoteModels() throws {
        // Direct/off aliases are local runtime controls. Public remote schemas
        // reject them as `reasoning_effort` values, even when the model is not
        // a local DSV4 bundle.
        for effort in ["instruct", "none", "no_think", "off", "disabled", "false"] {
            let nonDSV4 = RemoteProviderService.dsv4RemoteEffort(
                host: "api.openai.com",
                model: "gpt-5.5",
                effort: effort
            )
            #expect(nonDSV4.effort == nil)
            #expect(nonDSV4.thinking == nil)
        }

        // Nil effort: nothing to translate, nothing to inject.
        let nilEffort = RemoteProviderService.dsv4RemoteEffort(
            host: "api.deepseek.com",
            model: "deepseek-v4-pro",
            effort: nil
        )
        #expect(nilEffort.effort == nil)
        #expect(nilEffort.thinking == nil)
    }

    @Test func encode_thinkingDisabled_emitsThinkingObjectWithoutReasoningEffort() throws {
        let request = Self.makeRequest(
            model: "deepseek-v4-pro",
            maxTokens: 1024,
            reasoningEffort: nil,
            thinking: ThinkingConfig(type: "disabled")
        )

        let payload = try Self.encodeAsDictionary(request)
        let thinking = try #require(payload["thinking"] as? [String: Any])

        #expect(thinking["type"] as? String == "disabled")
        #expect(payload["reasoning_effort"] == nil)
    }

    @Test func encode_nilThinking_omitsKey() throws {
        let request = Self.makeRequest(
            model: "deepseek-v4-pro",
            maxTokens: 1024,
            reasoningEffort: "high",
            thinking: nil
        )

        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["thinking"] == nil)
        #expect(payload["reasoning_effort"] as? String == "high")
    }

    // MARK: - Fixtures

    private static func makeRequest(
        model: String,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [Tool]? = nil,
        thinking: ThinkingConfig? = nil
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
            thinking: thinking,
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
