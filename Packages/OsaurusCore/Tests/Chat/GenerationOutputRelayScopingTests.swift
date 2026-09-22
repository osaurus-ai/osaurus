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

            // Output complete but the stream (engine tail) is still open: the
            // run is live, so the turn must keep a progress row — now in the
            // `.finishing` phase — instead of rendering header-only.
            #expect(session.isStreaming)
            #expect(
                Self.typingPhases(in: session.visibleBlocks) == [.finishing],
                "the engine tail must be labelled, not blank"
            )

            await engine.finish(with: "done")
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
            let ownSessionId = try #require(session.sessionId?.uuidString)

            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .chatUI, auxiliary: false
            )
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }
            #expect(Self.typingPhases(in: session.visibleBlocks) == [.finishing])

            session.stop()
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
            #expect(!session.isStreaming)
            #expect(Self.typingPhases(in: session.visibleBlocks).isEmpty)
            #expect(session.turns.last?.role == .assistant)
            #expect(session.turns.last?.terminalStopReason == "cancelled")

            // Release the gated engine so the harness does not leak the stream.
            await engine.finish(with: "")
        }
    }

    /// Stop while a local tool step sits on the engine tail: the model has
    /// named the tool (pending chip up), output is complete, but the parsed
    /// invocation is still withheld. The chip must go with the run AND the
    /// cancelled turn must render its "Interrupted" record — the ephemeral
    /// `pendingToolName` used to survive the stop and suppress that notice,
    /// leaving a header-only row until a reload.
    @Test("Stop during a pending-tool engine tail clears the chip and renders the cancelled record")
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
            let ownSessionId = try #require(session.sessionId?.uuidString)

            await engine.yield(StreamingToolHint.encode("osaurus_inspect"))
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.turns.last?.pendingToolName == "osaurus_inspect"
                    && Self.hasPendingToolChip(session.visibleBlocks)
            }

            GenerationOutputRelay.shared.announce(
                modelName: "local/model", generationTokens: 3,
                sessionId: ownSessionId, activitySource: .chatUI, auxiliary: false
            )
            try await waitUntil(timeout: Self.asyncTimeout) { session.outputComplete }
            // The chip owns the tail for a tool step — no finishing row on top.
            #expect(Self.hasPendingToolChip(session.visibleBlocks))
            #expect(Self.typingPhases(in: session.visibleBlocks).isEmpty)

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

            await engine.finish(with: "")
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

    /// Push one delta while keeping the stream open.
    func yield(_ text: String) {
        continuation?.yield(text)
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
