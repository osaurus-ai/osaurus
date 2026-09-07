//
//  OpenCodeSessionHeaderTests.swift
//  osaurusTests
//
//  OpenCode Go rejects requests that lack `x-opencode-session` with HTTP 400
//  "Request is missing x-opencode-session and cannot be routed efficiently".
//  These tests pin that Osaurus stamps the header on every request to an
//  OpenCode host, keeps it stable across turns of one conversation, never
//  sends it elsewhere, and lets a user-supplied custom header win.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenCode session affinity header")
struct OpenCodeSessionHeaderTests {
    private static func makeProvider(
        host: String,
        providerType: RemoteProviderType = .openaiLegacy,
        customHeaders: [String: String] = [:]
    ) -> RemoteProvider {
        RemoteProvider(
            name: "opencode",
            host: host,
            basePath: "/zen/v1",
            customHeaders: customHeaders,
            authType: .none,
            providerType: providerType
        )
    }

    private static func makeService(
        host: String = "opencode.ai",
        providerType: RemoteProviderType = .openaiLegacy,
        resolvedHeaders: [String: String] = [:]
    ) -> RemoteProviderService {
        RemoteProviderService(
            provider: makeProvider(host: host, providerType: providerType),
            models: ["opencode/gpt-5"],
            resolvedHeaders: resolvedHeaders
        )
    }

    private static func buildRequest(
        _ service: RemoteProviderService,
        sessionId: String?
    ) async throws -> URLRequest {
        let req = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: GenerationParameters(temperature: 0.7, maxTokens: 256, sessionId: sessionId),
            model: "opencode/gpt-5",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        return try await service.buildURLRequest(for: req)
    }

    @Test func hostDetection() {
        #expect(RemoteProviderService.isOpenCodeHost("opencode.ai"))
        #expect(RemoteProviderService.isOpenCodeHost("OpenCode.ai"))
        #expect(RemoteProviderService.isOpenCodeHost("api.opencode.ai"))
        #expect(!RemoteProviderService.isOpenCodeHost("api.openai.com"))
        #expect(!RemoteProviderService.isOpenCodeHost("notopencode.ai"))
        #expect(!RemoteProviderService.isOpenCodeHost("opencode.ai.example.com"))
    }

    @Test func opencodeHost_stampsHeaderAndKeepsItStablePerConversation() async throws {
        let service = Self.makeService()
        let first = try await Self.buildRequest(service, sessionId: "conv-1")
        let second = try await Self.buildRequest(service, sessionId: "conv-1")
        let other = try await Self.buildRequest(service, sessionId: "conv-2")

        let firstId = try #require(first.value(forHTTPHeaderField: "x-opencode-session"))
        #expect(UUID(uuidString: firstId) != nil)
        #expect(second.value(forHTTPHeaderField: "x-opencode-session") == firstId)
        #expect(other.value(forHTTPHeaderField: "x-opencode-session") != firstId)
    }

    @Test func opencodeHost_withoutConversation_stillSendsHeader() async throws {
        // API-server callers without a session id must still route; each
        // request gets a fresh id rather than being rejected upstream.
        let service = Self.makeService()
        let a = try await Self.buildRequest(service, sessionId: nil)
        let b = try await Self.buildRequest(service, sessionId: nil)
        let aId = try #require(a.value(forHTTPHeaderField: "x-opencode-session"))
        let bId = try #require(b.value(forHTTPHeaderField: "x-opencode-session"))
        #expect(aId != bId)
    }

    @Test func opencodeHost_anthropicProviderType_alsoStampsHeader() async throws {
        let service = Self.makeService(providerType: .anthropic)
        let request = try await Self.buildRequest(service, sessionId: "conv-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") != nil)
    }

    @Test func userCustomHeader_wins() async throws {
        let service = Self.makeService(resolvedHeaders: ["X-OpenCode-Session": "mine"])
        let request = try await Self.buildRequest(service, sessionId: "conv-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == "mine")
    }

    @Test func nonOpenCodeHost_neverSendsHeader() async throws {
        let service = Self.makeService(host: "api.openai.com")
        let request = try await Self.buildRequest(service, sessionId: "conv-1")
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == nil)
    }

    @Test func sessionKey_neverReachesTheWire() throws {
        var request = RemoteChatRequest(
            model: "m",
            messages: [ChatMessage(role: "user", content: "hi")],
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
        request.opencodeSessionKey = "conv-1"
        let data = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(request)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("opencodeSessionKey"))
        #expect(!text.contains("conv-1"))
    }
}
