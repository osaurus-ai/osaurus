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

@Suite("ChatWarmupController RAM gate")
@MainActor
struct ChatWarmupControllerRAMGateTests {

    private static func feasibility(
        projected: Int64,
        soft: Int64,
        hard: Int64,
        physical: Int64,
        requiredAvailable: Int64
    ) -> ModelRuntime.RAMFeasibility {
        ModelRuntime.RAMFeasibility(
            modelName: "test-model",
            verdict: projected > soft ? .tight : .ok,
            incomingWeightsBytes: projected,
            incomingLoadFootprintBytes: projected,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 0,
            projectedBytes: projected,
            physicalMemoryBytes: physical,
            availableMemoryBytes: physical,
            requiredAvailableBytes: requiredAvailable,
            softLimitBytes: soft,
            hardLimitBytes: hard,
            automaticMemoryLimitsDisabled: false,
            // Budget unknown, so it never influences these warmup assertions.
            gpuBudgetBytes: 0,
            timestamp: Date()
        )
    }

    /// Sentry APPLE-MACOS-3T: a window-open warm-up of a 31B model on a
    /// 24GB machine died in a fatal Metal OOM. Proactive warm-up must skip
    /// entirely when the projection is block-severity.
    @Test("warm-up is skipped when the projected load exceeds the hard RAM ceiling")
    func warmupSkippedWhenProjectionBlocks() async {
        let gib: Int64 = 1_073_741_824
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
        controller.projectedLoadFeasibility = { _ in
            Self.feasibility(
                projected: 23 * gib,
                soft: Int64(16.8 * Double(gib)),
                hard: Int64(21.6 * Double(gib)),
                physical: 24 * gib,
                requiredAvailable: 23 * gib
            )
        }
        controller.scheduleWarmup(session: session, debounce: .zero)

        try? await Task.sleep(for: .milliseconds(150))
        await controller.awaitInFlightWarmup()

        // No generation was started, and the dot must not claim warming.
        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
    }

    @Test("warn-severity projection still warms up")
    func warnSeverityStillWarms() async {
        let gib: Int64 = 1_073_741_824
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
        controller.projectedLoadFeasibility = { _ in
            Self.feasibility(
                projected: 18 * gib,
                soft: Int64(16.8 * Double(gib)),
                hard: Int64(21.6 * Double(gib)),
                physical: 24 * gib,
                requiredAvailable: 18 * gib
            )
        }
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest != nil)
        #expect(controller.state == .warm)
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
        #expect(engine.lastRequest?.backgroundModelLoad == true)
    }
}

@Suite("ChatWarmupController completed-run policy")
@MainActor
struct ChatWarmupControllerCompletedRunTests {

    @Test("stopped run does not launch a hidden transcript warm-up")
    func stoppedRunDoesNotWarm() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(
                    role: "user",
                    content: String(repeating: "cancelled prompt ", count: 2_000)
                ),
            ],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|cancelled-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: true,
            hadError: false
        )

        try? await Task.sleep(for: .milliseconds(650))
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 0)
        #expect(controller.state == .cold)
    }

    @Test("successful run still refreshes the completed transcript checkpoint")
    func successfulRunStillWarms() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|successful-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: false,
            hadError: false
        )

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }
}

@Suite("ChatWarmupController runtime residency")
@MainActor
struct ChatWarmupControllerRuntimeResidencyTests {

    @Test("external eviction clears the warm claim and cached fingerprint")
    func externalEvictionClearsWarmClaimAndFingerprint() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)

        controller.reconcileRuntimeResidency(
            selectedModel: session.selectedModel,
            residentModelNames: ["different-model"]
        )
        #expect(controller.state == .cold)

        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if engine.requestCount == 2, controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        // A second request proves eviction cleared the cached fingerprint;
        // otherwise scheduleWarmup would immediately restore the green state
        // without touching the runtime.
        #expect(engine.requestCount == 2)
        #expect(controller.state == .warm)
    }

    @Test("canonical and tail model identifiers preserve the warm claim")
    func equivalentResidentIdentifierPreservesWarmClaim() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)

        controller.reconcileRuntimeResidency(
            selectedModel: session.selectedModel,
            residentModelNames: ["test-model"]
        )

        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)
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
    var requestCount = 0

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        requestCount += 1
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
