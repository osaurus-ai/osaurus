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

    private static func decodeAsDictionary(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeAsDictionaryError.notAnObject
        }
        return obj
    }

    private enum DecodeAsDictionaryError: Error { case notAnObject }
}
