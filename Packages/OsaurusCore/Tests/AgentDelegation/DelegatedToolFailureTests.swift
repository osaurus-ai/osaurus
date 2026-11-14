import Foundation
import Testing
@testable import OsaurusCore

/// Actual loop terminal boundary, ChatSession state, background observer and
/// dispatcher mapping. Scripted tool output only; no model or GPU execution.
@Suite(.serialized)
@MainActor
struct DelegatedToolFailureTests {
    private func object(_ error: SubagentError) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(error.envelope(tool: "spawn_agent").utf8))
            as? [String: Any])
    }

    @Test(arguments: [false, true])
    func stoppedNestedToolStaysNonretryableThroughBackgroundFailure(batch: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let context = ExecutionContext(agentId: Agent.defaultId)
            let session = context.chatSession
            session.chatEngineFactory = { _ in MockChatEngine() }
            let taskID = UUID(), runID = UUID()
            session.sessionId = taskID
            session.delegatedToolFailure.begin(runID: runID)
            let state = BackgroundTaskState(id: taskID, taskTitle: "nested-stop-regression",
                agentId: Agent.defaultId, chatSession: session, executionContext: context,
                status: .running, currentStep: "Running")
            let manager = BackgroundTaskManager.shared
            manager.registerTaskForTesting(state)
            manager.observeChatTask(state, session: session)
            defer { manager.finalizeTask(taskID) }
            session.isStreaming = true
            let denied = ToolEnvelope.failure(kind: .userDenied,
                message: "Run stopped by the user while waiting for another subagent to finish.",
                tool: "image", retryable: false)
            let invocation = ServiceToolInvocation(toolName: "image", jsonArguments: "{}", toolCallId: "image-stop")
            var hooks = AgentLoopHooks(
                buildMessages: { _ in AgentLoopIterationInput(messages: [], overBudget: false) },
                modelStep: { _, _ in .toolCalls([invocation]) },
                executeTool: { _, _ in AgentLoopToolExecution(result: denied, isError: true) })
            hooks.recordTerminalToolRejection = { envelope in
                session.delegatedToolFailure.record(envelope, runID: runID)
            }
            if batch {
                hooks.executeBatch = { calls in
                    calls.map { _ in AgentLoopToolExecution(result: denied, isError: true) }
                }
            }
            let result = try await AgentToolLoop.run(
                policy: AgentLoopPolicy(maxIterations: 2, stopOnToolRejection: true, dedupeNoticeEnabled: false),
                state: AgentTaskState(), hooks: hooks)
            #expect(result.exit == .toolRejected)
            let captured = try #require(session.delegatedToolFailure.current)
            #expect(captured.runID == runID && captured.kind == .userDenied && captured.retryable == false)
            // Match ChatSession's terminal publication ordering and preserve the
            // existing lifecycle error. The dispatcher must retain its cause.
            session.lastStreamError = "Tool call failed."
            session.delegatedToolFailure.finish(runID: runID)
            session.isStreaming = false
            let completion = await manager.awaitCompletion(taskID, timeoutSeconds: 2)
            guard case .failed(let message) = completion else {
                Issue.record("Expected real background failure, got \(completion)")
                return
            }
            let mapped = try object(AgentDelegationDispatcher.failureForChild(message: message,
                targetAgentName: "image worker", terminalFailure: session.delegatedToolFailure.current))
            #expect(mapped["kind"] as? String == "user_denied")
            #expect(mapped["retryable"] as? Bool == false)
        }
    }

    @Test func genuineRuntimeFailuresRemainRetryable() throws {
        var state = DelegatedToolFailureState()
        let run = UUID()
        state.begin(runID: run)
        state.record(ToolEnvelope.failure(kind: .executionError, message: "temporary engine failure",
            tool: "image", retryable: true), runID: run)
        let mapped = try object(AgentDelegationDispatcher.failureForChild(message: "Tool call failed.",
            targetAgentName: "worker", terminalFailure: state.current))
        #expect(mapped["kind"] as? String == "execution_error")
        #expect(mapped["retryable"] as? Bool == true)
    }

    @Test func newRunClearsOldRejectionAndIgnoresLateOldDelivery() throws {
        var state = DelegatedToolFailureState()
        let old = UUID(), next = UUID()
        let denied = ToolEnvelope.failure(kind: .userDenied, message: "stopped", tool: "image", retryable: false)
        state.begin(runID: old)
        state.record(denied, runID: old)
        #expect(state.current?.kind == .userDenied)
        state.begin(runID: next)
        state.record(denied, runID: old)
        state.finish(runID: old)
        #expect(state.runID == next && state.current == nil)
        let mapped = try object(AgentDelegationDispatcher.failureForChild(message: "new engine failure",
            targetAgentName: "worker", terminalFailure: state.current))
        #expect(mapped["kind"] as? String == "execution_error")
        #expect(mapped["retryable"] as? Bool == true)
    }

    @Test func finishedRunRejectsLateMetadataAndSuccessCannotBecomeDenial() {
        var state = DelegatedToolFailureState()
        let run = UUID()
        state.begin(runID: run)
        state.record(ToolEnvelope.success(tool: "image", text: "done"), runID: run)
        #expect(state.current == nil)
        state.finish(runID: run)
        state.record(ToolEnvelope.failure(kind: .userDenied, message: "late", tool: "image", retryable: false), runID: run)
        #expect(state.current == nil)
    }
    @Test func explicitNonUserNonretryableFailureIsNotUpgraded() throws {
        var state = DelegatedToolFailureState()
        let run = UUID()
        state.begin(runID: run)
        state.record(ToolEnvelope.failure(kind: .executionError, message: "nonretryable operation failure",
            tool: "image", retryable: false), runID: run)
        let mapped = try object(AgentDelegationDispatcher.failureForChild(message: "Tool call failed.",
            targetAgentName: "worker", terminalFailure: state.current))
        #expect(mapped["kind"] as? String == "execution_error")
        #expect(mapped["retryable"] as? Bool == false)
    }

    @Test func completionSnapshotSurvivesTaskFinalizationBeforeArtifactAdoption() async throws {
        try await ChatHistoryTestStorage.run {
            let context = ExecutionContext(agentId: Agent.defaultId)
            let session = context.chatSession
            session.chatEngineFactory = { _ in MockChatEngine() }
            let taskID = UUID(), runID = UUID()
            session.sessionId = taskID
            session.delegatedToolFailure.begin(runID: runID)
            let state = BackgroundTaskState(id: taskID, taskTitle: "completion-snapshot",
                agentId: Agent.defaultId, chatSession: session, executionContext: context,
                status: .running, currentStep: "Running")
            let manager = BackgroundTaskManager.shared
            manager.registerTaskForTesting(state)
            manager.observeChatTask(state, session: session)
            defer { manager.finalizeTask(taskID) }
            session.isStreaming = true
            session.delegatedToolFailure.record(ToolEnvelope.failure(kind: .userDenied,
                message: "stopped", tool: "image", retryable: false), runID: runID)
            session.lastStreamError = "Tool call failed."
            session.delegatedToolFailure.finish(runID: runID)
            session.isStreaming = false
            let completion = await manager.awaitCompletionWithToolFailure(taskID, timeoutSeconds: 2)
            manager.finalizeTask(taskID)
            #expect(manager.taskState(for: taskID) == nil)
            // No live lookup survives this point. Model artifact adoption may
            // suspend, but this value-only snapshot retains the exact cause.
            await Task.yield()
            guard case .failed(let message) = completion.result else {
                Issue.record("Expected failed background completion")
                return
            }
            #expect(completion.terminalToolFailure?.runID == runID)
            let mapped = try object(AgentDelegationDispatcher.failureForChild(message: message,
                targetAgentName: "worker", terminalFailure: completion.terminalToolFailure))
            #expect(mapped["kind"] as? String == "user_denied")
            #expect(mapped["retryable"] as? Bool == false)
        }
    }

    @Test func pendingCompletionCopiesCauseBeforeImmediateFinalization() async throws {
        try await ChatHistoryTestStorage.run {
            let context = ExecutionContext(agentId: Agent.defaultId)
            let session = context.chatSession
            session.chatEngineFactory = { _ in MockChatEngine() }
            let taskID = UUID(), runID = UUID()
            session.sessionId = taskID
            session.delegatedToolFailure.begin(runID: runID)
            let state = BackgroundTaskState(id: taskID, taskTitle: "pending-completion-snapshot",
                agentId: Agent.defaultId, chatSession: session, executionContext: context,
                status: .running, currentStep: "Running")
            let manager = BackgroundTaskManager.shared
            manager.registerTaskForTesting(state)
            manager.observeChatTask(state, session: session)
            session.isStreaming = true
            let waiter = Task { @MainActor in
                await manager.awaitCompletionWithToolFailure(taskID, timeoutSeconds: 2)
            }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !manager.hasCompletionWaiterForTesting(taskID), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                // Observe actual registration, not an assumed Task.yield order.
                try #require(manager.hasCompletionWaiterForTesting(taskID))
                session.delegatedToolFailure.record(ToolEnvelope.failure(kind: .userDenied,
                    message: "stopped at child", tool: "image", retryable: false), runID: runID)
                session.lastStreamError = "Tool call failed."
                session.delegatedToolFailure.finish(runID: runID)
                session.isStreaming = false
                // No actor suspension: remove all task-owned live references
                // before the registered continuation can resume on MainActor.
                manager.finalizeTask(taskID)
                #expect(manager.taskState(for: taskID) == nil)
                let completion = await waiter.value
                guard case .failed(let message) = completion.result else {
                    Issue.record("Expected failed registered completion")
                    return
                }
                #expect(completion.terminalToolFailure?.runID == runID)
                #expect(completion.terminalToolFailure?.message == "stopped at child")
                let mapped = try object(AgentDelegationDispatcher.failureForChild(message: message,
                    targetAgentName: "worker", terminalFailure: completion.terminalToolFailure))
                #expect(mapped["kind"] as? String == "user_denied")
                #expect(mapped["retryable"] as? Bool == false)
            } catch {
                // Finalization resumes a registered waiter; join before the
                // shared test storage scope exits, including timeout/cancel.
                manager.finalizeTask(taskID)
                _ = await waiter.value
                throw error
            }
        }
    }

}
