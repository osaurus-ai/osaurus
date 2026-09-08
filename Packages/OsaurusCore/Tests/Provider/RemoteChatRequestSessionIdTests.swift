//
//  RemoteChatRequestSessionIdTests.swift
//  osaurusTests
//
//  A teammate chatting with a shared agent (Mode 2 against an `.osaurus`
//  peer) threads its stable conversation id as `session_id` so the host can
//  group every turn into one history row. The field must never leak onto
//  Mode 1 chat-completions bodies (the OpenAI-compatible wire has no such
//  key) nor onto non-Osaurus providers.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RemoteChatRequest session_id (Mode 2)")
struct RemoteChatRequestSessionIdTests {

    private static func makeService(
        providerType: RemoteProviderType,
        remoteAgentAddress: String? = "0xagent"
    ) -> RemoteProviderService {
        RemoteProviderService(
            provider: RemoteProvider(
                name: "peer",
                host: "127.0.0.1",
                providerProtocol: .http,
                port: 1337,
                basePath: "/v1",
                authType: .none,
                providerType: providerType,
                remoteAgentId: UUID(),
                remoteAgentAddress: remoteAgentAddress
            ),
            models: ["m"],
            resolvedHeaders: [:]
        )
    }

    private static func params(runAsRemoteAgent: Bool, sessionId: String?) -> GenerationParameters {
        GenerationParameters(
            temperature: 0.7,
            maxTokens: 512,
            sessionId: sessionId,
            runAsRemoteAgent: runAsRemoteAgent
        )
    }

    private static func wire(_ request: RemoteChatRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func mode2_osaurus_threadsSessionIdOnTheWire() async throws {
        let req = await Self.makeService(providerType: .osaurus).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.params(runAsRemoteAgent: true, sessionId: "CONVO-1"),
            model: "m",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(req.runAsRemoteAgent)
        #expect(req.remoteAgentSessionId == "CONVO-1")
        let payload = try Self.wire(req)
        #expect(payload["session_id"] as? String == "CONVO-1")
        #expect(payload["model"] == nil, "Mode 2 still omits model on the wire")
    }

    @Test func mode2_osaurus_withoutSessionId_omitsKey() async throws {
        let req = await Self.makeService(providerType: .osaurus).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.params(runAsRemoteAgent: true, sessionId: nil),
            model: "m",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(req.remoteAgentSessionId == nil)
        #expect(try Self.wire(req)["session_id"] == nil)

        let blank = await Self.makeService(providerType: .osaurus).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.params(runAsRemoteAgent: true, sessionId: ""),
            model: "m",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(try Self.wire(blank)["session_id"] == nil)
    }

    @Test func mode1_osaurus_neverSendsSessionId() async throws {
        let req = await Self.makeService(providerType: .osaurus).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: Self.params(runAsRemoteAgent: false, sessionId: "CONVO-1"),
            model: "m",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(req.runAsRemoteAgent == false)
        #expect(req.remoteAgentSessionId == nil)
        let payload = try Self.wire(req)
        #expect(payload["session_id"] == nil)
        #expect(payload["model"] as? String == "m")
    }

    @Test func nonOsaurusProviders_neverSendSessionId() async throws {
        for providerType in [RemoteProviderType.openaiLegacy, .osaurusRouter, .anthropic] {
            let req = await Self.makeService(providerType: providerType).buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: Self.params(runAsRemoteAgent: false, sessionId: "CONVO-1"),
                model: "m",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
            #expect(req.remoteAgentSessionId == nil, "\(providerType)")
            #expect(try Self.wire(req)["session_id"] == nil, "\(providerType)")
        }
    }

    @Test func encode_dropsSessionIdWhenFlagIsCleared() throws {
        // Even if a caller stamps the id, a non-agent-run body must not carry it.
        var req = RemoteChatRequest(
            model: "m",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_completion_tokens: nil,
            stream: true,
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
        req.remoteAgentSessionId = "CONVO-1"
        req.runAsRemoteAgent = false
        #expect(try Self.wire(req)["session_id"] == nil)
        req.runAsRemoteAgent = true
        #expect(try Self.wire(req)["session_id"] as? String == "CONVO-1")
    }
}
