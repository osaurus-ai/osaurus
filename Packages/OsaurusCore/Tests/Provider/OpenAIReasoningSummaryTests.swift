//
//  OpenAIReasoningSummaryTests.swift
//  osaurusTests
//
//  Responses requests on the official OpenAI and ChatGPT/Codex routes ask for
//  a reasoning summary even when no effort was picked, and the official GPT-6
//  effort table decides when `none` reaches the wire.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenAI reasoning summaries and GPT-6 efforts")
struct OpenAIReasoningSummaryTests {

    @Test func summaryIsRequestedOnlyOnOfficialAndCodexRoutes() {
        #expect(RemoteProviderService.requestsReasoningSummary(
            providerType: .openResponses, host: "api.openai.com", model: "gpt-6-astra"))
        #expect(RemoteProviderService.requestsReasoningSummary(
            providerType: .openResponses, host: "api.openai.com", model: "o4-mini"))
        #expect(!RemoteProviderService.requestsReasoningSummary(
            providerType: .openResponses, host: "api.openai.com", model: "gpt-4.1"))
        #expect(!RemoteProviderService.requestsReasoningSummary(
            providerType: .openResponses, host: "api.openai.com", model: "gpt-5-chat-latest"))
        #expect(!RemoteProviderService.requestsReasoningSummary(
            providerType: .openResponses, host: "litellm.internal", model: "gpt-6-astra"))
        #expect(!RemoteProviderService.requestsReasoningSummary(
            providerType: .openaiLegacy, host: "api.openai.com", model: "gpt-6-astra"))
        #expect(RemoteProviderService.requestsReasoningSummary(
            providerType: .openAICodex, host: "chatgpt.com", model: "gpt-5.6-terra"))
    }

    @Test func officialRouteSendsSummaryWithoutEffort() async throws {
        let service = Self.makeService(providerType: .openResponses, host: "api.openai.com")
        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(temperature: 0.7, maxTokens: 512),
            model: "gpt-6-astra",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let responses = try request.toOpenResponsesRequest()
        #expect(responses.reasoning?.summary == "auto")
        #expect(responses.reasoning?.effort == nil, "effort stays on the server default")

        let payload = try Self.decodeAsDictionary(try JSONEncoder().encode(responses))
        let reasoning = try #require(payload["reasoning"] as? [String: Any])
        #expect(reasoning["summary"] as? String == "auto")
        #expect(reasoning["effort"] == nil)
    }

    @Test func officialRouteKeepsSummaryWithPickedEffort() async throws {
        let service = Self.makeService(providerType: .openResponses, host: "api.openai.com")
        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(
                temperature: 0.7, maxTokens: 512, modelOptions: ["reasoningEffort": .string("xhigh")]),
            model: "gpt-6.1-sol",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let responses = try request.toOpenResponsesRequest()
        #expect(responses.reasoning?.effort == "xhigh")
        #expect(responses.reasoning?.summary == "auto")
    }

    @Test func customHostAndAgentRunsGetNoSummary() async throws {
        let proxy = Self.makeService(providerType: .openResponses, host: "litellm.internal")
        let proxied = await proxy.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(temperature: 0.7, maxTokens: 512),
            model: "gpt-6-astra",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(try proxied.toOpenResponsesRequest().reasoning == nil)

        let official = Self.makeService(providerType: .openResponses, host: "api.openai.com")
        let agentParameters = GenerationParameters(temperature: 0.7, maxTokens: 512, runAsRemoteAgent: true)
        let agentRun = await official.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: agentParameters,
            model: "gpt-6-astra",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(try agentRun.toOpenResponsesRequest().reasoning == nil)
    }

    @Test func codexRouteSendsSummaryWithoutEffort() async throws {
        let service = Self.makeService(providerType: .openAICodex, host: "chatgpt.com")
        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(temperature: 0.7, maxTokens: 512),
            model: "gpt-5.6-terra",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        let responses = try request.toCodexOpenResponsesRequest()
        #expect(responses.reasoning?.summary == "auto")
        let payload = try Self.decodeAsDictionary(
            try responses.toCodexOAuthPayloadData(sessionId: nil, usesResponsesLite: false))
        let reasoning = try #require(payload["reasoning"] as? [String: Any])
        #expect(reasoning["summary"] as? String == "auto")
        #expect(reasoning["context"] as? String == "all_turns")
    }

    @Test func noneReachesTheWireOnlyForModelsThatDocumentIt() {
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-6.1-terra", effort: "none").effort
            == "none")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-6-luna", effort: "none").effort
            == "none")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-5.6-sol", effort: "none").effort
            == "none")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-6-sol", effort: "none").effort
            == "none")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-5.5", effort: "none").effort
            == "none", "GPT-5.5 defaults to medium, so dropping none keeps reasoning on")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-5.1", effort: "none").effort
            == "none")
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "o3", effort: "none").effort
            == nil)
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-6-astra", effort: "none").effort
            == nil)
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "api.openai.com", model: "gpt-6.1-sol", effort: "none").effort
            == nil)
        #expect(RemoteReasoningPolicy.dsv4Effort(host: "litellm.internal", model: "gpt-6.1-terra", effort: "none").effort
            == nil)
    }

    // MARK: - Fixtures

    private static func makeService(providerType: RemoteProviderType, host: String) -> RemoteProviderService {
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
            models: [],
            resolvedHeaders: [:]
        )
    }

    private static func decodeAsDictionary(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
