//
//  BackgroundTaskInterruptTests.swift
//  osaurusTests
//
//  Tests for `BackgroundTaskManager.interruptTask(_:message:)` semantics.
//  Plugins call `dispatch_interrupt(task_id, message)` and expect that a
//  non-empty message lands as a user-role turn before the stream is
//  cancelled. An empty / whitespace-only message just soft-stops without
//  injecting anything.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct BackgroundTaskInterruptTests {

    private func makeRunningState() -> (state: BackgroundTaskState, mgr: BackgroundTaskManager) {
        let context = ExecutionContext(agentId: Agent.defaultId)
        context.chatSession.chatEngineFactory = { MockChatEngine() }
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "interrupt-test",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running..."
        )
        let mgr = BackgroundTaskManager.shared
        mgr.registerTaskForTesting(state)
        mgr.observeChatTask(state, session: context.chatSession)
        // Force the streaming-observed flag so the observer doesn't trip the
        // initial-emission guard when we flip isStreaming.
        state.chatSession?.isStreaming = true
        return (state, mgr)
    }

    @Test
    func interrupt_withNonEmptyMessage_appendsUserTurnBeforeStop() async throws {
        let (state, mgr) = makeRunningState()
        defer { mgr.finalizeTask(state.id) }

        let priorTurnCount = state.chatSession?.turns.count ?? -1
        mgr.interruptTask(state.id, message: "stop and try plan B instead")
        // interruptTask is synchronous; the user turn should be present
        // immediately and the stream-stop is queued.
        try await Task.sleep(for: .milliseconds(10))

        let turns = state.chatSession?.turns ?? []
        #expect(turns.count == priorTurnCount + 1)
        #expect(turns.last?.role == .user)
        #expect(turns.last?.content == "stop and try plan B instead")
    }

    @Test
    func interrupt_trimsWhitespace() async throws {
        let (state, mgr) = makeRunningState()
        defer { mgr.finalizeTask(state.id) }

        mgr.interruptTask(state.id, message: "  hello  ")
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.chatSession?.turns.last?.content == "hello")
    }

    @Test
    func interrupt_withNilMessage_doesNotAppendTurn() async throws {
        let (state, mgr) = makeRunningState()
        defer { mgr.finalizeTask(state.id) }

        let priorTurnCount = state.chatSession?.turns.count ?? -1
        mgr.interruptTask(state.id, message: nil)
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.chatSession?.turns.count == priorTurnCount)
    }

    @Test
    func interrupt_withEmptyMessage_doesNotAppendTurn() async throws {
        let (state, mgr) = makeRunningState()
        defer { mgr.finalizeTask(state.id) }

        let priorTurnCount = state.chatSession?.turns.count ?? -1
        mgr.interruptTask(state.id, message: "   ")
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.chatSession?.turns.count == priorTurnCount)
    }
}
