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
        host: String, port: Int = 8000, model: String = "Qwen3.8-Flash-Next",
        options: [String: ModelOptionValue]
    ) async throws -> [String: Any] {
        let request = await service(host: host, port: port).buildChatRequest(
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

    // MARK: - Ollama (#3435)

    @Test(arguments: [("localhost", 11434), ("192.168.1.20", 11434), ("ollama.com", 443)])
    func ollamaGetsReasoningEffortNone(host: String, port: Int) async throws {
        let payload = try await Self.wire(host: host, port: port, options: ["disableThinking": .bool(true)])
        #expect(payload["reasoning_effort"] as? String == "none")
        #expect((payload["reasoning"] as? [String: String]) == ["effort": "none"])
        #expect(payload["chat_template_kwargs"] == nil, "Ollama's /v1 drops chat_template_kwargs")
        #expect(payload["thinking"] == nil)
    }

    @Test(arguments: ["none", "off", "instruct"])
    func ollamaDirectRailEffortSendsNone(effort: String) async throws {
        let payload = try await Self.wire(
            host: "localhost", port: 11434, options: ["reasoningEffort": .string(effort)])
        #expect(payload["reasoning_effort"] as? String == "none")
    }

    @Test func ollamaWithThinkingOnKeepsTheModelDefault() async throws {
        let unset = try await Self.wire(host: "localhost", port: 11434, options: [:])
        #expect(unset["reasoning_effort"] == nil)
        let high = try await Self.wire(
            host: "localhost", port: 11434, options: ["reasoningEffort": .string("high")])
        #expect(high["reasoning_effort"] as? String == "high")
    }

    @Test func otherSelfHostedPortsKeepTemplateKwargs() async throws {
        let payload = try await Self.wire(host: "localhost", port: 1234, options: ["disableThinking": .bool(true)])
        #expect((payload["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(payload["reasoning_effort"] == nil)
    }

    // MARK: - Provider-reported completion (#3435)

    @Test func outputTokenParsing() {
        let openAI = Data(#"{"choices":[],"usage":{"prompt_tokens":40,"completion_tokens":96}}"#.utf8)
        #expect(RemoteProviderService.oneShotOutputTokens(openAI) == 96)
        let anthropic = Data(#"{"stop_reason":"max_tokens","usage":{"input_tokens":40,"output_tokens":12}}"#.utf8)
        #expect(RemoteProviderService.oneShotOutputTokens(anthropic) == 12)
        let gemini = Data(#"{"usageMetadata":{"candidatesTokenCount":5,"thoughtsTokenCount":91}}"#.utf8)
        #expect(RemoteProviderService.oneShotOutputTokens(gemini) == 96)
        #expect(RemoteProviderService.oneShotOutputTokens(Data("{}".utf8)) == nil)
    }

    @Test func streamedOneShotRecordsStatsOnTheProbe() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield("")
        continuation.yield(StreamingStatsHint.encode(tokenCount: 96, tokensPerSecond: 0, stopReason: "length"))
        continuation.finish()
        let probe = WireTransportProbe()
        let text = try await WireTransportProbe.$current.withValue(probe) {
            try await RemoteProviderService.collectVisibleText(from: stream)
        }
        #expect(text.isEmpty)
        #expect(probe.completion == .init(finishReason: "length", outputTokens: 96))
    }

    @Test func probeIgnoresAnEmptyCompletion() {
        let probe = WireTransportProbe()
        probe.recordCompletion(finishReason: nil, outputTokens: nil)
        #expect(probe.completion == nil)
    }

    @Test func insightsFinishReasonMapping() {
        #expect(CoreModelService.loggedFinishReason(nil) == .stop)
        #expect(CoreModelService.loggedFinishReason("stop") == .stop)
        #expect(CoreModelService.loggedFinishReason("length") == .length)
        #expect(CoreModelService.loggedFinishReason("max_tokens") == .length)
        #expect(CoreModelService.loggedFinishReason("MAX_TOKENS") == .length)
        #expect(CoreModelService.loggedFinishReason("incomplete") == .length)
        #expect(CoreModelService.loggedFinishReason("tool_calls") == .toolCalls)
        #expect(CoreModelService.loggedFinishReason("tool_use") == .toolCalls)
        #expect(CoreModelService.loggedFinishReason("end_turn") == .stop)
    }
}

@Suite("Compaction request contract (#3036)")
struct CompactionRequestContractTests {
    @Test func remoteSummaryRequestsReasoningOffAndCompleteOutput() {
        let params = ContextCompactionService.summaryParameters(
            sessionId: UUID(), requestSource: .chatUI, remote: true)
        #expect(params.modelOptions["disableThinking"]?.boolValue == true)
        #expect(params.requireCompleteOutput)
        #expect(RemoteReasoningPolicy.requestsReasoningOff(params.modelOptions))
    }

    @Test func localSummaryWithoutThinkingSwitchKeepsModelOptionsUntouched() {
        let params = ContextCompactionService.summaryParameters(
            sessionId: UUID(), requestSource: .chatUI, remote: false)
        #expect(params.modelOptions.isEmpty)
        #expect(params.requireCompleteOutput)
    }

    @Test func localSummaryUsesOnlyTheSupportedThinkingSwitch() {
        let capability = LocalReasoningCapability.analyze(template: """
            {% if enable_thinking is false %}{{ '<think></think>' }}
            {% else %}{{ '<think>' }}{% endif %}
            """)
        #expect(capability.isToggleableThinking)
        let params = ContextCompactionService.summaryParameters(
            sessionId: UUID(), requestSource: .chatUI, remote: false,
            localThinkingCapability: capability)
        #expect(params.modelOptions == ["disableThinking": .bool(true)])
        #expect(params.requireCompleteOutput)
    }

    @Test func thinkingWithoutATemplateSwitchIsNotOverridden() {
        let capability = LocalReasoningCapability.analyze(template: "{{ '<think>' }}")
        #expect(!capability.isToggleableThinking)
        let params = ContextCompactionService.summaryParameters(
            sessionId: nil, requestSource: .chatUI, remote: false,
            localThinkingCapability: capability)
        #expect(params.modelOptions.isEmpty)
    }

    @Test func truncationIsALoudCompactionError() {
        let error = ContextCompactionError.truncatedSummary(model: "Qwen3.8-Flash-Next")
        #expect(error.errorDescription?.contains("output limit") == true)
    }
}
