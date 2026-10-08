//
//  ReasoningOffWireTests.swift
//  osaurusTests
//
//  #3036: compaction to a self-hosted vLLM Qwen3.8 came back empty because
//  "reasoning off" never reached the wire in a form that server reads. vLLM /
//  SGLang / llama.cpp take `chat_template_kwargs.enable_thinking`; DeepSeek V4
//  takes a `thinking` object; strict hosted schemas must receive neither.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Reasoning off reaches the wire (#3036)")
struct ReasoningOffWireTests {
    private static func service(host: String, port: Int = 8000) -> RemoteProviderService {
        RemoteProviderService(
            provider: RemoteProvider(
                name: "p", host: host, providerProtocol: .http, port: port, basePath: "/v1",
                authType: .none, providerType: .openaiLegacy),
            models: ["m"], resolvedHeaders: [:])
    }

    private static func wire(
        host: String, model: String = "Qwen3.8-Flash-Next", options: [String: ModelOptionValue]
    ) async throws -> [String: Any] {
        let request = await service(host: host).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "summarize")],
            parameters: GenerationParameters(temperature: 0.2, maxTokens: 1024, modelOptions: options),
            model: model, stream: false, tools: nil, toolChoice: nil)
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(arguments: ["dc01", "192.168.1.20", "localhost", "vllm.internal.example"])
    func selfHostedGetsTemplateKwargs(host: String) async throws {
        let payload = try await Self.wire(host: host, options: ["disableThinking": .bool(true)])
        #expect((payload["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(payload["thinking"] == nil)
    }

    @Test(arguments: ["none", "off", "instruct", "no_think"])
    func directRailEffortAlsoTurnsReasoningOff(effort: String) async throws {
        let payload = try await Self.wire(host: "dc01", options: ["reasoningEffort": .string(effort)])
        #expect((payload["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(payload["reasoning_effort"] == nil, "direct-rail aliases stay off the wire")
    }

    @Test func noReasoningOffRequestSendsNothing() async throws {
        for options: [String: ModelOptionValue] in [
            [:], ["disableThinking": .bool(false)], ["reasoningEffort": .string("high")],
        ] {
            let payload = try await Self.wire(host: "dc01", options: options)
            #expect(payload["chat_template_kwargs"] == nil)
        }
    }

    @Test(arguments: ["api.openai.com", "api.mistral.ai", "api.groq.com", "api.x.ai", "api.venice.ai"])
    func strictHostedSchemasNeverSeeTheField(host: String) async throws {
        let payload = try await Self.wire(host: host, options: ["disableThinking": .bool(true)])
        #expect(payload["chat_template_kwargs"] == nil)
    }

    @Test func deepSeekV4UsesItsThinkingObject() async throws {
        let payload = try await Self.wire(
            host: "api.deepseek.com", model: "deepseek-v4-flash",
            options: ["disableThinking": .bool(true)])
        #expect((payload["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(payload["chat_template_kwargs"] == nil)
    }

    @Test func finishReasonParsing() {
        let openAI = Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8)
        #expect(RemoteProviderService.oneShotFinishReason(openAI) == "length")
        let stop = Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        #expect(RemoteProviderService.oneShotFinishReason(stop) == "stop")
        #expect(RemoteProviderService.oneShotFinishReason(Data("{}".utf8)) == nil)
    }
}

@Suite("Compaction request contract (#3036)")
struct CompactionRequestContractTests {
    @Test func summaryRequestsReasoningOffAndCompleteOutput() {
        let params = ContextCompactionService.summaryParameters(sessionId: UUID(), requestSource: .chatUI)
        #expect(params.modelOptions["disableThinking"]?.boolValue == true)
        #expect(params.requireCompleteOutput)
        #expect(RemoteReasoningPolicy.requestsReasoningOff(params.modelOptions))
    }

    @Test func truncationIsALoudCompactionError() {
        let error = ContextCompactionError.truncatedSummary(model: "Qwen3.8-Flash-Next")
        #expect(error.errorDescription?.contains("output limit") == true)
    }
}
