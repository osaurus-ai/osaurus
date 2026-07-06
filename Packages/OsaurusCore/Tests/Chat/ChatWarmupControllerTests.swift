//
//  ChatWarmupControllerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ChatConfiguration warmModelsOnLoad")
struct ChatConfigurationWarmModelsOnLoadTests {

    @Test("defaults to on")
    func defaultOn() {
        #expect(ChatConfiguration.default.warmModelsOnLoad == true)
    }

    @Test("Codable round-trip preserves explicit off")
    func codableRoundTripOff() throws {
        var cfg = ChatConfiguration.default
        cfg.warmModelsOnLoad = false
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.warmModelsOnLoad == false)
    }

    @Test("missing key decodes to on")
    func missingFieldDefaultsOn() throws {
        let json = #"{"systemPrompt":""}"#
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: Data(json.utf8))
        #expect(decoded.warmModelsOnLoad == true)
    }
}

@Suite("ChatWarmupController debounce")
@MainActor
struct ChatWarmupControllerDebounceTests {

    @Test("quick model switch-back does not evict before debounce fires")
    func switchBackSkipsEviction() async {
        var evictionCount = 0
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(
            session: session,
            from: "test-model",
            to: "other-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        controller.handleModelSelectionChange(
            session: session,
            from: "other-model",
            to: "test-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        try? await Task.sleep(for: .milliseconds(100))
        #expect(evictionCount == 0)
    }
}

@Suite("ChatWarmupController request fidelity")
@MainActor
struct ChatWarmupControllerRequestTests {

    /// The warm-up generation must mirror the real send's prompt-affecting
    /// options. `enable_thinking` (derived from `disableThinking`) changes
    /// both the rendered template and the runtime's cache-scope salt — a
    /// warm-up without it prefetches under a different cache key and every
    /// real send misses (the "green dot but prefill from 0" bug).
    @Test("warm-up request carries the payload's model options")
    func warmupRequestCarriesModelOptions() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: ["disableThinking": .bool(true)],
            fingerprint: "test-model|hint|opts|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest?.modelOptions?["disableThinking"] == .bool(true))
        #expect(engine.lastRequest?.suppressProgressUI == true)
        #expect(engine.lastRequest?.warmupPrefill == true)
    }
}

@MainActor
private final class WarmupTestSession: ChatWarmupSessionContext {
    var selectedModel: String? = "test-model"
    var selectedModelIsLocal: Bool = true
    var isRemoteAgentTarget: Bool = false
    var isStreaming: Bool = false
    var payload: ChatWarmupPayload?
    var engine: ChatEngineProtocol = WarmupTestEngine()

    func isImageGenerationModel(_ id: String?) -> Bool { false }

    func makeWarmupPayload() async -> ChatWarmupPayload? { payload }

    func makeWarmupEngine() -> ChatEngineProtocol { engine }
}

private final class WarmupRecordingEngine: ChatEngineProtocol, @unchecked Sendable {
    var lastRequest: ChatCompletionRequest?

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        lastRequest = request
        return ChatCompletionResponse(
            id: "test",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}

private struct WarmupTestEngine: ChatEngineProtocol {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "test",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}
