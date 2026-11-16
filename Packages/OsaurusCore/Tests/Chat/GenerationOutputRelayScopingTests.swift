//
//  GenerationOutputRelayScopingTests.swift
//  OsaurusCoreTests
//
//  The relay's standalone identity matcher remains tested for its consumers.
//  Chat now settles only at its own ordered typed completion, so even a
//  same-session global announcement cannot outrun buffered output. Gated
//  typed streams cover completion, producer tail and Stop independently.
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
    /// live turn streaming (typing indicator up, `outputComplete` false).
    /// Only its ordered typed completion may settle it.
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
            // Give any obsolete relay-driven UI path time to fire.
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

            // Even an own-session global announcement can run ahead of
            // buffered typed deltas. It cannot settle this ordered stream.
            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .chatUI, auxiliary: false
            )
            try await Task.sleep(for: .milliseconds(250))
            #expect(!session.outputComplete)
            await engine.complete(with: "done")
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }
            #expect(session.turns.last?.content == "done")

            // Output complete but the stream (engine tail) is still open: the
            // run is live, so the turn must keep a progress row — now in the
            // `.finishing` phase — instead of rendering header-only.
            #expect(session.isStreaming)
            #expect(
                Self.typingPhases(in: session.visibleBlocks) == [.finishing],
                "the engine tail must be labelled, not blank"
            )

            await engine.finish()
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
            #expect(session.turns.last?.content == "done")
            // Run closed: no indicator of either phase remains.
            #expect(Self.typingPhases(in: session.visibleBlocks).isEmpty)
        }
    }

    /// Stop pressed while the engine tail is draining (output complete, run
    /// open, finishing indicator up): the indicator must clear with the run
    /// and the turn must finalize as cancelled — no lingering progress row.
    @Test
    func stopDuringEngineTailClearsFinishingIndicator() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.toolsDisabledForTestingOverride = true
            session.forceChatEngineRouteForTests = true
            session.selectedModel = "relay-scoping-test"
            let engine = GatedChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("hello")
            try await waitUntilAsync(timeout: Self.asyncTimeout) { await engine.requestCount == 1 }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming && session.turns.last?.role == .assistant
            }

            await engine.complete(with: "done")
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }
            #expect(Self.typingPhases(in: session.visibleBlocks) == [.finishing])

            session.stop()
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
            #expect(!session.isStreaming)
            #expect(Self.typingPhases(in: session.visibleBlocks).isEmpty)
            #expect(session.turns.last?.role == .assistant)
            #expect(session.turns.last?.terminalStopReason == "cancelled")

            // Release the gated engine so the harness does not leak the stream.
            await engine.finish()
        }
    }

    /// A name preview absent from the complete batch is not executable.
    /// Completion clears it and shows the real finishing phase; Stop during
    /// that producer tail still clears the row and records interruption.
    @Test("Typed completion clears an abandoned preview before producer drain")
    func stopDuringPendingToolTailRendersInterruptedNotice() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.toolsDisabledForTestingOverride = true
            session.forceChatEngineRouteForTests = true
            session.selectedModel = "relay-scoping-test"
            let engine = GatedChatEngine()
            session.chatEngineFactory = { _ in engine }

            session.send("inspect")
            try await waitUntilAsync(timeout: Self.asyncTimeout) { await engine.requestCount == 1 }
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.isStreaming && session.turns.last?.role == .assistant
            }

            await engine.yield(.functionNamePreview("osaurus_inspect"))
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.turns.last?.pendingToolName == "osaurus_inspect"
                    && Self.hasPendingToolChip(session.visibleBlocks)
            }

            await engine.complete()
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }
            #expect(!Self.hasPendingToolChip(session.visibleBlocks))
            #expect(Self.typingPhases(in: session.visibleBlocks) == [.finishing])

            session.stop()
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
            #expect(!session.isStreaming)
            let last = try #require(session.turns.last)
            #expect(last.role == .assistant)
            #expect(last.terminalStopReason == "cancelled")
            #expect(last.pendingToolName == nil)
            #expect(!Self.hasPendingToolChip(session.visibleBlocks))
            #expect(Self.typingPhases(in: session.visibleBlocks).isEmpty)
            #expect(
                session.visibleBlocks.contains { block in
                    if case let .paragraph(_, text, _, _) = block.kind {
                        return text.hasPrefix("Interrupted")
                    }
                    return false
                }
            )

            await engine.finish()
        }
    }

    private static func hasPendingToolChip(_ blocks: [ContentBlock]) -> Bool {
        blocks.contains { block in
            if case .pendingToolCall = block.kind { return true }
            return false
        }
    }

    private static func typingPhases(in blocks: [ContentBlock]) -> [TypingIndicatorPhase] {
        blocks.compactMap { block in
            guard case let .typingIndicator(phase) = block.kind else { return nil }
            return phase
        }
    }
}

/// Holds the typed stream open across logical completion and producer drain.
private actor GatedChatEngine: ChatEngineProtocol {
    private var continuation: AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation?
    private(set) var requestCount = 0

    func streamResponses(request _: ResponsesInferenceRequest) async throws
        -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
    {
        requestCount += 1
        let pair = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func yield(_ event: ResponsesGenerationEvent) { continuation?.yield(event) }

    func complete(with text: String = "") {
        if !text.isEmpty { continuation?.yield(.outputTextDelta(text)) }
        continuation?.yield(.responseCompleted(.init(
            responseID: "resp_visual_fixture", status: .completed, functionCalls: [],
            tokenCount: 3, tokensPerSecond: 30, unclosedReasoning: false,
            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil
        )))
    }

    func finish() {
        continuation?.yield(.drained)
        continuation?.finish()
        continuation = nil
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "unexpected-legacy-stream", code: 1)
    }
    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "unexpected-legacy-completion", code: 1)
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
