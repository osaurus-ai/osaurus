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

@Suite("ChatWarmupController immediate model switch")
@MainActor
struct ChatWarmupControllerModelSwitchTests {

    @Test("selection change performs the residency switch immediately")
    func selectionChangeSwitchesImmediately() async {
        var evictionCount = 0
        var lastEvictOthers: Bool?
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { evictOthers in
                evictionCount += 1
                lastEvictOthers = evictOthers
            }
        )

        // No debounce: the switch (and its eviction) must run promptly, not
        // after a multi-second grace timer.
        for _ in 0 ..< 100 {
            if evictionCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(evictionCount == 1)
        // Default policy in the test environment is strict single-model, so
        // the switch must ask for eviction of the previous model.
        #expect(lastEvictOthers == true)
        #expect(controller.state != .warm)
    }

    @Test("rapid consecutive switches all settle without losing an eviction")
    func rapidSwitchesSerialize() async {
        var evictionCount = 0
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { _ in evictionCount += 1 }
        )
        controller.handleModelSelectionChange(
            session: session,
            to: "test-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        for _ in 0 ..< 100 {
            if evictionCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(evictionCount == 2)
    }

    @Test("selection change cancels an in-flight warm-up generation")
    func selectionChangeCancelsInFlightWarmup() async {
        let engine = HangingWarmupEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        // Wait until the warm-up generation is actually streaming.
        for _ in 0 ..< 100 {
            if engine.started { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.started)

        // Keep the post-switch re-warm from starting another hanging stream:
        // shouldAttemptWarmup bails while the session reports streaming.
        session.isStreaming = true

        var evictionCount = 0
        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        // The stale warm-up must be cancelled (stream terminated) and the
        // eviction must not wait for the warm-up to finish on its own.
        for _ in 0 ..< 100 {
            if engine.terminated && evictionCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.terminated)
        #expect(evictionCount == 1)
        #expect(controller.state == .warming)
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

@Suite("ChatWarmupController shutdown")
@MainActor
struct ChatWarmupControllerShutdownTests {

    /// Window close calls `cleanup()` → `shutdown()` before `session.stop()`.
    /// `stop()`'s run-completed path calls `scheduleWarmup` again; after
    /// shutdown that must be inert so teardown can't start model work.
    @Test("scheduleWarmup after shutdown does not run a warm-up")
    func scheduleAfterShutdownIsInert() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.shutdown()
        controller.scheduleWarmup(session: session, debounce: .zero)

        try? await Task.sleep(for: .milliseconds(150))
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
    }

    @Test("shutdown cancels a scheduled-but-not-started warm-up")
    func shutdownCancelsScheduledWarmup() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .milliseconds(80))
        controller.shutdown()

        try? await Task.sleep(for: .milliseconds(200))
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
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

/// Engine whose stream never finishes on its own — only cancellation
/// terminates it. Lets tests prove a model switch cancels the in-flight
/// warm-up instead of waiting it out.
private final class HangingWarmupEngine: ChatEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _terminated = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    var terminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _terminated
    }

    private func markStarted() {
        lock.lock()
        _started = true
        lock.unlock()
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        markStarted()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self._terminated = true
                self.lock.unlock()
            }
            // Never finish: the warm-up only ends via task cancellation.
        }
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
