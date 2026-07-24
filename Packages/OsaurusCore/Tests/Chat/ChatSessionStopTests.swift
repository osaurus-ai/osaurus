import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionStopTests {
    private static let asyncTimeout: Duration = .seconds(10)

    private func beginSuspendedPreSendHandshake(
        session: ChatSession,
        gate: IgnoringCancellationHandshakeGate
    ) async throws {
        session.warmupController.handleModelSelectionChange(
            session: session,
            to: "handshake-test-model",
            performSwitch: { _ in await gate.wait() }
        )
        try await waitUntilAsync(timeout: Self.asyncTimeout) {
            await gate.started
                && session.warmupController.needsPreSendHandshake
        }
    }

    @Test
    func stop_trimsTrailingEmptyAssistantPlaceholder() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns = [
                ChatTurn(role: .user, content: "Hello"),
                ChatTurn(role: .assistant, content: ""),
            ]

            session.stop()

            #expect(session.turns.count == 1)
            #expect(session.turns.last?.role == .user)
        }
    }

    @Test
    func stop_ignoresLateResultsWhenEngineSetupIgnoresCancellation() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { _ in IgnoringCancellationChatEngine() }

            session.send("Hello")
            try await Task.sleep(for: .milliseconds(20))
            session.stop()

            #expect(session.isStreaming == false)

            try await Task.sleep(for: .milliseconds(250))

            #expect(session.turns.count == 1)
            #expect(session.turns.first?.role == .user)
            #expect(session.turns.first?.content == "Hello")
        }
    }

    @Test
    func stop_cancelsEngineSetupBeforeStreamIsReturned() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let engine = CancellationObservingChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("Hello")
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.started
            }

            session.stop()

            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.cancelled
            }
            #expect(session.isStreaming == false)
            #expect(session.turns.count == 1)
            #expect(session.turns.first?.role == .user)
        }
    }

    @Test
    func send_ignoresReentrantSendBeforeStreamingFlagFlips() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { _ in IgnoringCancellationChatEngine() }

            session.send("first")
            session.send("second")

            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first"])

            session.stop()
        }
    }

    @Test
    func stop_invalidatesSuspendedPreSendHandshakeWithoutLaunchingCapturedTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("keep this stopped turn")
            #expect(session.turns.map(\.content) == ["keep this stopped turn"])

            session.stop()
            // Keep the test focused on the outer ChatSession task rather than
            // allowing the completed switch to schedule a speculative warm-up.
            session.warmupController.reset()
            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.isStreaming == false)
            #expect(session.turns.map(\.content) == ["keep this stopped turn"])
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func reset_doesNotResurrectTurnCapturedBySuspendedPreSendHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            #expect(session.turns.map(\.content) == ["old chat turn"])

            session.reset()
            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.turns.isEmpty)
            #expect(session.sessionId == nil)
            #expect(session.isStreaming == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func reset_incomingWarmupSurvivesCancelledPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.warmModelsOnLoad = true
            ChatConfigurationStore.save(chatConfig)

            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            session.chatEngineFactory = { _ in PreSendHandshakeRecordingEngine() }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            session.reset()

            let incomingEngine = IncomingWarmupRecordingEngine()
            let incomingSession = IncomingWarmupSession(engine: incomingEngine)
            session.warmupController.scheduleWarmup(
                session: incomingSession,
                debounce: .milliseconds(250)
            )

            await gate.release()
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await incomingEngine.requestCount == 1
            }

            #expect(session.turns.isEmpty)
            #expect(await incomingEngine.requestCount == 1)
        }
    }

    @Test
    func sessionLoad_doesNotAppendTurnCapturedByPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            let loaded = ChatSessionData(
                id: UUID(),
                title: "Loaded chat",
                turns: [ChatTurnData(role: .user, content: "loaded turn")]
            )
            session.load(from: loaded)
            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.sessionId == loaded.id)
            #expect(session.turns.map(\.content) == ["loaded turn"])
            #expect(session.isStreaming == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func sessionLoad_dropsQueuedDraftAndOneOffSkillFromPreviousHandshake() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("old chat turn")
            session.pendingOneOffSkillId = UUID()
            session.enqueueSend("old queued draft", attachments: [])
            session.pendingOneOffSkillId = UUID()
            #expect(session.queuedSend?.text == "old queued draft")
            #expect(session.queuedSend?.oneOffSkillId != nil)
            #expect(session.pendingOneOffSkillId != nil)

            let loaded = ChatSessionData(
                id: UUID(),
                title: "Loaded chat",
                turns: [ChatTurnData(role: .user, content: "loaded turn")]
            )
            session.load(from: loaded)

            #expect(session.queuedSend == nil)
            #expect(session.pendingOneOffSkillId == nil)

            await gate.release()
            try await Task.sleep(for: .milliseconds(250))

            #expect(session.sessionId == loaded.id)
            #expect(session.turns.map(\.content) == ["loaded turn"])
            #expect(session.isSendActiveForComposer == false)
            #expect(await engine.regularRequestCount == 0)
        }
    }

    @Test
    func send_ignoresReentrantSendWhilePreSendHandshakeIsSuspended() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            session.send("second")

            #expect(session.turns.filter { $0.role == .user }.map(\.content) == ["first"])

            session.stop()
            session.warmupController.reset()
            await gate.release()
        }
    }

    @Test
    func sendCurrent_queuesDraftWhilePreSendHandshakeIsSuspended() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            session.chatEngineFactory = { _ in PreSendHandshakeRecordingEngine() }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            #expect(session.isSendActiveForComposer)

            session.input = "second"
            session.sendCurrent()

            #expect(session.turns.filter { $0.role == .user }.map(\.content) == ["first"])
            #expect(session.queuedSend?.text == "second")
            #expect(session.input.isEmpty)

            session.stop()
            #expect(session.isSendActiveForComposer == false)
            session.warmupController.reset()
            await gate.release()
        }
    }

    @Test
    func sendNowInterrupting_replacesSuspendedHandshakeWithQueuedSend() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let gate = IgnoringCancellationHandshakeGate()
            let engine = PreSendHandshakeRecordingEngine()
            session.chatEngineFactory = { _ in engine }
            try await beginSuspendedPreSendHandshake(session: session, gate: gate)

            session.send("first")
            session.enqueueSend("replacement", attachments: [])
            session.sendNowInterrupting()

            #expect(
                session.turns.filter { $0.role == .user }.map(\.content)
                    == ["first", "replacement"]
            )

            await gate.release()
            try await waitUntilAsync(timeout: Self.asyncTimeout) {
                await engine.regularRequestCount == 1
            }
        }
    }

    @Test
    func send_finishesReasoningOnlyLocalStream() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { _ in ReasoningOnlyChatEngine() }

            session.send("Hello")

            try await waitUntil(timeout: Self.asyncTimeout) {
                session.turns.contains { $0.role == .assistant && !$0.thinkingIsBlank }
            }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming == false
            }

            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            #expect(assistant.contentIsBlank)
            #expect(assistant.thinking.contains("The user is straightforward greeting"))
            #expect(assistant.generationTokenCount == 0)
        }
    }
}

private actor IgnoringCancellationChatEngine: ChatEngineProtocol {
    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        try? await Task.sleep(for: .milliseconds(150))
        return AsyncThrowingStream { continuation in
            continuation.yield("late result")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 1)
    }
}

private actor CancellationObservingChatEngine: ChatEngineProtocol {
    private(set) var started = false
    private(set) var cancelled = false

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("unexpected")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 4)
    }
}

private actor ReasoningOnlyChatEngine: ChatEngineProtocol {
    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamingReasoningHint.encode("The user is straightforward greeting"))
            continuation.yield(StreamingStatsHint.encode(tokenCount: 0, tokensPerSecond: 0, unclosedReasoning: true))
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 2)
    }
}

/// Suspends a model-selection switch and deliberately ignores task
/// cancellation until the test releases it. This reproduces the production
/// race where a pre-send handshake can outlive Stop/reset/session load.
private actor IgnoringCancellationHandshakeGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PreSendHandshakeRecordingEngine: ChatEngineProtocol {
    private(set) var regularRequestCount = 0

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        if request.warmupPrefill != true {
            regularRequestCount += 1
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("unexpected stale dispatch")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 5)
    }
}

@MainActor
private final class IncomingWarmupSession: ChatWarmupSessionContext {
    let selectedModel: String? = "incoming-warmup-model"
    let selectedModelIsLocal = true
    let isRemoteAgentTarget = false
    let isStreaming = false
    private let engine: IncomingWarmupRecordingEngine

    init(engine: IncomingWarmupRecordingEngine) {
        self.engine = engine
    }

    func isImageGenerationModel(_: String?) -> Bool { false }

    func makeWarmupPayload() async -> ChatWarmupPayload? {
        ChatWarmupPayload(
            model: "incoming-warmup-model",
            messages: [ChatMessage(role: "system", content: "incoming chat prefix")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "incoming-warmup-model|incoming-chat-prefix"
        )
    }

    func makeWarmupEngine() -> ChatEngineProtocol { engine }
}

private actor IncomingWarmupRecordingEngine: ChatEngineProtocol {
    private(set) var requestCount = 0

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionStopTests", code: 6)
    }
}

private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionStopTests", code: 3)
}

@MainActor
private func waitUntilAsync(
    timeout: Duration,
    _ predicate: @MainActor @escaping () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionStopTests", code: 5)
}
