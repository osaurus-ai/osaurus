//
//  NotchAgentActionsTests.swift
//  osaurusTests
//
//  Lifecycle tests for the notch's agent-tab actions on
//  `BackgroundTaskManager`:
//
//  - `closeAgentTaskGroup(agentId:)` cancels every active task for the
//    agent and finalizes the whole group atomically. The agent's own
//    queued work must never briefly start mid-close (its deferred start
//    is dropped BEFORE cancellation can pump the queue), and other
//    agents' tasks are untouched.
//  - `submitQuickReply(_:text:)` routes a notch reply through the task's
//    retained `ChatSession.send` (the canonical answer channel): a
//    waiting task resumes from its clarify pause, a completed task is
//    revived off its auto-finalize timer, and non-replyable states /
//    empty text are rejected.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Helpers

@MainActor
private func makeTaskState(
    agentId: UUID,
    title: String,
    status: BackgroundTaskStatus = .running
) -> BackgroundTaskState {
    let id = UUID()
    let context = ExecutionContext(id: id, agentId: agentId)
    context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
    return BackgroundTaskState(
        id: id,
        taskTitle: title,
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status
    )
}

/// Records whether a queued task's deferred start closure ever ran.
@MainActor
private final class StartProbe {
    private(set) var started = false
    func makeStart() -> @MainActor () async -> Void {
        { self.started = true }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "NotchAgentActionsTests", code: 1)
}

// MARK: - Agent Group Close

@MainActor
struct NotchAgentGroupCloseTests {

    /// Isolated manager: these tests cancel/finalize whole agent groups,
    /// which must not touch tasks registered by concurrently-running
    /// suites on `.shared`.
    private let mgr = BackgroundTaskManager.makeForTesting()

    @Test func closeAgentGroup_cancelsActiveFinalizesAllAndSparesOtherAgents() async throws {
        let agent = UUID()
        let otherAgent = UUID()
        let running = makeTaskState(agentId: agent, title: "running")
        let waiting = makeTaskState(agentId: agent, title: "waiting", status: .waitingForInput)
        let done = makeTaskState(agentId: agent, title: "done", status: .completed(summary: "ok"))
        let bystander = makeTaskState(agentId: otherAgent, title: "bystander")
        [running, waiting, done, bystander].forEach { mgr.registerTaskForTesting($0) }
        defer { mgr.finalizeTask(bystander.id) }

        mgr.closeAgentTaskGroup(agentId: agent)

        // Active members went through the cancel path; terminal members
        // were finalized as-is.
        #expect(running.status == .cancelled)
        #expect(waiting.status == .cancelled)
        #expect(done.status == .completed(summary: "ok"))
        // The whole group left the registry atomically.
        #expect(mgr.taskState(for: running.id) == nil)
        #expect(mgr.taskState(for: waiting.id) == nil)
        #expect(mgr.taskState(for: done.id) == nil)
        // The other agent's task is untouched and still surfaced.
        #expect(bystander.status == .running)
        #expect(mgr.taskState(for: bystander.id) != nil)
        #expect(mgr.sortedToastTasks.contains { $0.id == bystander.id })
    }

    /// Closing a group must not briefly start the agent's own queued work:
    /// `cancelTask` pumps the queue after each cancellation, so if the
    /// deferred start were still registered, a freed slot would promote it
    /// mid-close.
    @Test func closeAgentGroup_droppedQueuedStartNeverRuns() async throws {
        let agent = UUID()
        // Saturate the per-agent cap so the next admission queues.
        let fillers = (0 ..< 5).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        #expect(queued.status == .queued)

        mgr.closeAgentTaskGroup(agentId: agent)

        // Everything is gone...
        for state in fillers + [queued] {
            #expect(mgr.taskState(for: state.id) == nil)
        }
        // ...and the queued start can't be resurrected by a later pump.
        mgr.pumpQueueForTesting()
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started == false)
    }

    @Test func closeAgentGroup_unknownAgentIsNoOp() async throws {
        let agent = UUID()
        let state = makeTaskState(agentId: agent, title: "keep")
        mgr.registerTaskForTesting(state)
        defer { mgr.finalizeTask(state.id) }

        mgr.closeAgentTaskGroup(agentId: UUID())

        #expect(mgr.taskState(for: state.id) != nil)
        #expect(state.status == .running)
    }
}

// MARK: - Quick Reply

@Suite(.serialized)
@MainActor
struct NotchQuickReplyTests {

    private let mgr = BackgroundTaskManager.makeForTesting()

    /// Build a registered + observed task whose session runs against the
    /// instant `MockChatEngine`, using the default agent so `send` resolves
    /// real agent settings under `ChatHistoryTestStorage`.
    private func makeObservedState() -> BackgroundTaskState {
        let state = makeTaskState(agentId: Agent.defaultId, title: "quick-reply-test")
        mgr.registerTaskForTesting(state)
        mgr.observeChatTask(state, session: state.chatSession!)
        return state
    }

    @Test func quickReply_waitingTask_answersClarifyThroughCanonicalSend() async throws {
        try await ChatHistoryTestStorage.run {
            let state = makeObservedState()
            defer { mgr.finalizeTask(state.id) }
            let session = try #require(state.chatSession)

            // Reach the clarify pause the same way production does: the
            // streaming observer sees the run, the clarify payload lands,
            // then the stream ends — the observer's clarify guard keeps
            // the task waiting instead of completing it.
            session.isStreaming = true
            session.awaitingClarify =
                ClarifyPayload(question: "Postgres or SQLite?", options: [], allowMultiple: false)
            session.isStreaming = false
            try await waitUntil { state.status == .waitingForInput }

            #expect(mgr.submitQuickReply(state.id, text: "Postgres") == true)

            // The reply dispatched as the next user turn through
            // `ChatSession.send`, clearing the clarify pause.
            try await waitUntil {
                session.turns.contains { $0.role == .user && $0.content == "Postgres" }
            }
            try await waitUntil { session.awaitingClarify == nil }
        }
    }

    @Test func quickReply_completedTask_cancelsAutoFinalizeAndStartsFollowUp() async throws {
        try await ChatHistoryTestStorage.run {
            let state = makeObservedState()
            defer { mgr.finalizeTask(state.id) }
            let session = try #require(state.chatSession)

            // Natural completion schedules the 15s terminal cleanup.
            session.isStreaming = true
            try await waitUntil { state.status == .running }
            session.isStreaming = false
            try await waitUntil { state.status == .completed(summary: "Chat completed") }
            #expect(mgr.hasPendingAutoFinalizeForTesting(state.id))

            #expect(mgr.submitQuickReply(state.id, text: "One more thing") == true)

            // The follow-up revived the task before resource cleanup and
            // landed as a user turn in the same session.
            #expect(mgr.hasPendingAutoFinalizeForTesting(state.id) == false)
            try await waitUntil {
                session.turns.contains { $0.role == .user && $0.content == "One more thing" }
            }
        }
    }

    @Test func completedTab_dehydratesWithContextAndRehydratesOnReply() async throws {
        try await ChatHistoryTestStorage.run {
            let state = makeTaskState(
                agentId: Agent.defaultId,
                title: "Architecture follow-up",
                status: .completed(summary: "Chat completed")
            )
            let originalSession = try #require(state.chatSession)
            originalSession.turns = [
                ChatTurn(role: .user, content: "Should this cache survive relaunch?"),
                ChatTurn(role: .assistant, content: "Yes. Persist metadata and hydrate the transcript on demand."),
            ]
            originalSession.save()
            mgr.registerTaskForTesting(state)
            defer { mgr.finalizeTask(state.id) }

            mgr.dehydrateTaskForTesting(state.id)

            #expect(mgr.taskState(for: state.id) != nil, "terminal tab stays visible")
            #expect(mgr.isTaskDehydratedForTesting(state.id))
            #expect(
                state.contextPreview.map(\.content) == [
                    "Should this cache survive relaunch?",
                    "Yes. Persist metadata and hydrate the transcript on demand.",
                ]
            )

            #expect(mgr.submitQuickReply(state.id, text: "Implement that approach") == true)
            try await waitUntil {
                state.chatSession?.turns.contains {
                    $0.role == .user && $0.content == "Implement that approach"
                } == true
            }
            #expect(mgr.isTaskDehydratedForTesting(state.id) == false)
        }
    }

    @Test func renameTask_updatesLiveAndRetainedConversationTitle() async throws {
        try await ChatHistoryTestStorage.run {
            let state = makeTaskState(
                agentId: Agent.defaultId,
                title: "Original",
                status: .completed(summary: "Chat completed")
            )
            let session = try #require(state.chatSession)
            session.turns = [ChatTurn(role: .user, content: "Keep this conversation")]
            session.save()
            mgr.registerTaskForTesting(state)
            defer { mgr.finalizeTask(state.id) }

            #expect(mgr.renameTask(state.id, title: "Durable Tabs"))
            #expect(state.taskTitle == "Durable Tabs")
            #expect(session.title == "Durable Tabs")
            #expect(ChatSessionStore.load(id: state.id)?.title == "Durable Tabs")

            mgr.dehydrateTaskForTesting(state.id)
            #expect(mgr.renameTask(state.id, title: "Pinned Work"))
            #expect(state.taskTitle == "Pinned Work")
            #expect(ChatSessionStore.load(id: state.id)?.title == "Pinned Work")
        }
    }

    @Test func retainedTabs_restoreAcrossManagerRelaunchWithoutLiveSession() async throws {
        try await ChatHistoryTestStorage.run {
            let suiteName = "NotchAgentActionsTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let firstManager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            let state = makeTaskState(
                agentId: Agent.defaultId,
                title: "Keep across restart",
                status: .completed(summary: "Chat completed")
            )
            let session = try #require(state.chatSession)
            session.turns = [
                ChatTurn(role: .user, content: "What did we decide?"),
                ChatTurn(role: .assistant, content: "Keep tabs until explicitly closed."),
            ]
            session.save()
            state.captureContextPreview()
            firstManager.registerTaskForTesting(state)
            firstManager.dehydrateTaskForTesting(state.id)

            // A fresh manager simulates the next app launch. It restores only
            // lightweight metadata; transcript hydration stays demand-driven.
            let relaunchedManager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            let restored = try #require(relaunchedManager.taskState(for: state.id))
            #expect(restored.taskTitle == "Keep across restart")
            #expect(restored.status == .completed(summary: "Chat completed"))
            #expect(restored.contextPreview.count == 2)
            #expect(relaunchedManager.isTaskDehydratedForTesting(state.id))

            relaunchedManager.finalizeTask(state.id)
            #expect(relaunchedManager.taskState(for: state.id) == nil)
        }
    }

    @Test func quickReply_rejectsNonReplyableStatesEmptyTextAndUnknownIds() async throws {
        try await ChatHistoryTestStorage.run {
            let running = makeTaskState(agentId: Agent.defaultId, title: "running")
            let queued = makeTaskState(agentId: Agent.defaultId, title: "queued", status: .queued)
            let failed = makeTaskState(
                agentId: Agent.defaultId,
                title: "failed",
                status: .failed(summary: "boom")
            )
            let cancelled = makeTaskState(
                agentId: Agent.defaultId,
                title: "cancelled",
                status: .cancelled
            )
            let waiting = makeTaskState(
                agentId: Agent.defaultId,
                title: "waiting",
                status: .waitingForInput
            )
            let all = [running, queued, failed, cancelled, waiting]
            all.forEach { mgr.registerTaskForTesting($0) }
            defer { all.forEach { mgr.finalizeTask($0.id) } }

            // Running / queued work takes input via the chat window;
            // failed / cancelled runs are view-only.
            #expect(mgr.submitQuickReply(running.id, text: "hi") == false)
            #expect(mgr.submitQuickReply(queued.id, text: "hi") == false)
            #expect(mgr.submitQuickReply(failed.id, text: "hi") == false)
            #expect(mgr.submitQuickReply(cancelled.id, text: "hi") == false)
            // Whitespace-only replies and unknown tasks are rejected too.
            #expect(mgr.submitQuickReply(waiting.id, text: "   ") == false)
            #expect(mgr.submitQuickReply(UUID(), text: "hi") == false)
            // No send was dispatched by the rejected calls.
            #expect(running.chatSession?.turns.isEmpty == true)
            #expect(waiting.chatSession?.turns.isEmpty == true)
        }
    }
}
