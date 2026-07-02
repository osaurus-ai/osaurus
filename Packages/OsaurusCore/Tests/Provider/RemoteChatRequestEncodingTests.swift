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

    // MARK: - Router idempotency key (double-billing guard)

    /// The router idempotency token rides the request BODY (so it's covered by
    /// the `sha256(body)` signature). A re-POST with the same key lets the
    /// router dedupe the charge.
    @Test func encode_includesIdempotencyKey_whenSet() throws {
        var request = Self.makeRequest(model: "venice/minimax-m3", maxTokens: 256)
        request.idempotencyKey = "run-abc:2"
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["idempotency_key"] as? String == "run-abc:2")
    }

    /// Non-router paths never set the key, so it must be omitted (some
    /// OpenAI-compat upstreams 422 on unknown top-level fields).
    @Test func encode_omitsIdempotencyKey_whenNil() throws {
        let request = Self.makeRequest(model: "gpt-4o-mini", maxTokens: 256)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["idempotency_key"] == nil)
    }

    // MARK: - stream_options.include_usage (remote completion-token telemetry)

    /// When set, `stream_options` encodes as the nested OpenAI object so the
    /// upstream emits a final `usage` chunk we surface as completion tokens.
    @Test func encode_includesStreamOptions_whenSet() throws {
        var request = Self.makeRequest(model: "grok-4", maxTokens: 256)
        request.streamOptions = StreamOptions(include_usage: true)
        let payload = try Self.encodeAsDictionary(request)

        let streamOptions = payload["stream_options"] as? [String: Any]
        #expect(streamOptions?["include_usage"] as? Bool == true)
    }

    /// Default (nil) omits the key entirely, so every provider/path that does
    /// not opt in keeps its exact current wire bytes.
    @Test func encode_omitsStreamOptions_whenNil() throws {
        let request = Self.makeRequest(model: "gpt-4o-mini", maxTokens: 256)
        let payload = try Self.encodeAsDictionary(request)

        #expect(payload["stream_options"] == nil)
    }

    /// Only the genuinely OpenAI Chat-Completions `/chat/completions` upstreams
    /// (xAI/Grok + OpenAI-compatible third parties via `.openaiLegacy`, and
    /// Azure OpenAI) request usage. The router carries billed tokens in its own
    /// summary frame; Anthropic/Gemini/Responses/Codex use other shapes.
    @Test func requestsStreamUsageOptions_truthTable() {
        #expect(RemoteProviderService.requestsStreamUsageOptions(providerType: .openaiLegacy))
        #expect(RemoteProviderService.requestsStreamUsageOptions(providerType: .azureOpenAI))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .osaurus))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .osaurusRouter))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .anthropic))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .gemini))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .openResponses))
        #expect(!RemoteProviderService.requestsStreamUsageOptions(providerType: .openAICodex))
    }

    @Test func routerImplicitMaxTokens_forwardsChatDefaultToAvoidUpstream1024Cap() {
        let params = GenerationParameters(
            temperature: nil,
            maxTokens: 16_384,
            maxTokensExplicit: false
        )

        #expect(
            RemoteProviderService.remoteChatMaxTokens(
                providerType: .osaurusRouter,
                parameters: params
            ) == 16_384
        )
    }

    @Test func nonRouterImplicitMaxTokens_preservesProviderDefault() {
        let params = GenerationParameters(
            temperature: nil,
            maxTokens: 16_384,
            maxTokensExplicit: false
        )

        #expect(
            RemoteProviderService.remoteChatMaxTokens(
                providerType: .openaiLegacy,
                parameters: params
            ) == nil
        )
    }

    @Test func openResponsesRequest_defaultSingleUserMessage_usesTextShorthand() throws {
        let request = Self.makeRequest(model: "gpt-5.2", maxTokens: 1024)
        let responsesRequest = request.toOpenResponsesRequest()
        let payload = try Self.encodeAsDictionary(responsesRequest)

        #expect(payload["input"] as? String == "hi")
    }

    /// A two-turn tool loop must re-send the captured reasoning item
    /// (id + encrypted_content) immediately BEFORE the assistant's
    /// function_call, so a reasoning model resumes its chain instead of
    /// re-deriving it.
    @Test func openResponsesRequest_reEmitsReasoningItemBeforeFunctionCall() throws {
        let request = RemoteChatRequest(
            model: "gpt-5.2",
            messages: [
                ChatMessage(role: "user", content: "what's the weather?"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call_1",
                            type: "function",
                            function: ToolCallFunction(name: "get_weather", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil,
                    reasoning_content: nil,
                    reasoning_item_id: "rs_abc123",
                    reasoning_encrypted: "ENCRYPTED_BLOB"
                ),
                ChatMessage(role: "tool", content: "sunny", tool_calls: nil, tool_call_id: "call_1"),
            ],
            temperature: nil,
            max_completion_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )

        let responsesRequest = request.toOpenResponsesRequest(alwaysUseInputItems: true)
        guard case .items(let items) = responsesRequest.input else {
            Issue.record("expected items input")
            return
        }

        // Find the reasoning item and the function call; reasoning must precede it.
        let reasoningIndex = items.firstIndex { item in
            if case .reasoning = item { return true }
            return false
        }
        let functionCallIndex = items.firstIndex { item in
            if case .functionCall = item { return true }
            return false
        }
        let reasoningIdx = try #require(reasoningIndex, "no reasoning input item emitted")
        let funcIdx = try #require(functionCallIndex, "no function_call input item emitted")
        #expect(reasoningIdx < funcIdx, "reasoning item must come before its function_call")

        // Verify the emitted reasoning item carries id + encrypted_content.
        if case .reasoning(let reasoning) = items[reasoningIdx] {
            #expect(reasoning.id == "rs_abc123")
            #expect(reasoning.encrypted_content == "ENCRYPTED_BLOB")
            #expect(reasoning.type == "reasoning")
        } else {
            Issue.record("item at reasoning index was not a reasoning item")
        }

        // The encoded payload contains the reasoning item with its blob.
        let payload = try Self.encodeAsDictionary(responsesRequest)
        let inputArray = try #require(payload["input"] as? [[String: Any]])
        let reasoningDict = inputArray.first { ($0["type"] as? String) == "reasoning" }
        let reasoningObj = try #require(reasoningDict)
        #expect(reasoningObj["id"] as? String == "rs_abc123")
        #expect(reasoningObj["encrypted_content"] as? String == "ENCRYPTED_BLOB")
    }

    /// A plain-answer turn (no tool call) must also re-send the captured
    /// reasoning item immediately BEFORE the assistant message, so a reasoning
    /// model resumes its chain on follow-ups that didn't end in a tool call.
    @Test func openResponsesRequest_reEmitsReasoningItemBeforeAssistantMessage() throws {
        let request = RemoteChatRequest(
            model: "gpt-5.2",
            messages: [
                ChatMessage(role: "user", content: "explain quicksort"),
                ChatMessage(
                    role: "assistant",
                    content: "Quicksort partitions around a pivot...",
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: nil,
                    reasoning_item_id: "rs_text1",
                    reasoning_encrypted: "TEXT_BLOB"
                ),
                ChatMessage(role: "user", content: "what's its worst case?"),
            ],
            temperature: nil,
            max_completion_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )

        let responsesRequest = request.toOpenResponsesRequest(alwaysUseInputItems: true)
        guard case .items(let items) = responsesRequest.input else {
            Issue.record("expected items input")
            return
        }

        let reasoningIdx = try #require(
            items.firstIndex { if case .reasoning = $0 { return true } else { return false } },
            "no reasoning input item emitted"
        )
        let assistantMsgIdx = try #require(
            items.firstIndex { item in
                if case .message(let m) = item, m.role == "assistant" { return true }
                return false
            },
            "no assistant message input item emitted"
        )
        #expect(reasoningIdx < assistantMsgIdx, "reasoning item must precede the assistant message")
        if case .reasoning(let reasoning) = items[reasoningIdx] {
            #expect(reasoning.id == "rs_text1")
            #expect(reasoning.encrypted_content == "TEXT_BLOB")
        } else {
            Issue.record("item at reasoning index was not a reasoning item")
        }
    }

    /// When no reasoning item was captured (non-reasoning provider), the
    /// function_call history is emitted without a stray reasoning item.
    @Test func openResponsesRequest_omitsReasoningItem_whenNoneCaptured() throws {
        let request = RemoteChatRequest(
            model: "gpt-5.2",
            messages: [
                ChatMessage(role: "user", content: "hi"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call_1",
                            type: "function",
                            function: ToolCallFunction(name: "noop", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: "ok", tool_calls: nil, tool_call_id: "call_1"),
            ],
            temperature: nil,
            max_completion_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )

        let responsesRequest = request.toOpenResponsesRequest(alwaysUseInputItems: true)
        guard case .items(let items) = responsesRequest.input else {
            Issue.record("expected items input")
            return
        }
        let hasReasoning = items.contains { item in
            if case .reasoning = item { return true }
            return false
        }
        #expect(!hasReasoning, "no reasoning item should be emitted when none was captured")
    }

    /// A reasoning request must ask for a human-readable summary
    /// (`reasoning.summary == "auto"`). Without it the Responses API returns
    /// only the opaque `encrypted_content` blob and the Think panel stays
    /// empty — the user sees no reasoning.
    @Test func openResponsesRequest_reasoningModelRequestsSummary() throws {
        let request = Self.makeRequest(
            model: "gpt-5.5",
            maxTokens: 1024,
            reasoningEffort: "high"
        )
        let responsesRequest = request.toOpenResponsesRequest(alwaysUseInputItems: true)
        let payload = try Self.encodeAsDictionary(responsesRequest)
        let reasoning = try #require(payload["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        #expect(reasoning["summary"] as? String == "auto")
    }

    @Test func openResponsesRequest_forcedInputItems_usesList() throws {
        let request = Self.makeRequest(model: "gpt-5.2", maxTokens: 1024)
        let responsesRequest = request.toCodexOpenResponsesRequest()
        let payload = try Self.encodeAsDictionary(responsesRequest)

        #expect(payload["input"] is [[String: Any]])
    }

    @Test func openResponsesRequest_decodesOpenAIStyleMessageItemWithoutType() throws {
        let data = Data(
            #"""
            {
              "model": "foundation",
              "input": [
                {
                  "role": "user",
                  "content": "Hello!"
                }
              ],
              "stream": false
            }
            """#.utf8
        )

        let responsesRequest = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        let chatRequest = responsesRequest.toChatCompletionRequest()
        let payload = try Self.encodeAsDictionary(responsesRequest)
        let input = try #require(payload["input"] as? [[String: Any]])
        let item = try #require(input.first)

        #expect(chatRequest.messages.map(\.role) == ["user"])
        #expect(chatRequest.messages.first?.content == "Hello!")
        #expect(item["type"] as? String == "message")
    }

    @Test func openResponsesRequest_rejectsExplicitNullMessageType() throws {
        let data = Data(
            #"""
            {
              "model": "foundation",
              "input": [
                {
                  "type": null,
                  "role": "user",
                  "content": "Hello!"
                }
              ],
              "stream": false
            }
            """#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        }
    }

    @Test func openResponsesRequest_rejectsInvalidExplicitMessageType() throws {
        let data = Data(
            #"""
            {
              "model": "foundation",
              "input": [
                {
                  "type": "not_message",
                  "role": "user",
                  "content": "Hello!"
                }
              ],
              "stream": false
            }
            """#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        }
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

        var provider = RemoteProvider(
            id: providerId,
            name: "Azure OpenAI Foundry",
            host: "example-resource.cognitiveservices.azure.com",
            basePath: "/openai/v1",
            authType: .apiKey,
            providerType: .azureOpenAI
        )

        if KeychainQueryHelpers.disablesKeychainForProcess {
            #expect(!RemoteProviderKeychain.saveAPIKey("azure-secret", for: providerId))
            #expect(provider.resolvedHeaders()["api-key"] == nil)

            provider.customHeaders["api-key"] = "azure-secret"
            let headers = provider.resolvedHeaders()
            #expect(headers["api-key"] == "azure-secret")
            #expect(headers["Authorization"] == nil)
            return
        }

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

    @Test func routerWireCompatibleMessages_keepsUserMediaAndStringifiesAssistantContent() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: "I looked at the image.",
            contentParts: [
                .text("I looked at the image."),
                .imageUrl(url: "data:image/png;base64,AAAA", detail: nil),
            ]
        )
        let user = ChatMessage(
            role: "user",
            content: "describe this",
            contentParts: [
                .text("describe this"),
                .imageUrl(url: "data:image/png;base64,BBBB", detail: nil),
            ]
        )

        let normalized = RemoteProviderService.routerWireCompatibleMessages([assistant, user])
        let array = try Self.encodeAsArray(normalized)
        let assistantJSON = try #require(array.first)
        let userJSON = try #require(array.dropFirst().first)

        #expect(assistantJSON["content"] as? String == "I looked at the image.")
        #expect(userJSON["content"] is [[String: Any]])
    }

    @Test func routerWireCompatibleMessages_includesEmptyStringForAssistantToolHistory() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "call_1",
                    type: "function",
                    function: ToolCallFunction(name: "sandbox_exec", arguments: #"{"cmd":"pwd"}"#)
                )
            ],
            tool_call_id: nil
        )

        let normalized = RemoteProviderService.routerWireCompatibleMessages([assistant])
        let array = try Self.encodeAsArray(normalized)
        let assistantJSON = try #require(array.first)

        #expect(assistantJSON["content"] as? String == "")
        #expect(assistantJSON["tool_calls"] != nil)
    }

    @Test func routerWireCompatibleMessages_dropsTrailingPlainAssistantPrefill() throws {
        let messages = [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "Build tetris."),
            ChatMessage(role: "assistant", content: "I'll build that now."),
        ]

        let normalized = RemoteProviderService.routerWireCompatibleMessages(messages)

        #expect(normalized.map(\.role) == ["system", "user"])
        #expect(normalized.last?.content == "Build tetris.")
    }

    @Test func routerWireCompatibleMessages_keepsTrailingAssistantToolCallTurn() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "call_1",
                    type: "function",
                    function: ToolCallFunction(name: "sandbox_write_file", arguments: #"{"path":"tetris.html"}"#)
                )
            ],
            tool_call_id: nil
        )

        let normalized = RemoteProviderService.routerWireCompatibleMessages([
            ChatMessage(role: "user", content: "Build tetris."),
            assistant,
        ])
        let array = try Self.encodeAsArray(normalized)
        let assistantJSON = try #require(array.last)

        #expect(normalized.map { $0.role } == ["user", "assistant"])
        #expect(assistantJSON["content"] as? String == "")
        #expect(assistantJSON["tool_calls"] != nil)
    }

    @Test func routerWireCompatibleMessages_collapsesDuplicateToolResultsByCallId() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "toolu_1",
                    type: "function",
                    function: ToolCallFunction(name: "read_file", arguments: #"{"path":"a"}"#)
                )
            ],
            tool_call_id: nil
        )
        let result = ChatMessage(role: "tool", content: "FILE CONTENTS", tool_calls: nil, tool_call_id: "toolu_1")
        let notice = ChatMessage(
            role: "tool",
            content: "[System Notice] history compacted",
            tool_calls: nil,
            tool_call_id: "toolu_1"
        )

        let normalized = RemoteProviderService.routerWireCompatibleMessages([assistant, result, notice])

        #expect(normalized.map(\.role) == ["assistant", "tool"])
        let toolMessage = try #require(normalized.last)
        #expect(toolMessage.tool_call_id == "toolu_1")
        #expect(toolMessage.content == "FILE CONTENTS\n\n[System Notice] history compacted")
    }

    @Test func routerWireCompatibleMessages_keepsDistinctParallelToolResults() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "toolu_1",
                    type: "function",
                    function: ToolCallFunction(name: "read_file", arguments: "{}")
                ),
                ToolCall(
                    id: "toolu_2",
                    type: "function",
                    function: ToolCallFunction(name: "list_dir", arguments: "{}")
                ),
            ],
            tool_call_id: nil
        )
        let first = ChatMessage(role: "tool", content: "A", tool_calls: nil, tool_call_id: "toolu_1")
        let second = ChatMessage(role: "tool", content: "B", tool_calls: nil, tool_call_id: "toolu_2")

        let normalized = RemoteProviderService.routerWireCompatibleMessages([assistant, first, second])

        #expect(normalized.map(\.role) == ["assistant", "tool", "tool"])
        #expect(normalized.dropFirst().compactMap(\.tool_call_id) == ["toolu_1", "toolu_2"])
        #expect(normalized.dropFirst().compactMap(\.content) == ["A", "B"])
    }

    /// Regression for the Osaurus Router HTTP 400 "each tool_use must have a
    /// single result": a transient `[System Notice]` riding the prior result's
    /// tool_call_id must not become a second tool entry on the wire.
    @Test func routerWireCompatibleMessages_singleToolEntryOnWireForNoticeRide() throws {
        let assistant = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(id: "toolu_1", type: "function", function: ToolCallFunction(name: "run", arguments: "{}"))
            ],
            tool_call_id: nil
        )
        let result = ChatMessage(role: "tool", content: "ok", tool_calls: nil, tool_call_id: "toolu_1")
        let notice = ChatMessage(
            role: "tool",
            content: "[System Notice] nudge",
            tool_calls: nil,
            tool_call_id: "toolu_1"
        )

        let normalized = RemoteProviderService.routerWireCompatibleMessages([assistant, result, notice])
        let array = try Self.encodeAsArray(normalized)

        let toolEntries = array.filter { ($0["tool_call_id"] as? String) == "toolu_1" }
        #expect(toolEntries.count == 1)
        #expect(toolEntries.first?["content"] as? String == "ok\n\n[System Notice] nudge")
    }

    @Test func toAnthropicRequest_emitsSingleToolResultPerToolUseId() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "read the file"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "toolu_1",
                            type: "function",
                            function: ToolCallFunction(name: "read_file", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: "RESULT", tool_calls: nil, tool_call_id: "toolu_1"),
                ChatMessage(role: "tool", content: "[System Notice] note", tool_calls: nil, tool_call_id: "toolu_1"),
            ]
        )

        let anthropic = request.toAnthropicRequest()
        let blocks = Self.toolResultBlocks(in: anthropic)

        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.tool_use_id == "toolu_1")
        let text = block.content?.plainText ?? ""
        #expect(text.contains("RESULT"))
        #expect(text.contains("[System Notice] note"))
    }

    @Test func toAnthropicRequest_keepsDistinctToolResults() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "toolu_1",
                            type: "function",
                            function: ToolCallFunction(name: "a", arguments: "{}")
                        ),
                        ToolCall(
                            id: "toolu_2",
                            type: "function",
                            function: ToolCallFunction(name: "b", arguments: "{}")
                        ),
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: "A", tool_calls: nil, tool_call_id: "toolu_1"),
                ChatMessage(role: "tool", content: "B", tool_calls: nil, tool_call_id: "toolu_2"),
            ]
        )

        let anthropic = request.toAnthropicRequest()
        let blocks = Self.toolResultBlocks(in: anthropic)

        #expect(blocks.map(\.tool_use_id) == ["toolu_1", "toolu_2"])
    }

    // MARK: - tool_use / tool_result pairing (Anthropic 400 backstop)

    /// An assistant `tool_use` whose `tool_result` was trimmed away (a
    /// non-tool message follows it mid-conversation) must be dropped, not
    /// forwarded as the orphan that trips "tool_use ids were found without
    /// tool_result blocks immediately after". The assistant carries text, so
    /// the turn survives as text-only.
    @Test func toAnthropicRequest_dropsOrphanToolUseKeepingAssistantText() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "do it"),
                ChatMessage(
                    role: "assistant",
                    content: "Let me check that file.",
                    tool_calls: [
                        ToolCall(
                            id: "toolu_orphan",
                            type: "function",
                            function: ToolCallFunction(name: "read_file", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                // The tool result was trimmed; a later user turn follows.
                ChatMessage(role: "user", content: "any progress?"),
            ]
        )

        let anthropic = request.toAnthropicRequest()

        #expect(!Self.toolUseBlocks(in: anthropic).contains { $0.id == "toolu_orphan" })
        Self.assertAnthropicToolPairing(anthropic)
    }

    /// An assistant whose ONLY content was an orphaned `tool_use` (no text)
    /// is removed entirely once the dangling call is dropped.
    @Test func toAnthropicRequest_dropsAssistantWhenOnlyOrphanToolUseRemains() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "toolu_orphan",
                            type: "function",
                            function: ToolCallFunction(name: "read_file", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "user", content: "still there?"),
            ]
        )

        let anthropic = request.toAnthropicRequest()

        #expect(Self.toolUseBlocks(in: anthropic).isEmpty)
        // Only the two user turns remain; no assistant message survives.
        #expect(!anthropic.messages.contains { $0.role == "assistant" })
        Self.assertAnthropicToolPairing(anthropic)
    }

    /// A `tool_result` with no preceding `tool_use` (its assistant turn was
    /// trimmed) is an orphan result and must be dropped.
    @Test func toAnthropicRequest_dropsOrphanToolResult() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(role: "tool", content: "STALE RESULT", tool_calls: nil, tool_call_id: "toolu_ghost"),
                ChatMessage(role: "user", content: "continue"),
            ]
        )

        let anthropic = request.toAnthropicRequest()

        #expect(!Self.toolResultBlocks(in: anthropic).contains { $0.tool_use_id == "toolu_ghost" })
        Self.assertAnthropicToolPairing(anthropic)
    }

    /// A `tool` turn with `nil` content must still emit a (non-empty)
    /// `tool_result` rather than being silently skipped, which would orphan
    /// its `tool_use`. Empty content rides as a single space (a truthful
    /// empty result), never fabricated output.
    @Test func toAnthropicRequest_emitsToolResultForNilContent() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "run it"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "toolu_1",
                            type: "function",
                            function: ToolCallFunction(name: "run", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: nil, tool_calls: nil, tool_call_id: "toolu_1"),
            ]
        )

        let anthropic = request.toAnthropicRequest()
        let blocks = Self.toolResultBlocks(in: anthropic)

        #expect(blocks.count == 1)
        #expect(blocks.first?.tool_use_id == "toolu_1")
        #expect(!(blocks.first?.content?.plainText.isEmpty ?? true))
        Self.assertAnthropicToolPairing(anthropic)
    }

    /// A trailing assistant tool-call turn (results not yet appended) is NOT
    /// a trimmed-away middle orphan and must be preserved verbatim.
    @Test func toAnthropicRequest_keepsTrailingAssistantToolUse() throws {
        let request = Self.makeRequest(
            model: "claude-3-5-sonnet-20241022",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "toolu_last",
                            type: "function",
                            function: ToolCallFunction(name: "run", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
            ]
        )

        let anthropic = request.toAnthropicRequest()

        #expect(Self.toolUseBlocks(in: anthropic).contains { $0.id == "toolu_last" })
    }

    @Test func routerWireCompatibleMessages_dropsOrphanToolUse() throws {
        let normalized = RemoteProviderService.routerWireCompatibleMessages([
            ChatMessage(role: "user", content: "go"),
            ChatMessage(
                role: "assistant",
                content: "Looking into it.",
                tool_calls: [
                    ToolCall(
                        id: "toolu_orphan",
                        type: "function",
                        function: ToolCallFunction(name: "read_file", arguments: "{}")
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "user", content: "next"),
        ])

        let hasOrphanCall = normalized.contains {
            $0.tool_calls?.contains { $0.id == "toolu_orphan" } ?? false
        }
        #expect(!hasOrphanCall)
        Self.assertChatMessageToolPairing(normalized)
    }

    @Test func routerWireCompatibleMessages_dropsOrphanToolResult() throws {
        let normalized = RemoteProviderService.routerWireCompatibleMessages([
            ChatMessage(role: "user", content: "go"),
            ChatMessage(role: "tool", content: "STALE", tool_calls: nil, tool_call_id: "toolu_ghost"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(id: "toolu_1", type: "function", function: ToolCallFunction(name: "run", arguments: "{}"))
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "tool", content: "FRESH", tool_calls: nil, tool_call_id: "toolu_1"),
        ])

        #expect(!normalized.contains { $0.role == "tool" && $0.tool_call_id == "toolu_ghost" })
        // The valid pair survives untouched.
        #expect(normalized.contains { $0.role == "tool" && $0.tool_call_id == "toolu_1" })
        Self.assertChatMessageToolPairing(normalized)
    }

    // MARK: - Empty/whitespace content (Anthropic non-whitespace rule)

    /// Empty/whitespace tool output must ride as a NON-WHITESPACE marker.
    /// Anthropic rejects content blocks that aren't non-whitespace text ("text
    /// content blocks must contain non-whitespace text"), so a lone `" "` would
    /// still 400. We send "(no output)" — truthful, never fabricated.
    @Test func toAnthropicRequest_emptyOrWhitespaceToolResultUsesNonWhitespaceMarker() throws {
        for emptyish in ["", "   ", "\n\t "] {
            let request = Self.makeRequest(
                model: "claude-opus-4-8",
                maxTokens: 1024,
                messages: [
                    ChatMessage(role: "user", content: "run it"),
                    ChatMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [
                            ToolCall(
                                id: "toolu_1",
                                type: "function",
                                function: ToolCallFunction(name: "run", arguments: "{}")
                            )
                        ],
                        tool_call_id: nil
                    ),
                    ChatMessage(role: "tool", content: emptyish, tool_calls: nil, tool_call_id: "toolu_1"),
                ]
            )

            let anthropic = request.toAnthropicRequest()
            let block = try #require(Self.toolResultBlocks(in: anthropic).first)
            let text = block.content?.plainText ?? ""
            #expect(
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "empty tool result must become non-whitespace text (was \(text.debugDescription))"
            )
            Self.assertAnthropicToolPairing(anthropic)
            Self.assertNoEmptyAnthropicContent(anthropic)
        }
    }

    /// A whitespace-only assistant turn whose only `tool_use` is orphaned must
    /// not emit a whitespace text block (Anthropic 400) — the turn is dropped.
    @Test func toAnthropicRequest_dropsWhitespaceOnlyAssistantWithOrphanToolUse() throws {
        let request = Self.makeRequest(
            model: "claude-opus-4-8",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(
                    role: "assistant",
                    content: "   ",
                    tool_calls: [
                        ToolCall(
                            id: "toolu_orphan",
                            type: "function",
                            function: ToolCallFunction(name: "run", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "user", content: "still there?"),
            ]
        )

        let anthropic = request.toAnthropicRequest()

        #expect(Self.toolUseBlocks(in: anthropic).isEmpty)
        #expect(!anthropic.messages.contains { $0.role == "assistant" })
        Self.assertAnthropicToolPairing(anthropic)
        Self.assertNoEmptyAnthropicContent(anthropic)
    }

    // MARK: - OpenAI Responses pairing backstop (call_id)

    /// An assistant `function_call` whose output was trimmed away (a non-tool
    /// message follows mid-history) must be dropped, not emitted as the orphan
    /// that 400s "No tool output found for function call".
    @Test func toOpenResponsesRequest_dropsOrphanToolUse() throws {
        let request = Self.makeRequest(
            model: "gpt-5.2",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(
                    role: "assistant",
                    content: "Looking.",
                    tool_calls: [
                        ToolCall(
                            id: "call_orphan",
                            type: "function",
                            function: ToolCallFunction(name: "read", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "user", content: "next"),
            ]
        )

        let responses = request.toOpenResponsesRequest(alwaysUseInputItems: true)

        #expect(!Self.functionCallIds(in: responses).contains("call_orphan"))
        Self.assertOpenResponsesToolPairing(responses)
    }

    /// A `function_call_output` with no preceding `function_call` (its assistant
    /// turn was trimmed) 400s "No tool call found for function call output" — it
    /// must be dropped.
    @Test func toOpenResponsesRequest_dropsOrphanToolResult() throws {
        let request = Self.makeRequest(
            model: "gpt-5.2",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "go"),
                ChatMessage(role: "tool", content: "STALE", tool_calls: nil, tool_call_id: "call_ghost"),
                ChatMessage(role: "user", content: "continue"),
            ]
        )

        let responses = request.toOpenResponsesRequest(alwaysUseInputItems: true)

        #expect(!Self.functionCallOutputIds(in: responses).contains("call_ghost"))
        Self.assertOpenResponsesToolPairing(responses)
    }

    /// A nil-content tool result must still emit a `function_call_output` with a
    /// non-empty `output` — skipping it (the old behavior) would re-orphan its
    /// `function_call`. Empty rides as a truthful "(no output)" marker.
    @Test func toOpenResponsesRequest_emitsFunctionCallOutputForNilContent() throws {
        let request = Self.makeRequest(
            model: "gpt-5.2",
            maxTokens: 1024,
            messages: [
                ChatMessage(role: "user", content: "run"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call_1",
                            type: "function",
                            function: ToolCallFunction(name: "run", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(role: "tool", content: nil, tool_calls: nil, tool_call_id: "call_1"),
                ChatMessage(role: "user", content: "done?"),
            ]
        )

        let responses = request.toOpenResponsesRequest(alwaysUseInputItems: true)
        guard case .items(let items) = responses.input else {
            Issue.record("expected items input")
            return
        }
        let output = items.compactMap { item -> String? in
            if case .functionCallOutput(let o) = item, o.call_id == "call_1" { return o.output }
            return nil
        }.first
        let outputText = try #require(output, "no function_call_output emitted for nil-content tool")
        #expect(!outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Self.assertOpenResponsesToolPairing(responses)
    }

    // MARK: - OpenAI-compat wire pairing backstop

    /// The plain OpenAI-compat dispatch (`.openaiLegacy`/`.azureOpenAI`/
    /// `.osaurus`) must drop an orphaned `tool_use` so the upstream never sees
    /// "an assistant message with tool_calls must be followed by tool messages".
    @Test func openAICompatWireBody_dropsOrphanToolUse() throws {
        let messages = [
            ChatMessage(role: "user", content: "go"),
            ChatMessage(
                role: "assistant",
                content: "Looking.",
                tool_calls: [
                    ToolCall(
                        id: "call_orphan",
                        type: "function",
                        function: ToolCallFunction(name: "read", arguments: "{}")
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "user", content: "next"),
        ]

        let body = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-4.1",
            assistantReasoning: "x",
            messages: messages
        )

        #expect(!body.contains("call_orphan"))
        let payload = try Self.decodeAsDictionary(Data(body.utf8))
        let wireMessages = try #require(payload["messages"] as? [[String: Any]])
        Self.assertWireMessagesToolPairing(wireMessages)
    }

    // MARK: - Gemini thought_signature preservation

    /// Gemini 3 enforces a `thought_signature` on a surviving `functionCall`
    /// part of the current turn (omitting it 400s). The pairing backstop FILTERS
    /// calls (it keeps the original `ToolCall`), so a kept call's signature must
    /// ride through encode unchanged. This guards a future refactor that rebuilds
    /// `ToolCall`s and silently drops the signature.
    @Test func toGeminiRequest_preservesThoughtSignatureForSurvivingCall() throws {
        let messages = [
            ChatMessage(role: "user", content: "weather?"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(name: "get_weather", arguments: "{}"),
                        geminiThoughtSignature: "SIG_ABC123"
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "tool", content: "sunny", tool_calls: nil, tool_call_id: "call_1"),
            // An orphaned call afterwards forces the pairing pass to filter.
            ChatMessage(
                role: "assistant",
                content: "Checking again.",
                tool_calls: [
                    ToolCall(
                        id: "call_orphan",
                        type: "function",
                        function: ToolCallFunction(name: "noop", arguments: "{}")
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "user", content: "and tomorrow?"),
        ]
        let request = Self.makeRequest(model: "gemini-2.5-pro", maxTokens: 1024, messages: messages)
        let gemini = request.toGeminiRequest()

        #expect(Self.functionCallSignature(in: gemini, name: "get_weather") == "SIG_ABC123")
        #expect(Self.functionCallSignature(in: gemini, name: "noop") == nil)
        Self.assertGeminiToolPairing(gemini)
    }

    // MARK: - Full pipeline: trim → encode (no orphans, no empty/whitespace)

    /// The canonical failure mode: a full context window trims history, and the
    /// trimmed transcript is then encoded. Each provider path must come out with
    /// the tool-pairing invariant intact and no empty/whitespace content blocks.
    @Test func trimThenEncode_anthropic_noOrphansNoEmptyBlocks() throws {
        let trimmed = Self.tinyTrimmed(Self.makeToolLoopHistory(units: 14))
        let anthropic = Self.makeRequest(
            model: "claude-opus-4-8",
            maxTokens: 1024,
            messages: trimmed
        ).toAnthropicRequest()

        #expect(!Self.toolResultBlocks(in: anthropic).isEmpty, "trim should still leave tool units to encode")
        Self.assertAnthropicToolPairing(anthropic)
        Self.assertNoEmptyAnthropicContent(anthropic)
    }

    @Test func trimThenEncode_openResponses_noOrphans() throws {
        let trimmed = Self.tinyTrimmed(Self.makeToolLoopHistory(units: 14))
        let responses = Self.makeRequest(
            model: "gpt-5.2",
            maxTokens: 1024,
            messages: trimmed
        ).toOpenResponsesRequest(alwaysUseInputItems: true)

        #expect(!Self.functionCallIds(in: responses).isEmpty, "trim should still leave function_calls to encode")
        Self.assertOpenResponsesToolPairing(responses)
    }

    @Test func trimThenEncode_gemini_noOrphans() throws {
        let trimmed = Self.tinyTrimmed(Self.makeToolLoopHistory(units: 14))
        let gemini = Self.makeRequest(
            model: "gemini-2.5-pro",
            maxTokens: 1024,
            messages: trimmed
        ).toGeminiRequest()

        Self.assertGeminiToolPairing(gemini)
    }

    @Test func trimThenEncode_openAICompat_noOrphans() throws {
        let trimmed = Self.tinyTrimmed(Self.makeToolLoopHistory(units: 14))
        let body = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-4.1",
            assistantReasoning: "x",
            messages: trimmed
        )
        let payload = try Self.decodeAsDictionary(Data(body.utf8))
        let wireMessages = try #require(payload["messages"] as? [[String: Any]])
        Self.assertWireMessagesToolPairing(wireMessages)
    }

    @Test func echoesReasoningContent_trueForDeepSeekHost() throws {
        #expect(
            RemoteProviderService.echoesReasoningContent(
                providerType: .openaiLegacy,
                host: "api.deepseek.com",
                model: "deepseek-chat"
            ) == true
        )
    }

    /// Local ds4 servers run on `localhost`, so the host alone can't tell
    /// us they're DeepSeek-family; we have to look at the model id too.
    @Test func echoesReasoningContent_trueForLocalHostWithDeepSeekModel() throws {
        let cases: [(host: String, model: String)] = [
            ("localhost:8888", "deepseek-v4-flash"),
            ("127.0.0.1:9000", "deepseek-r1"),
            ("ds4.local", "DeepSeek-V3"),
        ]
        for c in cases {
            #expect(
                RemoteProviderService.echoesReasoningContent(
                    providerType: .openaiLegacy,
                    host: c.host,
                    model: c.model
                ) == true,
                "expected reasoning_content echo for host=\(c.host) model=\(c.model)"
            )
        }
    }

    @Test func echoesReasoningContent_falseForOtherOpenAICompatHosts() throws {
        for host in ["api.x.ai", "api.venice.ai", "openrouter.ai", "api.openai.com", "api.together.xyz"] {
            #expect(
                RemoteProviderService.echoesReasoningContent(
                    providerType: .openaiLegacy,
                    host: host,
                    model: "gpt-4o-mini"
                ) == false
            )
        }
    }

    @Test func echoesReasoningContent_falseForNonOpenAICompatProviders() throws {
        for providerType: RemoteProviderType in [.anthropic, .openResponses, .openAICodex, .gemini, .osaurus] {
            #expect(
                RemoteProviderService.echoesReasoningContent(
                    providerType: providerType,
                    host: "api.deepseek.com",
                    model: "deepseek-chat"
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

    /// End-to-end: a follow-up turn against a local ds4 server must keep
    /// `reasoning_content` on the wire so ds4's prompt template renders the
    /// same `<think>…</think>` block that produced its cached KV state.
    @Test func wireBody_includesReasoningContent_forLocalDS4() throws {
        let body = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "localhost:8888",
            model: "deepseek-v4-flash",
            assistantReasoning: "The user wants weather; call get_weather."
        )

        #expect(body.contains("\"reasoning_content\""))
        #expect(body.contains("The user wants weather"))
    }

    /// Symmetric guard: non-DeepSeek host+model still strips
    /// `reasoning_content` to avoid unknown-field rejections on strict schemas.
    @Test func wireBody_omitsReasoningContent_forNonDeepSeekRemote() throws {
        let body = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-5",
            assistantReasoning: "internal trace"
        )

        #expect(!body.contains("\"reasoning_content\""))
        #expect(!body.contains("internal trace"))
    }

    @Test func wireBody_routerExplicitlyRejectsClampToBalance() throws {
        let routerBody = try Self.encodedWireBody(
            providerType: .osaurusRouter,
            host: "router.osaurus.ai",
            model: "venice/minimax-m3",
            assistantReasoning: "hidden trace"
        )
        let openAICompatBody = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-5",
            assistantReasoning: "hidden trace"
        )

        #expect(routerBody.contains("\"clamp_to_balance\":false"))
        #expect(!openAICompatBody.contains("\"clamp_to_balance\""))
    }

    // MARK: - prompt_cache_key (session-scoped OpenAI prompt-cache routing)

    @Test func supportsPromptCacheKey_onlyForGenuineOpenAIHosts() throws {
        #expect(
            RemoteProviderService.supportsPromptCacheKey(
                providerType: .openaiLegacy,
                host: "api.openai.com"
            )
        )
        #expect(
            RemoteProviderService.supportsPromptCacheKey(
                providerType: .openaiLegacy,
                host: "eu.api.openai.com"
            )
        )
        // Third-party OpenAI-compat schemas can be strict about unknown
        // fields — same rationale as router-only `idempotency_key`.
        #expect(
            !RemoteProviderService.supportsPromptCacheKey(
                providerType: .openaiLegacy,
                host: "api.x.ai"
            )
        )
        #expect(
            !RemoteProviderService.supportsPromptCacheKey(
                providerType: .osaurusRouter,
                host: "router.osaurus.ai"
            )
        )
        #expect(
            !RemoteProviderService.supportsPromptCacheKey(
                providerType: .anthropic,
                host: "api.anthropic.com"
            )
        )
    }

    @Test func wireBody_carriesPromptCacheKeyOnlyWhenSet() throws {
        var request = Self.makeRequest(model: "gpt-5.2", maxTokens: 128)
        let bare = try JSONEncoder.osaurusCanonical().encode(request)
        #expect(!String(decoding: bare, as: UTF8.self).contains("prompt_cache_key"))

        request.promptCacheKey = "osaurus-session-ABC"
        let payload = try Self.decodeAsDictionary(
            try JSONEncoder.osaurusCanonical().encode(request)
        )
        #expect(payload["prompt_cache_key"] as? String == "osaurus-session-ABC")
    }

    @Test func buildChatRequest_setsSessionScopedPromptCacheKeyForOpenAIOnly() async throws {
        func service(host: String, providerType: RemoteProviderType) -> RemoteProviderService {
            RemoteProviderService(
                provider: RemoteProvider(
                    name: "p",
                    host: host,
                    providerProtocol: .https,
                    port: nil,
                    basePath: "/v1",
                    authType: .none,
                    providerType: providerType
                ),
                models: ["gpt-5.2"],
                resolvedHeaders: [:]
            )
        }
        let params = GenerationParameters(
            temperature: 0.7,
            maxTokens: 256,
            sessionId: "SESSION-1"
        )

        let openAIReq = await service(host: "api.openai.com", providerType: .openaiLegacy)
            .buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: params,
                model: "gpt-5.2",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
        #expect(openAIReq.promptCacheKey == "osaurus-session-SESSION-1")

        let compatReq = await service(host: "api.x.ai", providerType: .openaiLegacy)
            .buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: params,
                model: "grok-4",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
        #expect(compatReq.promptCacheKey == nil)

        // No session id → no key, even on the genuine OpenAI host.
        let noSessionReq = await service(host: "api.openai.com", providerType: .openaiLegacy)
            .buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: GenerationParameters(temperature: 0.7, maxTokens: 256),
                model: "gpt-5.2",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
        #expect(noSessionReq.promptCacheKey == nil)
    }

    @Test func wireBody_routerMatchesVeniceToolRequest_exceptRouterOnlyFields() throws {
        let priorCall = ToolCall(
            id: "call_write_1",
            type: "function",
            function: ToolCallFunction(
                name: "sandbox_write_file",
                arguments: #"{"path":"tetris.html","content":"<html></html>"}"#
            )
        )
        let messages = [
            ChatMessage(role: "user", content: "build me a game of tetris"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [priorCall],
                tool_call_id: nil
            ),
            ChatMessage(
                role: "tool",
                content: #"{"ok":true,"path":"tetris.html"}"#,
                tool_calls: nil,
                tool_call_id: "call_write_1"
            ),
        ]

        let veniceBody = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.venice.ai",
            model: "minimax-m3",
            assistantReasoning: "hidden trace",
            tools: [Self.topLevelAnyOfTool],
            messages: messages,
            toolChoice: .auto
        )
        let routerBody = try Self.encodedWireBody(
            providerType: .osaurusRouter,
            host: "router.osaurus.ai",
            model: "venice/minimax-m3",
            assistantReasoning: "hidden trace",
            tools: [Self.topLevelAnyOfTool],
            messages: messages,
            toolChoice: .auto,
            idempotencyKey: "run-abc:1"
        )

        let venice = try Self.decodeAsDictionary(Data(veniceBody.utf8))
        let router = try Self.decodeAsDictionary(Data(routerBody.utf8))

        #expect(venice["tool_choice"] as? String == "auto")
        #expect(router["tool_choice"] as? String == "auto")
        #expect(venice["clamp_to_balance"] == nil)
        #expect(router["clamp_to_balance"] as? Bool == false)
        #expect(venice["idempotency_key"] == nil)
        #expect(router["idempotency_key"] as? String == "run-abc:1")

        let veniceMessages = try #require(venice["messages"] as? [[String: Any]])
        let routerMessages = try #require(router["messages"] as? [[String: Any]])
        #expect(veniceMessages[1]["content"] == nil)
        #expect(routerMessages[1]["content"] as? String == "")
        #expect(veniceMessages[1]["tool_calls"] != nil)
        #expect(routerMessages[1]["tool_calls"] != nil)

        let veniceTools = try #require(venice["tools"] as? [[String: Any]])
        let routerTools = try #require(router["tools"] as? [[String: Any]])
        let veniceFunction = try #require(veniceTools.first?["function"] as? [String: Any])
        let routerFunction = try #require(routerTools.first?["function"] as? [String: Any])
        #expect(veniceFunction["name"] as? String == "share_artifact")
        #expect(routerFunction["name"] as? String == "share_artifact")

        let veniceParams = try #require(veniceFunction["parameters"] as? [String: Any])
        let routerParams = try #require(routerFunction["parameters"] as? [String: Any])
        #expect(veniceParams["anyOf"] != nil)
        #expect(routerParams["anyOf"] == nil)
    }

    /// Mirrors the strip-or-echo branch in `buildURLRequest`, then encodes
    /// with the canonical encoder. Returns the wire body as a string.
    private static func encodedWireBody(
        providerType: RemoteProviderType,
        host: String,
        model: String,
        assistantReasoning: String,
        tools: [Tool]? = nil,
        messages: [ChatMessage]? = nil,
        toolChoice: ToolChoiceOption? = nil,
        idempotencyKey: String? = nil
    ) throws -> String {
        let wireTools: [Tool]?
        if let tools,
            RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: providerType,
                host: host
            )
        {
            wireTools = tools.map(RemoteProviderService.strippingRestrictedTopLevelSchemaKeys)
        } else {
            wireTools = tools
        }

        let request = RemoteChatRequest(
            model: model,
            messages: messages ?? [
                ChatMessage(role: "user", content: "hi"),
                ChatMessage(
                    role: "assistant",
                    content: "answer",
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: assistantReasoning
                ),
            ],
            temperature: nil,
            max_completion_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: wireTools,
            tool_choice: toolChoice,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )

        var outbound = request
        outbound.idempotencyKey = idempotencyKey
        if !RemoteProviderService.echoesReasoningContent(
            providerType: providerType,
            host: host,
            model: model
        ) {
            outbound.messages = RemoteProviderService.strippingReasoningContent(from: outbound.messages)
        }
        if providerType == .osaurusRouter {
            outbound.messages = RemoteProviderService.routerWireCompatibleMessages(outbound.messages)
            outbound.clamp_to_balance = false
        } else {
            // Mirror buildURLRequest: plain OpenAI-compat upstreams run the
            // dedupe + pairing backstop so a trimmed half-pair can't 400.
            outbound.messages = RemoteProviderService.enforcingToolUseResultPairing(
                RemoteProviderService.mergingDuplicateToolResults(outbound.messages),
                provider: String(describing: providerType)
            )
        }
        let data = try JSONEncoder.osaurusCanonical().encode(outbound)
        return String(decoding: data, as: UTF8.self)
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

    @Test func geminiRequest_stripsAdditionalPropertiesFromToolSchemas() throws {
        let request = Self.makeRequest(
            model: "gemini-2.5-pro",
            maxTokens: 1024,
            tools: [Self.strictNestedTool]
        )
        let payload = try Self.encodeAsDictionary(request.toGeminiRequest())
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let functionDeclarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        let parameters = try #require(functionDeclarations.first?["parameters"] as? [String: Any])

        #expect(parameters["additionalProperties"] == nil)
        let properties = try #require(parameters["properties"] as? [String: Any])
        let location = try #require(properties["location"] as? [String: Any])
        #expect(location["additionalProperties"] == nil)

        let locationProperties = try #require(location["properties"] as? [String: Any])
        let city = try #require(locationProperties["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")

        let tags = try #require(properties["tags"] as? [String: Any])
        let items = try #require(tags["items"] as? [String: Any])
        #expect(items["additionalProperties"] == nil)

        let itemProperties = try #require(items["properties"] as? [String: Any])
        #expect(itemProperties["name"] != nil)
    }

    @Test func openAIRequest_preservesAdditionalPropertiesInToolSchemas() throws {
        let request = Self.makeRequest(
            model: "gpt-4.1",
            maxTokens: 1024,
            tools: [Self.strictNestedTool]
        )
        let payload = try Self.encodeAsDictionary(request)
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])

        #expect(parameters["additionalProperties"] as? Bool == false)
        let properties = try #require(parameters["properties"] as? [String: Any])
        let location = try #require(properties["location"] as? [String: Any])
        #expect(location["additionalProperties"] as? Bool == false)
    }

    // MARK: - Gemini schema sanitization regression tests
    //
    // Each case pins one of the MCP-driven incompatibilities Gemini's OpenAPI 3.0
    // validator rejects with HTTP 400 `INVALID_ARGUMENT`.

    @Test func geminiRequest_dropsRequiredEntriesNotDeclaredInProperties() throws {
        // Reproduces the exact 400 in the bug report:
        //   `function_declarations[i].parameters.required[j]: property is not defined`
        let tool = Self.makeTool(
            name: "broken_required",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "foo": .object(["type": .string("string")])
                ]),
                "required": .array([.string("foo"), .string("bar")]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)

        let required = try #require(parameters["required"] as? [String])
        #expect(required == ["foo"])
    }

    @Test func geminiRequest_omitsRequiredWhenAllEntriesUndefined() throws {
        let tool = Self.makeTool(
            name: "all_required_undefined",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "foo": .object(["type": .string("string")])
                ]),
                "required": .array([.string("bar"), .string("baz")]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)

        #expect(parameters["required"] == nil)
    }

    @Test func geminiRequest_stripsPropertiesAndRequiredOnNonObjectTypes() throws {
        // Notion-style MCP schemas attach `properties`/`required` to string
        // fields. Gemini rejects them: "only allowed for OBJECT type".
        let tool = Self.makeTool(
            name: "non_object_with_object_shape",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "properties": .object([
                            "nested": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("nested")]),
                    ])
                ]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)

        let properties = try #require(parameters["properties"] as? [String: Any])
        let name = try #require(properties["name"] as? [String: Any])

        #expect(name["type"] as? String == "string")
        #expect(name["properties"] == nil)
        #expect(name["required"] == nil)
    }

    @Test func geminiRequest_infersObjectTypeWhenPropertiesPresentWithoutType() throws {
        // Schema fragment with `properties` but no `type` — implicit object
        // per JSON Schema, rejected by Gemini until inferred.
        let tool = Self.makeTool(
            name: "implicit_object",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "data": .object([
                        "properties": .object([
                            "page_id": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("page_id"), .string("ghost")]),
                    ])
                ]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)
        let properties = try #require(parameters["properties"] as? [String: Any])
        let data = try #require(properties["data"] as? [String: Any])

        #expect(data["type"] as? String == "object")
        let required = try #require(data["required"] as? [String])
        #expect(required == ["page_id"])
    }

    @Test func geminiRequest_stripsContentEncodingAndContentMediaType() throws {
        // chrome-devtools-mcp-style screenshot tool — Gemini rejects these.
        let tool = Self.makeTool(
            name: "take_screenshot",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "image": .object([
                        "type": .string("string"),
                        "contentEncoding": .string("base64"),
                        "contentMediaType": .string("image/png"),
                    ])
                ]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)
        let properties = try #require(parameters["properties"] as? [String: Any])
        let image = try #require(properties["image"] as? [String: Any])

        #expect(image["contentEncoding"] == nil)
        #expect(image["contentMediaType"] == nil)
        #expect(image["type"] as? String == "string")
    }

    @Test func geminiRequest_stripsRefAndDefsAndConst() throws {
        let tool = Self.makeTool(
            name: "ref_and_const",
            parameters: .object([
                "type": .string("object"),
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "$id": .string("urn:example:schema"),
                "$defs": .object([
                    "Foo": .object(["type": .string("string")])
                ]),
                "definitions": .object([
                    "Bar": .object(["type": .string("number")])
                ]),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "const": .string("widget"),
                    ]),
                    "ref_field": .object([
                        "$ref": .string("#/$defs/Foo")
                    ]),
                    "either": .object([
                        "oneOf": .array([
                            .object(["type": .string("string")]),
                            .object(["type": .string("number")]),
                        ])
                    ]),
                ]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)

        #expect(parameters["$schema"] == nil)
        #expect(parameters["$id"] == nil)
        #expect(parameters["$defs"] == nil)
        #expect(parameters["definitions"] == nil)

        let properties = try #require(parameters["properties"] as? [String: Any])

        let kind = try #require(properties["kind"] as? [String: Any])
        #expect(kind["const"] == nil)
        #expect(kind["type"] as? String == "string")

        let refField = try #require(properties["ref_field"] as? [String: Any])
        #expect(refField["$ref"] == nil)

        let either = try #require(properties["either"] as? [String: Any])
        #expect(either["oneOf"] == nil)
    }

    @Test func geminiRequest_normalizesArrayNullableTypeUnion() throws {
        let tool = Self.makeTool(
            name: "nullable_union",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "label": .object([
                        "type": .array([.string("string"), .string("null")])
                    ])
                ]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)
        let properties = try #require(parameters["properties"] as? [String: Any])
        let label = try #require(properties["label"] as? [String: Any])

        #expect(label["type"] as? String == "string")
        #expect(label["nullable"] as? Bool == true)
    }

    @Test func geminiRequest_preservesAllowedKeywords() throws {
        let tool = Self.makeTool(
            name: "rich_schema",
            parameters: .object([
                "type": .string("object"),
                "description": .string("A rich schema"),
                "propertyOrdering": .array([.string("count"), .string("tags")]),
                "properties": .object([
                    "count": .object([
                        "type": .string("integer"),
                        "format": .string("int32"),
                        "minimum": .number(0),
                        "maximum": .number(100),
                        "nullable": .bool(true),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "minItems": .number(1),
                        "maxItems": .number(5),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([.string("a"), .string("b")]),
                        ]),
                    ]),
                    "either": .object([
                        "anyOf": .array([
                            .object(["type": .string("string")]),
                            .object(["type": .string("number")]),
                        ])
                    ]),
                ]),
                "required": .array([.string("count")]),
            ])
        )
        let parameters = try Self.geminiParameters(for: tool)

        #expect(parameters["description"] as? String == "A rich schema")
        let ordering = try #require(parameters["propertyOrdering"] as? [String])
        #expect(ordering == ["count", "tags"])
        let required = try #require(parameters["required"] as? [String])
        #expect(required == ["count"])

        let properties = try #require(parameters["properties"] as? [String: Any])

        let count = try #require(properties["count"] as? [String: Any])
        #expect(count["type"] as? String == "integer")
        #expect(count["format"] as? String == "int32")
        #expect((count["minimum"] as? NSNumber)?.doubleValue == 0)
        #expect((count["maximum"] as? NSNumber)?.doubleValue == 100)
        #expect(count["nullable"] as? Bool == true)

        let tags = try #require(properties["tags"] as? [String: Any])
        #expect(tags["type"] as? String == "array")
        #expect((tags["minItems"] as? NSNumber)?.doubleValue == 1)
        #expect((tags["maxItems"] as? NSNumber)?.doubleValue == 5)
        let items = try #require(tags["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
        let enumValues = try #require(items["enum"] as? [String])
        #expect(enumValues == ["a", "b"])

        let either = try #require(properties["either"] as? [String: Any])
        let anyOf = try #require(either["anyOf"] as? [[String: Any]])
        #expect(anyOf.count == 2)
    }

    // MARK: - OpenAI top-level parameter schema sanitization

    /// OpenAI 400s on `oneOf`/`anyOf`/`allOf`/`enum`/`const`/`not` at the top
    /// level of a function's `parameters` (observed live with `share_artifact`,
    /// whose schema carries a top-level `anyOf` for path-OR-content). The
    /// sanitizer must strip exactly the top-level offenders and nothing nested.
    @Test func openAISanitizer_stripsTopLevelAnyOfOnly() throws {
        let sanitized = RemoteProviderService.strippingRestrictedTopLevelSchemaKeys(Self.topLevelAnyOfTool)
        guard case .object(let params)? = sanitized.function.parameters else {
            Issue.record("parameters lost")
            return
        }
        #expect(params["anyOf"] == nil)
        #expect(params["type"] == .string("object"))
        guard case .object(let properties)? = params["properties"],
            case .object(let mode)? = properties["mode"]
        else {
            Issue.record("properties lost")
            return
        }
        #expect(mode["anyOf"] != nil, "nested anyOf must survive")
    }

    @Test func routerWireBody_stripsTopLevelToolCombinatorsOnly() throws {
        let body = try Self.encodedWireBody(
            providerType: .osaurusRouter,
            host: "router.osaurus.ai",
            model: "claude-opus-4-8",
            assistantReasoning: "hidden trace",
            tools: [Self.topLevelAnyOfTool]
        )
        let payload = try Self.decodeAsDictionary(Data(body.utf8))
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])

        #expect(params["anyOf"] == nil, "router wire schema must drop top-level anyOf")
        #expect(params["type"] as? String == "object")
        let properties = try #require(params["properties"] as? [String: Any])
        let mode = try #require(properties["mode"] as? [String: Any])
        #expect(mode["anyOf"] != nil, "nested anyOf must survive for provider-side guidance")
    }

    @Test func nonStrictOpenAICompatWireBody_keepsTopLevelToolCombinators() throws {
        let body = try Self.encodedWireBody(
            providerType: .openaiLegacy,
            host: "api.x.ai",
            model: "grok-4",
            assistantReasoning: "hidden trace",
            tools: [Self.topLevelAnyOfTool]
        )
        let payload = try Self.decodeAsDictionary(Data(body.utf8))
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])

        #expect(params["anyOf"] != nil)
    }

    @Test func openAISanitizer_passThroughWhenClean() throws {
        let sanitized = RemoteProviderService.strippingRestrictedTopLevelSchemaKeys(Self.weatherTool)
        #expect(sanitized.function.parameters == Self.weatherTool.function.parameters)
    }

    @Test func openAISanitizer_gateMatchesOnlyEnforcingProviders() {
        #expect(
            RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: .openaiLegacy,
                host: "api.openai.com"
            )
        )
        #expect(
            RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: .azureOpenAI,
                host: "myorg.example.azure.com"
            )
        )
        #expect(
            RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: .osaurusRouter,
                host: "router.osaurus.ai"
            )
        )
        #expect(
            !RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: .openaiLegacy,
                host: "api.x.ai"
            )
        )
        // Anthropic 400s on top-level oneOf/allOf/anyOf in input_schema
        // (observed live: "input_schema does not support oneOf, allOf, or
        // anyOf at the top level").
        #expect(
            RemoteProviderService.enforcesTopLevelParameterSchemaRestrictions(
                providerType: .anthropic,
                host: "api.anthropic.com"
            )
        )
    }

    // MARK: - Fixtures

    private static func makeRequest(
        model: String,
        maxTokens: Int?,
        reasoningEffort: String? = nil,
        tools: [Tool]? = nil,
        thinking: ThinkingConfig? = nil,
        messages: [ChatMessage] = [ChatMessage(role: "user", content: "hi")]
    ) -> RemoteChatRequest {
        RemoteChatRequest(
            model: model,
            messages: messages,
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

    /// Single-tool fixture for the Gemini sanitizer regression tests.
    private static func makeTool(name: String, parameters: JSONValue) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: name,
                description: "Test tool",
                parameters: parameters
            )
        )
    }

    /// Encode through `toGeminiRequest()` and return the wire-format `parameters`
    /// dict for the first function declaration.
    private static func geminiParameters(for tool: Tool) throws -> [String: Any] {
        let request = makeRequest(model: "gemini-2.5-pro", maxTokens: 1024, tools: [tool])
        let payload = try encodeAsDictionary(request.toGeminiRequest())
        let tools = try #require(payload["tools"] as? [[String: Any]])
        let functionDeclarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        return try #require(functionDeclarations.first?["parameters"] as? [String: Any])
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

    private static let topLevelAnyOfTool = makeTool(
        name: "share_artifact",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "mode": .object([
                    "anyOf": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("number")]),
                    ])
                ]),
            ]),
            "anyOf": .array([
                .object(["required": .array([.string("path")])])
            ]),
        ])
    )

    private static let strictNestedTool = Tool(
        type: "function",
        function: ToolFunction(
            name: "plan_site",
            description: "Plan a site",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("location")]),
                "properties": .object([
                    "location": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "properties": .object([
                            "city": .object([
                                "type": .string("string"),
                                "description": .string("City name"),
                            ])
                        ]),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .object([
                                "name": .object([
                                    "type": .string("string")
                                ])
                            ]),
                        ]),
                    ]),
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

    private static func encodeAsDictionary(_ request: GeminiGenerateContentRequest) throws -> [String: Any] {
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

    private static func encodeAsArray(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(messages)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    /// Flatten every `tool_result` block across an Anthropic request, in order,
    /// for single-result-per-id assertions.
    private static func toolResultBlocks(
        in request: AnthropicMessagesRequest
    ) -> [AnthropicToolResultBlock] {
        request.messages.flatMap { message -> [AnthropicToolResultBlock] in
            guard case .blocks(let blocks) = message.content else { return [] }
            return blocks.compactMap { block in
                if case .toolResult(let result) = block { return result }
                return nil
            }
        }
    }

    /// Flatten every `tool_use` block across an Anthropic request, in order.
    private static func toolUseBlocks(
        in request: AnthropicMessagesRequest
    ) -> [AnthropicToolUseBlock] {
        request.messages.flatMap { message -> [AnthropicToolUseBlock] in
            guard case .blocks(let blocks) = message.content else { return [] }
            return blocks.compactMap { block in
                if case .toolUse(let use) = block { return use }
                return nil
            }
        }
    }

    /// Assert the Anthropic invariant the 400 enforces: every `tool_use` id is
    /// answered by a `tool_result` in the IMMEDIATELY following message, and
    /// every `tool_result` is produced by the immediately preceding message's
    /// `tool_use` (no orphan result).
    private static func assertAnthropicToolPairing(_ request: AnthropicMessagesRequest) {
        func useIds(_ message: AnthropicMessage?) -> Set<String> {
            guard let message, case .blocks(let blocks) = message.content else { return [] }
            return Set(
                blocks.compactMap { block in
                    if case .toolUse(let use) = block { return use.id }
                    return nil
                }
            )
        }
        func resultIds(_ message: AnthropicMessage?) -> Set<String> {
            guard let message, case .blocks(let blocks) = message.content else { return [] }
            return Set(
                blocks.compactMap { block in
                    if case .toolResult(let result) = block { return result.tool_use_id }
                    return nil
                }
            )
        }

        let messages = request.messages
        for (index, message) in messages.enumerated() {
            let uses = useIds(message)
            if !uses.isEmpty {
                let next = index + 1 < messages.count ? messages[index + 1] : nil
                #expect(uses.isSubset(of: resultIds(next)))
            }
            let results = resultIds(message)
            if !results.isEmpty {
                let prev = index > 0 ? messages[index - 1] : nil
                #expect(results.isSubset(of: useIds(prev)))
            }
        }
    }

    /// Forward-scan the OpenAI-style `ChatMessage` array (router output) for
    /// the same invariant: an assistant turn's requested ids are all answered
    /// by the contiguous following `tool` run, and no `tool` result appears
    /// without a requesting assistant turn.
    private static func assertChatMessageToolPairing(_ messages: [ChatMessage]) {
        var pendingCallIds = Set<String>()
        for message in messages {
            switch message.role.lowercased() {
            case "assistant":
                #expect(pendingCallIds.isEmpty)
                pendingCallIds = Set(message.tool_calls?.map(\.id) ?? [])
            case "tool":
                let id = message.tool_call_id ?? ""
                #expect(pendingCallIds.contains(id))
                pendingCallIds.remove(id)
            default:
                #expect(pendingCallIds.isEmpty)
            }
        }
        #expect(pendingCallIds.isEmpty)
    }

    /// A long, VALID tool-loop history (protected first task, `units`
    /// assistant(tool_call)+tool pairs, recent tail) that overflows a tiny
    /// budget — the shape that produced the reported `messages.78` 400.
    private static func makeToolLoopHistory(units: Int) -> [ChatMessage] {
        var msgs: [ChatMessage] = [ChatMessage(role: "user", content: "Original task: ship the feature.")]
        for i in 0 ..< units {
            let callId = "call_\(i)"
            msgs.append(
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(name: "read_file", arguments: #"{"path":"f"}"#)
                        )
                    ],
                    tool_call_id: nil
                )
            )
            msgs.append(
                ChatMessage(
                    role: "tool",
                    content: String(repeating: "data ", count: 80),
                    tool_calls: nil,
                    tool_call_id: callId
                )
            )
        }
        msgs.append(ChatMessage(role: "user", content: "What's the status now?"))
        return msgs
    }

    /// Trim through the real `ContextBudgetManager` at a budget far below the
    /// history size, forcing the atomic-unit drop path.
    private static func tinyTrimmed(_ messages: [ChatMessage]) -> [ChatMessage] {
        ContextBudgetManager(contextLength: 600).trimMessages(messages, recentPairsToKeep: 2)
    }

    private static func functionCallIds(in request: OpenResponsesRequest) -> Set<String> {
        guard case .items(let items) = request.input else { return [] }
        return Set(
            items.compactMap { item in
                if case .functionCall(let call) = item { return call.call_id }
                return nil
            }
        )
    }

    private static func functionCallOutputIds(in request: OpenResponsesRequest) -> Set<String> {
        guard case .items(let items) = request.input else { return [] }
        return Set(
            items.compactMap { item in
                if case .functionCallOutput(let output) = item { return output.call_id }
                return nil
            }
        )
    }

    /// The part-level `thoughtSignature` carried by the named `functionCall`,
    /// or nil if that call isn't present.
    private static func functionCallSignature(
        in request: GeminiGenerateContentRequest,
        name: String
    ) -> String? {
        for content in request.contents {
            for part in content.parts {
                if case .functionCall(let call) = part.content, call.name == name {
                    return part.thoughtSignature
                }
            }
        }
        return nil
    }

    /// Responses pairs by `call_id`: every `function_call_output` must follow a
    /// `function_call`, and the call/output id sets must match (no orphans).
    private static func assertOpenResponsesToolPairing(_ request: OpenResponsesRequest) {
        guard case .items(let items) = request.input else { return }
        var seenCalls = Set<String>()
        var callIds = Set<String>()
        var outputIds = Set<String>()
        for item in items {
            switch item {
            case .functionCall(let call):
                callIds.insert(call.call_id)
                seenCalls.insert(call.call_id)
            case .functionCallOutput(let output):
                outputIds.insert(output.call_id)
                #expect(
                    seenCalls.contains(output.call_id),
                    "function_call_output \(output.call_id) has no preceding function_call"
                )
            default:
                break
            }
        }
        #expect(callIds == outputIds)
    }

    /// Forward-scan decoded wire `messages` (OpenAI-compat) for the same
    /// invariant `assertChatMessageToolPairing` checks, on raw JSON dicts.
    private static func assertWireMessagesToolPairing(_ messages: [[String: Any]]) {
        var pending = Set<String>()
        for message in messages {
            switch (message["role"] as? String)?.lowercased() ?? "" {
            case "assistant":
                #expect(pending.isEmpty)
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                pending = Set(calls.compactMap { $0["id"] as? String })
            case "tool":
                let id = message["tool_call_id"] as? String ?? ""
                #expect(pending.contains(id))
                pending.remove(id)
            default:
                #expect(pending.isEmpty)
            }
        }
        #expect(pending.isEmpty)
    }

    /// Gemini pairs `functionCall` (model) with the immediately-following
    /// `functionResponse` (user) batch. Assert that adjacency both ways, that
    /// the totals balance, and that no text part is empty/whitespace-only.
    private static func assertGeminiToolPairing(_ request: GeminiGenerateContentRequest) {
        func callCount(_ content: GeminiContent?) -> Int {
            (content?.parts ?? []).reduce(0) { count, part in
                if case .functionCall = part.content { return count + 1 }
                return count
            }
        }
        func responseCount(_ content: GeminiContent?) -> Int {
            (content?.parts ?? []).reduce(0) { count, part in
                if case .functionResponse = part.content { return count + 1 }
                return count
            }
        }

        let contents = request.contents
        var totalCalls = 0
        var totalResponses = 0
        for (index, content) in contents.enumerated() {
            for part in content.parts {
                if case .text(let text) = part.content {
                    #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            let calls = callCount(content)
            totalCalls += calls
            if calls > 0 {
                let next = index + 1 < contents.count ? contents[index + 1] : nil
                #expect(responseCount(next) >= calls)
            }
            let responses = responseCount(content)
            totalResponses += responses
            if responses > 0 {
                let prev = index > 0 ? contents[index - 1] : nil
                #expect(callCount(prev) >= responses)
            }
        }
        #expect(totalCalls == totalResponses)
    }

    /// No Anthropic text block or `tool_result` may be empty or whitespace-only
    /// ("text content blocks must contain non-whitespace text").
    private static func assertNoEmptyAnthropicContent(_ request: AnthropicMessagesRequest) {
        func assertNonWhitespace(_ text: String) {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        for message in request.messages {
            switch message.content {
            case .text(let text):
                assertNonWhitespace(text)
            case .blocks(let blocks):
                for block in blocks {
                    switch block {
                    case .text(let textBlock):
                        assertNonWhitespace(textBlock.text)
                    case .toolResult(let result):
                        assertNonWhitespace(result.content?.plainText ?? "")
                    case .toolUse, .image:
                        break
                    }
                }
            }
        }
    }

    private static func decodeAsDictionary(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    private enum DecodeAsDictionaryError: Error { case notAnObject }
}
