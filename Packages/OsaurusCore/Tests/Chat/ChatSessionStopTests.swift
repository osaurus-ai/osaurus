import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionStopTests {
    private static let asyncTimeout: Duration = .seconds(10)

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
            session.chatEngineFactory = { IgnoringCancellationChatEngine() }

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
            session.chatEngineFactory = { engine }

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
            session.chatEngineFactory = { IgnoringCancellationChatEngine() }

            session.send("first")
            session.send("second")

            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first"])

            session.stop()
        }
    }

    @Test
    func send_finishesReasoningOnlyLocalStream() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { ReasoningOnlyChatEngine() }

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
