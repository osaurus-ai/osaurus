//
//  ChatSessionAgentSettingsTests.swift
//  OsaurusCoreTests
//
//  Pins the agent-bound chat sampling contract: a ChatSession running under a
//  custom agent must pass the agent's temperature and max-token settings into
//  the model request. This guards the "agent mode ignores custom temperature"
//  support report without changing the remote-agent Mode 2 boundary, where the
//  host agent intentionally resolves its own sampling settings server-side.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionAgentSettingsTests {
    private static let asyncTimeout: Duration = .seconds(10)

    @Test
    func sendUsesCustomAgentGenerationSettings() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "Sampling Agent \(UUID().uuidString)",
                temperature: 0.23,
                maxTokens: 321
            )
            manager.add(agent)

            let engine = AgentSettingsCaptureEngine()
            let session = ChatSession()
            session.agentId = agent.id
            session.chatEngineFactory = { _ in engine }

            session.send("Use the configured sampling values.")

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.request != nil
            }

            let request = try #require(await engine.request)
            #expect(request.temperature == 0.23)
            #expect(request.max_tokens == 321)

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                !session.isStreaming
            }
        }
    }
}

private actor AgentSettingsCaptureEngine: ChatEngineProtocol {
    private(set) var request: ChatCompletionRequest?

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        self.request = request
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionAgentSettingsTests", code: 1)
    }
}

@MainActor
private func waitUntilAsync(
    timeout: Duration,
    _ predicate: @escaping () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionAgentSettingsTests", code: 2)
}
