import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionStopTests {
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
