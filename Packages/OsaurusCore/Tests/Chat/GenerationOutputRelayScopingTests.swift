//
//  GenerationOutputRelayScopingTests.swift
//  OsaurusCoreTests
//
//  `GenerationOutputRelay` is process-wide: every local generation announces
//  its output completion there. A chat step must only accept the completion
//  of its OWN session's generation — a title / follow-up / memory job or a
//  foreign session finishing after the step started used to mark the turn
//  complete before its model had emitted a token, which hid the typing
//  indicator ("Loading Model..."), the cursor, and pushed every delta through
//  the non-streaming table path.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GenerationOutputRelayCompletionMatchingTests {
    private let started = Date(timeIntervalSince1970: 1_000)

    private func completion(
        at offset: TimeInterval = 1,
        sessionId: String? = "session-A",
        activitySource: RequestSource = .chatUI,
        auxiliary: Bool = false
    ) -> GenerationOutputRelay.Completion {
        GenerationOutputRelay.Completion(
            modelName: "local/model",
            at: started.addingTimeInterval(offset),
            generationTokens: 12,
            sessionId: sessionId,
            activitySource: activitySource,
            auxiliary: auxiliary
        )
    }

    @Test
    func acceptsOwnSessionsChatCompletionAfterStepStart() {
        #expect(completion().matches(sessionId: "session-A", startedAt: started))
        // Exactly at the start instant still counts (the adapter stamps
        // after the chat captured `streamStartTime`).
        #expect(completion(at: 0).matches(sessionId: "session-A", startedAt: started))
    }

    @Test
    func acceptsDispatchedSessionSources() {
        // Channel / scheduled sessions render in the same chat UI and own
        // their step's completion just like an interactive chat.
        for source in [RequestSource.channel, .scheduled, .p2p] {
            #expect(
                completion(activitySource: source).matches(sessionId: "session-A", startedAt: started),
                "\(source) session completion must be accepted"
            )
        }
    }

    @Test
    func rejectsCompletionsBeforeStepStart() {
        #expect(!completion(at: -0.001).matches(sessionId: "session-A", startedAt: started))
    }

    @Test
    func rejectsOtherSessions() {
        #expect(!completion(sessionId: "session-B").matches(sessionId: "session-A", startedAt: started))
    }

    @Test
    func rejectsWhenEitherSideHasNoSession() {
        // Requests without a session id (HTTP API clients, one-shot
        // utilities) can never claim a chat step; a chat without an id
        // must not accept an id-less foreign request either.
        #expect(!completion(sessionId: nil).matches(sessionId: "session-A", startedAt: started))
        #expect(!completion(sessionId: "session-A").matches(sessionId: nil, startedAt: started))
        #expect(!completion(sessionId: nil).matches(sessionId: nil, startedAt: started))
    }

    @Test
    func rejectsAuxiliaryUtilityGenerations() {
        // Title / follow-up / memory distillation, even when they happen to
        // carry the chat's own session id.
        #expect(!completion(auxiliary: true).matches(sessionId: "session-A", startedAt: started))
    }

    @Test
    func rejectsDelegatedSubagentSteps() {
        #expect(
            !completion(activitySource: .agent).matches(sessionId: "session-A", startedAt: started)
        )
    }
}

@Suite(.serialized)
@MainActor
struct GenerationOutputRelaySessionScopingTests {
    private static let asyncTimeout: Duration = .seconds(10)

    /// A foreign or utility completion arriving mid-step must leave the
    /// live turn streaming (typing indicator up, `outputComplete` false);
    /// the session's own completion must settle it.
    @Test
    func foreignCompletionsDoNotEndTheLiveTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.toolsDisabledForTestingOverride = true
            session.forceChatEngineRouteForTests = true
            session.selectedModel = "relay-scoping-test"
            let engine = GatedChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("hello")
            // Wait for the engine to have RECEIVED the request: `streamStartTime`
            // is captured right before `streamChat` is awaited, so everything
            // announced from here on is after it and can only be rejected by
            // the session scoping, never by the timestamp.
            try await waitUntilAsync(timeout: Self.asyncTimeout) { await engine.requestCount == 1 }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming && session.turns.last?.role == .assistant
                    && session.visibleBlocks.contains { block in
                        if case .typingIndicator = block.kind { return true }
                        return false
                    }
            }
            let ownSessionId = try #require(session.sessionId?.uuidString)
            #expect(!session.outputComplete)

            // Another chat's step, a utility job, and a subagent step finish
            // while this turn is still waiting on its model.
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: UUID().uuidString, activitySource: .chatUI, auxiliary: false
            )
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .chatUI, auxiliary: true
            )
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .agent, auxiliary: false
            )
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: nil, activitySource: .httpAPI, auxiliary: false
            )
            // Longer than the relay sink's quiet window (0.15 s) plus a margin.
            try await Task.sleep(for: .milliseconds(600))
            #expect(!session.outputComplete, "foreign completions must not end this session's step")
            #expect(session.isStreaming)
            #expect(
                session.visibleBlocks.contains { block in
                    if case .typingIndicator = block.kind { return true }
                    return false
                },
                "the typing indicator must stay up while this turn's model is still working"
            )

            // The session's own completion settles the step.
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .chatUI, auxiliary: false
            )
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }

            await engine.finish(with: "done")
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
            #expect(session.turns.last?.content == "done")
        }
    }
}

/// Holds the stream open (like a model still loading / prefilling) until
/// `finish(with:)` releases it.
private actor GatedChatEngine: ChatEngineProtocol {
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var requestCount = 0

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        requestCount += 1
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish(with text: String) {
        continuation?.yield(text)
        continuation?.finish()
        continuation = nil
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "GatedChatEngine", code: 1)
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
    throw NSError(domain: "GenerationOutputRelayScopingTests", code: 3)
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
    throw NSError(domain: "GenerationOutputRelayScopingTests", code: 4)
}
