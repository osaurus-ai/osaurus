//
//  BackgroundTaskStreamingObserverTests.swift
//  osaurusTests
//
//  Regression tests for `BackgroundTaskManager.observeChatTask`.
//  `Publishers.CombineLatest(session.$isStreaming, session.$lastStreamError)`
//  delivers an initial `(false, nil)` tuple synchronously on subscribe;
//  without the `streamingObserved` guard the observer would call
//  `markCompleted` immediately and ship a premature `.completed` event
//  with no `output` to the originating plugin / first task poll.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct BackgroundTaskStreamingObserverTests {

    // MARK: - Helpers

    /// Build a registered, observed task. Cleanup is handled by the caller's
    /// `defer { mgr.finalizeTask(state.id) }`.
    private func makeObservedState() -> (state: BackgroundTaskState, mgr: BackgroundTaskManager) {
        let context = ExecutionContext(agentId: Agent.defaultId)
        // Mock engine yields nothing — guarantees `isStreaming` only changes
        // when the test sets it explicitly, so we control the timeline.
        context.chatSession.chatEngineFactory = { MockChatEngine() }

        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "regression-test",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running..."
        )

        let mgr = BackgroundTaskManager.shared
        mgr.registerTaskForTesting(state)
        mgr.observeChatTask(state, session: context.chatSession)
        return (state, mgr)
    }

    // MARK: - Tests

    /// Subscribing must NOT synchronously fire `markCompleted`, even though
    /// CombineLatest delivers `(isStreaming: false, lastStreamError: nil)`
    /// the instant the sink attaches.
    @Test
    func observeChatTask_doesNotMarkCompletedOnInitialSynchronousEmission() {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        #expect(state.status == .running)
    }

    /// Once `isStreaming` actually flips `true` and back to `false`, the
    /// observer DOES mark the task completed. Guards against an over-broad
    /// fix that would silently break the real terminal-state path.
    @Test
    func observeChatTask_marksCompletedAfterStreamingStartsAndStops() async throws {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.status == .completed(success: true, summary: "Chat completed"))
    }

    /// A stream error before completion must transition the task to
    /// `.completed(success: false, summary: <error>)`.
    @Test
    func observeChatTask_marksFailedWhenStreamErrorPresent() async throws {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.lastStreamError = "boom"
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.status == .completed(success: false, summary: "boom"))
    }
}
