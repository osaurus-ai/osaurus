//
//  InboundSharedRunBridgeTests.swift
//  osaurusTests
//
//  Host-side presence for a remote caller (workspace teammate or invite-link
//  peer) driving one of this instance's shared agents: `begin` hosts the run
//  as a real session-backed task — history row saved at once, `.workspace`
//  origin, caller-tagged, tab-worthy and `taskRegistered` — step/tool hooks
//  drive its current step + activity feed, `appendMessages` mirrors the
//  host's turns into the transcript, `finish` leaves a retained terminal
//  row, Stop (via `BackgroundTaskManager.cancelTask`) trips the interrupt
//  token and the stop closure so the SSE run really ends, and a follow-up
//  run on the same conversation reuses the same row / task.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct InboundSharedRunBridgeTests {

    private final class StopProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
        func fire() {
            lock.lock()
            _count += 1
            lock.unlock()
        }
    }

    private func makeBridge() -> (InboundSharedRunBridge, BackgroundTaskManager, SessionActivityMonitor) {
        let manager = BackgroundTaskManager.makeForTesting()
        let monitor = SessionActivityMonitor()
        return (InboundSharedRunBridge(manager: manager, monitor: monitor), manager, monitor)
    }

    private func makeAgent(_ name: String) -> Agent {
        let agent = Agent(name: name)
        AgentManager.shared.add(agent)
        return agent
    }

    private func workspaceContext(caller: String = "Alice", wallet: String = "0xcaller") -> WorkspaceSessionContext {
        WorkspaceSessionContext(
            workspaceId: "ws-acme",
            agentAddress: "0xshared",
            callerWallet: wallet,
            callerName: caller
        )
    }

    private func directShareContext() -> WorkspaceSessionContext {
        WorkspaceSessionContext(
            workspaceId: "",
            agentAddress: "0xshared",
            callerWallet: "key-nonce-1",
            callerName: "Bob's laptop"
        )
    }

    private var request: [ChatMessage] {
        [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "Summarize the roadmap"),
        ]
    }

    private func key(_ ctx: WorkspaceSessionContext, _ sessionId: String) -> String {
        "\((ctx.callerWallet ?? "").lowercased()):\(sessionId)"
    }

    // MARK: - begin

    @Test func begin_hostsSessionBackedTaskAndSavesHistoryRowAtOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, monitor) = makeBridge()
            let agent = makeAgent("Research Agent")
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            var registered: [UUID] = []
            let sub = manager.taskRegistered.sink { registered.append($0.id) }
            defer { sub.cancel() }
            let probe = StopProbe()
            let runKey = "run-\(UUID().uuidString)"
            let ctx = workspaceContext()

            let handle = bridge.begin(
                runKey: runKey,
                agentId: agent.id,
                context: ctx,
                externalKey: key(ctx, "convo-1"),
                requestMessages: request,
                stop: { probe.fire() }
            )
            defer {
                bridge.finish(handle, success: true, summary: "Completed")
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }

            #expect(bridge.liveCount == 1)
            #expect(bridge.isLive(runKey: runKey))
            let state = try #require(manager.backgroundTasks[handle.taskId])
            #expect(state.isInboundRun)
            #expect(!state.isSubagentMirror, "a real session-backed task, not a visibility mirror")
            #expect(state.agentId == agent.id)
            #expect(state.source == .workspace)
            #expect(state.externalSessionKey == "Alice")
            #expect(state.status == .running)
            #expect(state.taskTitle == "Alice → Research Agent")
            #expect(state.currentStep == "Starting…")
            #expect(registered == [state.id], "chat windows are told to open it as a tab of the agent")
            #expect(manager.tasksForTabs().map(\.id).contains(state.id))
            #expect(manager.liveTask(forSessionId: handle.taskId) === state)
            #expect(monitor.status(for: handle.taskId) == .working, "the tab ring + agent row spin")

            // Session mirrors the caller's request (system prompt dropped) and
            // the row is already in History under the shared agent.
            let session = try #require(state.chatSession)
            #expect(session.sessionId == handle.taskId, "session id == task id so retained-tab hydration resolves")
            #expect(session.turns.map(\.role) == [.user])
            #expect(session.turns.first?.content == "Summarize the roadmap")
            #expect(session.workspaceContext == ctx)
            #expect(session.source == .workspace)
            let row = try #require(ChatSessionsManager.shared.sessions.first { $0.id == handle.taskId })
            #expect(row.agentId == agent.id)
            #expect(row.title == "Alice → Research Agent")
            #expect(row.sourcePluginId == ChatHistoryWriter.workspacePseudoPluginId)
            #expect(row.externalSessionKey == key(ctx, "convo-1"))
            #expect(row.workspace?.isServedForTeammate == true)
            #expect(row.isWorkspaceAgentChat == false, "host copy is not a teammate-agent chat")
            #expect(ChatSessionsManager.shared.sessions(for: agent.id).contains { $0.id == handle.taskId })
            #expect(probe.count == 0)
        }
    }

    @Test func begin_directShareCaller_isHostedWithSharedLabel() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let agent = makeAgent("Ops Helper")
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let ctx = directShareContext()

            let handle = bridge.begin(
                runKey: "run-\(UUID().uuidString)",
                agentId: agent.id,
                context: ctx,
                externalKey: key(ctx, "s1"),
                requestMessages: request,
                stop: {}
            )
            defer {
                bridge.finish(handle, success: true, summary: "Completed")
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }

            let state = try #require(manager.backgroundTasks[handle.taskId])
            #expect(state.taskTitle == "Bob's laptop → Ops Helper")
            #expect(state.externalSessionKey == "Bob's laptop")
            let row = try #require(ChatSessionsManager.shared.sessions.first { $0.id == handle.taskId })
            #expect(row.workspace?.isDirectShare == true)
            #expect(row.source.originLabel(workspace: row.workspace) == "for Bob's laptop · Shared")
            #expect(
                SessionSource.workspace.originLabel(workspace: workspaceContext()) == "for Alice · Workspace"
            )
        }
    }

    // MARK: - hooks

    @Test func stepToolAndMessageHooks_driveStepFeedAndTranscript() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let ctx = workspaceContext()
            let handle = bridge.begin(
                runKey: "run-\(UUID().uuidString)",
                agentId: UUID(),
                context: ctx,
                externalKey: key(ctx, "s2"),
                requestMessages: request,
                stop: {}
            )
            defer {
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }
            let state = try #require(manager.backgroundTasks[handle.taskId])
            let session = try #require(state.chatSession)

            bridge.step(handle, "Thinking…")
            #expect(state.currentStep == "Thinking…")

            bridge.toolStarted(handle, toolName: "read_file")
            let runningLabel = ToolDisplayName.friendly(for: "read_file", running: true)
            #expect(state.currentStep == runningLabel)
            #expect(state.activityFeed.last?.kind == .tool)
            #expect(state.activityFeed.last?.title == runningLabel)

            bridge.toolFinished(handle, toolName: "read_file", isError: false)
            #expect(state.activityFeed.last?.kind == .success)
            #expect(state.currentStep == "Thinking…", "after a tool the row returns to the model step")

            bridge.toolFinished(handle, toolName: "web_fetch", isError: true)
            #expect(state.activityFeed.last?.kind == .error)

            // The host's step lands in the transcript and is persisted.
            let call = ToolCall(
                id: "call-1",
                type: "function",
                function: ToolCallFunction(name: "read_file", arguments: "{\"path\":\"a.md\"}")
            )
            bridge.appendMessages(
                handle,
                [
                    ChatMessage(role: "assistant", content: nil, tool_calls: [call], tool_call_id: nil),
                    ChatMessage(role: "tool", content: "# a", tool_calls: nil, tool_call_id: "call-1"),
                ]
            )
            bridge.appendMessages(handle, [ChatMessage(role: "assistant", content: "Here is the summary.")])
            #expect(session.turns.map(\.role) == [.user, .assistant, .tool, .assistant])
            #expect(session.turns[1].toolCalls?.first?.function.name == "read_file")
            #expect(session.turns[2].toolCallId == "call-1")
            #expect(session.turns.last?.content == "Here is the summary.")
            let stored = try #require(ChatSessionStore.load(id: handle.taskId))
            #expect(stored.turns.count == 4)
            #expect(stored.turns.last?.content == "Here is the summary.")

            bridge.finish(handle, success: true, summary: "Completed")
            // Late hooks after finish are ignored.
            bridge.appendMessages(handle, [ChatMessage(role: "assistant", content: "late")])
            #expect(session.turns.count == 4)
        }
    }

    // MARK: - finish

    @Test func finish_goesTerminalRetainsRowClearsRingAndIsIdempotent() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, monitor) = makeBridge()
            let ctx = workspaceContext()
            let runKey = "run-\(UUID().uuidString)"
            let handle = bridge.begin(
                runKey: runKey,
                agentId: UUID(),
                context: ctx,
                externalKey: key(ctx, "s3"),
                requestMessages: request,
                stop: {}
            )
            defer {
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }
            let state = try #require(manager.backgroundTasks[handle.taskId])
            bridge.appendMessages(handle, [ChatMessage(role: "assistant", content: "done")])

            bridge.finish(handle, success: true, summary: "Completed")

            #expect(state.status == .completed(summary: "Completed"))
            #expect(state.currentStep == nil)
            #expect(bridge.liveCount == 0)
            #expect(!bridge.isLive(runKey: runKey))
            #expect(monitor.status(for: handle.taskId) == nil, "ring clears once the run ends")
            #expect(manager.tasksForTabs().map(\.id).contains(state.id), "finished runs stay as tabs until dismissed")
            #expect(!state.contextPreview.isEmpty, "preview captured for the retained tab")
            #expect(
                manager.hasPendingAutoFinalizeForTesting(state.id),
                "terminal cleanup dehydrates, never drops, the tab"
            )

            // After terminal cleanup the tab survives as a lightweight record
            // that still reads as an inbound run, and its transcript is on disk.
            manager.dehydrateTaskForTesting(state.id)
            #expect(manager.isTaskDehydratedForTesting(state.id))
            #expect(state.isInboundRun)
            #expect(manager.tasksForTabs().map(\.id).contains(state.id))
            #expect(ChatSessionStore.load(id: handle.taskId)?.turns.last?.content == "done")

            // Late hooks after finish are ignored; a second finish is a no-op.
            bridge.step(handle, "late")
            #expect(state.currentStep == nil)
            bridge.finish(handle, success: false, summary: "again")
            #expect(state.status == .completed(summary: "Completed"))
        }
    }

    // MARK: - multi-turn

    @Test func secondRunOnSameConversation_reusesRowAndTask() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, monitor) = makeBridge()
            let agent = makeAgent("Research Agent")
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let ctx = workspaceContext()
            let externalKey = key(ctx, "convo-multi")

            let first = bridge.begin(
                runKey: "a-\(UUID())",
                agentId: agent.id,
                context: ctx,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            defer {
                manager.finalizeTask(first.taskId)
                ChatSessionsManager.shared.delete(id: first.taskId)
            }
            bridge.appendMessages(first, [ChatMessage(role: "assistant", content: "hi there")])
            bridge.finish(first, success: true, summary: "Completed")
            let state = try #require(manager.backgroundTasks[first.taskId])
            #expect(state.status == .completed(summary: "Completed"))

            // The caller's next request carries the whole conversation.
            let secondRequest =
                request + [
                    ChatMessage(role: "assistant", content: "hi there"),
                    ChatMessage(role: "user", content: "and now?"),
                ]
            let second = bridge.begin(
                runKey: "b-\(UUID())",
                agentId: agent.id,
                context: ctx,
                externalKey: externalKey,
                requestMessages: secondRequest,
                stop: {}
            )
            #expect(second.taskId == first.taskId, "same caller + session_id → same row, task and tab")
            #expect(state.status == .running, "the retained tab is revived, not duplicated")
            #expect(monitor.status(for: first.taskId) == .working)
            let session = try #require(state.chatSession)
            #expect(session.turns.map(\.content) == ["Summarize the roadmap", "hi there", "and now?"])

            bridge.appendMessages(second, [ChatMessage(role: "assistant", content: "still here")])
            bridge.finish(second, success: true, summary: "Completed")
            #expect(session.turns.count == 4)
            let rows = ChatSessionsManager.shared.sessions.filter { $0.externalSessionKey == externalKey }
            #expect(rows.count == 1)
            #expect(ChatSessionStore.load(id: first.taskId)?.turns.count == 4)
        }
    }

    @Test func secondRunAfterTabDismissed_reattachesToTheHistoryRow() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let ctx = workspaceContext()
            let externalKey = key(ctx, "convo-dismissed")

            let first = bridge.begin(
                runKey: "a-\(UUID())",
                agentId: UUID(),
                context: ctx,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            bridge.appendMessages(first, [ChatMessage(role: "assistant", content: "hi there")])
            bridge.finish(first, success: true, summary: "Completed")
            // User closed the finished tab → task leaves the registry, the
            // History row stays.
            manager.finalizeTask(first.taskId)
            #expect(manager.backgroundTasks[first.taskId] == nil)

            let second = bridge.begin(
                runKey: "b-\(UUID())",
                agentId: UUID(),  // different agent id → different conversation
                context: ctx,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            defer {
                bridge.finish(second, success: true, summary: "Completed")
                manager.finalizeTask(second.taskId)
                ChatSessionsManager.shared.delete(id: first.taskId)
                ChatSessionsManager.shared.delete(id: second.taskId)
            }
            #expect(second.taskId != first.taskId, "rows are keyed per agent")

            let agentId = try #require(ChatSessionsManager.shared.sessions.first { $0.id == first.taskId }?.agentId)
            let third = bridge.begin(
                runKey: "c-\(UUID())",
                agentId: agentId,
                context: ctx,
                externalKey: externalKey,
                requestMessages: request + [
                    ChatMessage(role: "assistant", content: "hi there"), ChatMessage(role: "user", content: "continue"),
                ],
                stop: {}
            )
            defer {
                bridge.finish(third, success: true, summary: "Completed")
                manager.finalizeTask(third.taskId)
            }
            #expect(third.taskId == first.taskId, "a dismissed conversation is reattached, not duplicated")
            #expect(manager.backgroundTasks[first.taskId]?.status == .running)
        }
    }

    @Test func partialOutputSurvivesFailureAndConcurrentOrEditedRequestsCannotOverwriteIt() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let agentId = UUID()
            let ctx = workspaceContext()
            let externalKey = key(ctx, "immutable")
            var handles: [InboundSharedRunBridge.Handle] = []
            defer {
                for h in handles {
                    bridge.finish(h, success: false, summary: "Test end")
                    manager.finalizeTask(h.taskId)
                    ChatSessionsManager.shared.delete(id: h.taskId)
                }
            }
            let first = bridge.begin(
                runKey: "first",
                agentId: agentId,
                context: ctx,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            handles.append(first)
            bridge.streamDelta(first, reasoning: "Checking the roadmap")
            bridge.streamDelta(first, content: "Partial answer")
            let concurrent = bridge.begin(
                runKey: "concurrent",
                agentId: agentId,
                context: ctx,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            handles.append(concurrent)
            #expect(first.taskId != concurrent.taskId)
            bridge.finish(first, success: false, summary: "Connection lost")
            let stored = try #require(ChatSessionStore.load(id: first.taskId))
            #expect(stored.turns.last?.content == "Partial answer")
            #expect(stored.turns.last?.thinking == "Checking the roadmap")
            let edited = bridge.begin(
                runKey: "edited",
                agentId: agentId,
                context: ctx,
                externalKey: externalKey,
                requestMessages: [ChatMessage(role: "user", content: "rewritten")],
                stop: {}
            )
            handles.append(edited)
            #expect(edited.taskId != first.taskId)
            #expect(ChatSessionStore.load(id: first.taskId)?.turns.last?.content == "Partial answer")
            let other = WorkspaceSessionContext(
                workspaceId: "other",
                agentAddress: ctx.agentAddress,
                callerWallet: ctx.callerWallet,
                callerName: ctx.callerName
            )
            let crossWorkspace = bridge.begin(
                runKey: "other",
                agentId: agentId,
                context: other,
                externalKey: externalKey,
                requestMessages: request,
                stop: {}
            )
            handles.append(crossWorkspace)
            #expect(crossWorkspace.taskId != first.taskId && crossWorkspace.taskId != concurrent.taskId)
        }
    }

    @Test func streamedCompletionKeepsOneAssistantTurnAndReasoning() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let ctx = workspaceContext()
            let h = bridge.begin(
                runKey: "stream",
                agentId: UUID(),
                context: ctx,
                externalKey: key(ctx, "stream"),
                requestMessages: request,
                stop: {}
            )
            defer { manager.finalizeTask(h.taskId); ChatSessionsManager.shared.delete(id: h.taskId) }
            bridge.streamDelta(h, reasoning: "Reasoning")
            bridge.streamDelta(h, content: "Hello")
            bridge.appendMessages(h, [ChatMessage(role: "assistant", content: "Hello")])
            bridge.finish(h, success: true, summary: "Completed")
            let stored = try #require(ChatSessionStore.load(id: h.taskId))
            #expect(stored.turns.count == 2)
            #expect(stored.turns.last?.content == "Hello")
            #expect(stored.turns.last?.thinking == "Reasoning")
        }
    }

    // MARK: - stop

    @Test func cancelTaskOnManager_routesStopThroughSharedBridge() async throws {
        try await ChatHistoryTestStorage.run {
            // The tab notice / sidebar Stop call `BackgroundTaskManager.cancelTask`;
            // for inbound runs that must reach the shared bridge so the host
            // ends the run instead of only flipping the row.
            let bridge = InboundSharedRunBridge.shared
            let manager = BackgroundTaskManager.shared
            let probe = StopProbe()
            let ctx = workspaceContext()
            let handle = bridge.begin(
                runKey: "run-\(UUID().uuidString)",
                agentId: UUID(),
                context: ctx,
                externalKey: key(ctx, "s-stop"),
                requestMessages: request,
                stop: { probe.fire() }
            )
            let state = try #require(manager.backgroundTasks[handle.taskId])
            defer {
                bridge.finish(handle, success: false, summary: "Stopped")
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }
            #expect(handle.token.isInterrupted == false)

            manager.cancelTask(handle.taskId)

            #expect(state.status == .cancelled)
            #expect(state.activityFeed.last?.title == "Stopped")
            #expect(handle.token.isInterrupted, "the agent loop's isCancelled hook observes the token")
            #expect(probe.count == 1, "the host closes the SSE channel")
            #expect(SessionActivityMonitor.shared.status(for: handle.taskId) == nil, "ring clears at once")
            // The run stays live until the handler's terminal `finish` lands,
            // which is then a no-op on the already-cancelled row.
            #expect(bridge.isLive(runKey: handle.runKey))
            bridge.finish(handle, success: false, summary: "Stopped")
            #expect(state.status == .cancelled)
            #expect(!bridge.isLive(runKey: handle.runKey))
            #expect(manager.tasksForTabs().map(\.id).contains(state.id), "a stopped run stays as a tab until dismissed")
        }
    }

    @Test func stopRequestedByRunKey_tripsTokenAndStopClosure() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, monitor) = makeBridge()
            let probe = StopProbe()
            let ctx = workspaceContext()
            let runKey = "run-\(UUID().uuidString)"
            let handle = bridge.begin(
                runKey: runKey,
                agentId: UUID(),
                context: ctx,
                externalKey: key(ctx, "s-stop2"),
                requestMessages: request,
                stop: { probe.fire() }
            )
            defer {
                manager.finalizeTask(handle.taskId)
                ChatSessionsManager.shared.delete(id: handle.taskId)
            }

            bridge.stopRequested(runKey: runKey)
            #expect(handle.token.isInterrupted)
            #expect(probe.count == 1)
            #expect(monitor.status(for: handle.taskId) == nil)
            #expect(bridge.isLive(runKey: runKey))
            bridge.finish(handle, success: false, summary: "Stopped")
            #expect(!bridge.isLive(runKey: runKey))
            #expect(manager.backgroundTasks[handle.taskId]?.status == .failed(summary: "Stopped"))

            // Unknown keys are ignored.
            bridge.stopRequested(runKey: "nope")
            #expect(probe.count == 1)
        }
    }

    // MARK: - slot accounting / read-only

    @Test func inboundRun_doesNotHoldADispatchSlotAndIsNotReplyable() async throws {
        try await ChatHistoryTestStorage.run {
            let (bridge, manager, _) = makeBridge()
            let agentId = UUID()
            // More concurrent hosted runs than the per-agent dispatch cap (5):
            // admission is the HTTP inference gate's job, so none of them
            // holds a dispatch slot.
            var handles: [InboundSharedRunBridge.Handle] = []
            for i in 0 ..< 6 {
                let ctx = workspaceContext(caller: "Caller \(i)", wallet: "0xc\(i)")
                handles.append(
                    bridge.begin(
                        runKey: "run-\(UUID().uuidString)",
                        agentId: agentId,
                        context: ctx,
                        externalKey: key(ctx, "s-slot-\(i)"),
                        requestMessages: request,
                        stop: {}
                    )
                )
            }
            defer {
                for handle in handles {
                    bridge.finish(handle, success: true, summary: "Completed")
                    manager.finalizeTask(handle.taskId)
                    ChatSessionsManager.shared.delete(id: handle.taskId)
                }
            }
            #expect(bridge.liveCount == 6)
            #expect(Set(handles.map(\.taskId)).count == 6, "each caller conversation is its own row")
            #expect(
                manager.hasExecutionCapacityForTesting(agentId: agentId),
                "hosted runs never consume dispatch slots"
            )
            #expect(
                !manager.submitQuickReply(handles[0].taskId, text: "hello"),
                "the caller's conversation is read-only here"
            )
        }
    }

    // MARK: - outcome

    @Test func outcome_defaultsToStoppedAndRecordsExitsAndErrors() {
        let outcome = InboundSharedRun.Outcome()
        #expect(outcome.success == false)
        #expect(outcome.summary == "Stopped")

        outcome.record(exit: .finalResponse, cancelled: false)
        #expect(outcome.success)
        #expect(outcome.summary == "Completed")

        outcome.record(exit: .finalResponse, cancelled: true)
        #expect(outcome.success == false)
        #expect(outcome.summary == "Stopped")

        outcome.record(exit: .overBudget, cancelled: false)
        #expect(outcome.summary == "Context window exceeded")

        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        outcome.record(error: Boom(), cancelled: false)
        #expect(outcome.success == false)
        #expect(outcome.summary == "Failed: boom")

        outcome.record(error: CancellationError(), cancelled: false)
        #expect(outcome.summary == "Stopped")
    }
}
