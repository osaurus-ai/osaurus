//
//  AgentRequestLifecycleTests.swift
//  OsaurusCoreTests
//
//  Pins the independent agent-request lifecycle contract on
//  `BackgroundTaskManager`:
//
//  - Admission over capacity QUEUES (FIFO) instead of rejecting; the
//    deferred start has no execution side effects until promoted.
//  - Freeing a slot (finalize, completion, cancel) promotes the oldest
//    eligible queued request; an agent at its per-agent cap is skipped
//    without head-of-line blocking other agents' work.
//  - `.waitingForInput` releases the execution slot (queued work is not
//    starved by a run idling on the user) and resumes to `.running`
//    without re-queueing.
//  - Cancelling a queued request drops its deferred start permanently.
//  - `cancelAllTasks` (app shutdown) cancels running AND queued work.
//  - Toast surfacing: waiting sorts before running before queued, and a
//    stale window binding (window gone) never hides a task.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Helpers

/// Records whether a queued task's deferred start closure ever ran.
@MainActor
private final class StartProbe {
    private(set) var started = false
    func makeStart() -> @MainActor () async -> Void {
        { self.started = true }
    }
}

@MainActor
private func makeTaskState(
    agentId: UUID,
    title: String,
    status: BackgroundTaskStatus = .running
) -> BackgroundTaskState {
    let context = ExecutionContext(agentId: agentId)
    context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
    return BackgroundTaskState(
        id: UUID(),
        taskTitle: title,
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status,
        currentStep: status == .running ? "Running..." : nil
    )
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "AgentRequestLifecycleTests", code: 1)
}

// MARK: - Queue scheduling

@Suite(.serialized)
@MainActor
struct AgentRequestQueueSchedulingTests {

    /// Isolated manager instance: these tests saturate capacity, zero the
    /// global limit, and run `cancelAllTasks` — against `.shared` that
    /// would cancel/stall tasks registered by concurrently-running suites
    /// (e.g. `ChatWindowSessionDetachTests`' adopted sessions).
    private let mgr = BackgroundTaskManager.makeForTesting()

    /// Fill the per-agent cap (5) with directly-registered running tasks
    /// for a unique agent id, isolating capacity math from anything other
    /// suites may have in flight on the shared manager.
    private func fillAgentCap(_ agentId: UUID) -> [BackgroundTaskState] {
        (0..<5).map { i in
            let state = makeTaskState(agentId: agentId, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
    }

    @Test func saturatedAgent_admissionQueuesInsteadOfRejecting() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)
        defer { fillers.forEach { mgr.finalizeTask($0.id) } }

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued-6")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer { mgr.finalizeTask(queued.id) }

        #expect(queued.status == .queued)
        #expect(mgr.taskState(for: queued.id) != nil, "queued request must be registered, not dropped")
        #expect(probe.started == false, "queued request must have no execution side effects")
        // Queued requests surface globally like any other lifecycle state.
        #expect(mgr.sortedToastTasks.contains { $0.id == queued.id })
    }

    @Test func slotFree_promotesQueuedInFIFOOrder() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)

        let probe6 = StartProbe()
        let probe7 = StartProbe()
        let queued6 = makeTaskState(agentId: agent, title: "queued-6")
        let queued7 = makeTaskState(agentId: agent, title: "queued-7")
        mgr.admitTaskForTesting(queued6, start: probe6.makeStart())
        mgr.admitTaskForTesting(queued7, start: probe7.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued6.id)
            mgr.finalizeTask(queued7.id)
        }
        #expect(queued6.status == .queued)
        #expect(queued7.status == .queued)

        // First slot frees: the OLDER queued task is promoted, not the newer.
        mgr.finalizeTask(fillers[0].id)
        #expect(queued6.status == .running)
        #expect(queued7.status == .queued)
        try await waitUntil { probe6.started }
        #expect(probe7.started == false)

        // Second slot frees: the remaining queued task follows.
        mgr.finalizeTask(fillers[1].id)
        #expect(queued7.status == .running)
        try await waitUntil { probe7.started }
    }

    @Test func waitingForInput_releasesSlotAndResumesWithoutRequeue() async throws {
        let agent = UUID()
        var fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
        // Fifth slot: a task with a live observed session that will pause
        // on a clarify prompt.
        let pausing = makeTaskState(agentId: agent, title: "pausing")
        mgr.registerTaskForTesting(pausing)
        mgr.observeChatTask(pausing, session: pausing.chatSession!)
        fillers.append(pausing)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued.id)
        }
        #expect(queued.status == .queued)

        // The run pauses for user input: it stays alive but releases its
        // slot, so the queued request is promoted instead of starving.
        pausing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        pausing.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Which db?", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(10))

        #expect(pausing.status == .waitingForInput)
        #expect(queued.status == .running)
        try await waitUntil { probe.started }

        // The user answers: the paused run resumes straight to `.running`
        // — it is never demoted back into the queue.
        pausing.chatSession?.awaitingClarify = nil
        pausing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        #expect(pausing.status == .running)
    }

    @Test func naturalCompletion_promotesQueued() async throws {
        let agent = UUID()
        var fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }
        let finishing = makeTaskState(agentId: agent, title: "finishing")
        mgr.registerTaskForTesting(finishing)
        mgr.observeChatTask(finishing, session: finishing.chatSession!)
        fillers.append(finishing)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queued.id)
        }
        #expect(queued.status == .queued)

        // The running task's stream ends cleanly → terminal `.completed`
        // → its slot promotes the queued request.
        finishing.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        finishing.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(finishing.status == .completed(summary: "Chat completed"))
        #expect(queued.status == .running)
        try await waitUntil { probe.started }
    }

    @Test func cancelQueuedTask_dropsDeferredStartPermanently() async throws {
        let agent = UUID()
        let fillers = fillAgentCap(agent)

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued-cancel")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        #expect(queued.status == .queued)

        mgr.cancelTask(queued.id)
        #expect(queued.status == .cancelled)

        // Free every slot: the cancelled request must never be resurrected
        // by the promotion pass.
        fillers.forEach { mgr.finalizeTask($0.id) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started == false)
        #expect(queued.status == .cancelled)

        mgr.finalizeTask(queued.id)
    }

    @Test func promotion_skipsAgentAtCapWithoutBlockingOtherAgents() async throws {
        let agentX = UUID()
        let agentY = UUID()
        let fillers = fillAgentCap(agentX)

        // Force BOTH follow-ups into the queue by zeroing the global limit,
        // then restore it: agent X's request stays capacity-blocked by the
        // per-agent cap while agent Y's is not.
        let originalConfig = ToastManager.shared.configuration
        var zeroed = originalConfig
        zeroed.maxConcurrentTasks = 0
        ToastManager.shared.updateConfiguration(zeroed)

        let probeX = StartProbe()
        let probeY = StartProbe()
        let queuedX = makeTaskState(agentId: agentX, title: "queued-x")
        let queuedY = makeTaskState(agentId: agentY, title: "queued-y")
        mgr.admitTaskForTesting(queuedX, start: probeX.makeStart())
        mgr.admitTaskForTesting(queuedY, start: probeY.makeStart())
        defer {
            fillers.forEach { mgr.finalizeTask($0.id) }
            mgr.finalizeTask(queuedX.id)
            mgr.finalizeTask(queuedY.id)
        }
        #expect(queuedX.status == .queued)
        #expect(queuedY.status == .queued)

        ToastManager.shared.updateConfiguration(originalConfig)
        mgr.pumpQueueForTesting()

        // Y jumps past the capacity-blocked X (no head-of-line blocking);
        // X stays queued in place.
        #expect(queuedY.status == .running)
        #expect(queuedX.status == .queued)
        try await waitUntil { probeY.started }
        #expect(probeX.started == false)

        // Once agent X frees a slot, its queued request follows.
        mgr.finalizeTask(fillers[0].id)
        #expect(queuedX.status == .running)
        try await waitUntil { probeX.started }
    }

    @Test func cancelAllTasks_cancelsRunningAndQueued() async throws {
        let agent = UUID()
        let running = makeTaskState(agentId: agent, title: "running")
        mgr.registerTaskForTesting(running)
        // Saturate the agent so the second request queues.
        let fillers = (0..<4).map { i in
            let state = makeTaskState(agentId: agent, title: "filler-\(i)")
            mgr.registerTaskForTesting(state)
            return state
        }

        let probe = StartProbe()
        let queued = makeTaskState(agentId: agent, title: "queued")
        mgr.admitTaskForTesting(queued, start: probe.makeStart())
        #expect(queued.status == .queued)

        mgr.cancelAllTasks()

        #expect(running.status == .cancelled)
        #expect(queued.status == .cancelled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started == false)

        ([running, queued] + fillers).forEach { mgr.finalizeTask($0.id) }
    }

    @Test func toastOrdering_waitingBeforeRunningBeforeQueued() async throws {
        let agent = UUID()
        let running = makeTaskState(agentId: agent, title: "t-running", status: .running)
        let waiting = makeTaskState(agentId: agent, title: "t-waiting", status: .waitingForInput)
        let queued = makeTaskState(agentId: agent, title: "t-queued", status: .queued)
        // Register in the "wrong" order to prove the sort is by status.
        mgr.registerTaskForTesting(queued)
        mgr.registerTaskForTesting(running)
        mgr.registerTaskForTesting(waiting)
        defer {
            [running, waiting, queued].forEach { mgr.finalizeTask($0.id) }
        }

        let ourIds: Set<UUID> = [running.id, waiting.id, queued.id]
        let ours = mgr.sortedToastTasks.filter { ourIds.contains($0.id) }
        #expect(ours.map(\.id) == [waiting.id, running.id, queued.id])
    }

    /// A window binding whose window no longer exists must not suppress a
    /// task from the global toast surface — otherwise a crashed / torn-down
    /// window would permanently hide a still-running request.
    @Test func staleWindowBinding_doesNotHideTaskFromToasts() async throws {
        let agent = UUID()
        let state = makeTaskState(agentId: agent, title: "stale-bind")
        mgr.registerTaskForTesting(state)
        defer { mgr.finalizeTask(state.id) }

        let ghostWindowId = UUID()
        mgr.bindWindow(ghostWindowId, toTask: state.id)
        defer { mgr.unbindWindow(ghostWindowId) }

        #expect(mgr.isTaskAttachedToWindow(state.id) == false)
        #expect(mgr.sortedToastTasks.contains { $0.id == state.id })
    }
}

// MARK: - Concurrent tool-batch ownership

/// Minimal scripted loop surface for concurrency tests: records executed
/// calls and completed batches, with an artificial per-tool delay so two
/// concurrent runs genuinely interleave on the main actor.
@MainActor
private final class ConcurrentLoopSurface {
    var steps: [AgentLoopModelStep]
    let toolDelayMs: Int
    var executedCalls: [(name: String, callId: String)] = []
    var batchOutcomes: [[AgentLoopToolOutcome]] = []

    init(steps: [AgentLoopModelStep], toolDelayMs: Int) {
        self.steps = steps
        self.toolDelayMs = toolDelayMs
    }

    func makeHooks() -> AgentLoopHooks {
        AgentLoopHooks(
            isCancelled: { false },
            buildMessages: { _ in
                AgentLoopIterationInput(messages: [ChatMessage(role: "user", content: "task")])
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
            willProcessCall: { _, _ in },
            onDedupedResult: { _, _, _ in },
            executeTool: { inv, callId in
                // Yield across the actor so the two concurrent runs interleave.
                try? await Task.sleep(for: .milliseconds(self.toolDelayMs))
                self.executedCalls.append((inv.toolName, callId))
                return AgentLoopToolExecution(result: ToolEnvelope.success(tool: inv.toolName, text: "ok"))
            },
            onBatchComplete: { outcomes in
                self.batchOutcomes.append(outcomes)
            },
            pendingTodoCount: nil
        )
    }
}

@MainActor
struct ConcurrentToolBatchIsolationTests {

    private func invocation(_ name: String) -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: name, jsonArguments: "{}", toolCallId: nil)
    }

    /// Two requests run their multi-call tool batches at the same time.
    /// Each batch stays owned by its own request: executions and ordered
    /// outcomes land only in the surface that issued them, both runs stay
    /// live until their full batch settles, and neither run's results leak
    /// into the other.
    @Test func simultaneousBatches_stayOwnedByTheirRequest() async throws {
        let surfaceA = ConcurrentLoopSurface(
            steps: [.toolCalls([invocation("a_first"), invocation("a_second"), invocation("a_third")])],
            toolDelayMs: 15
        )
        let surfaceB = ConcurrentLoopSurface(
            steps: [.toolCalls([invocation("b_first"), invocation("b_second")])],
            toolDelayMs: 25
        )

        let hooksA = surfaceA.makeHooks()
        let hooksB = surfaceB.makeHooks()
        let runA = Task { @MainActor in
            try await AgentToolLoop.run(
                policy: AgentLoopPolicy(maxIterations: 5, stopOnToolRejection: true, dedupeNoticeEnabled: true),
                state: AgentTaskState(),
                hooks: hooksA
            )
        }
        let runB = Task { @MainActor in
            try await AgentToolLoop.run(
                policy: AgentLoopPolicy(maxIterations: 5, stopOnToolRejection: true, dedupeNoticeEnabled: true),
                state: AgentTaskState(),
                hooks: hooksB
            )
        }
        let resultA = try await runA.value
        let resultB = try await runB.value

        // Both requests ran to completion, staying alive until their whole
        // batch settled.
        #expect(resultA.exit == .finalResponse)
        #expect(resultB.exit == .finalResponse)

        // Every execution landed in the surface that issued it, in model
        // order — no cross-request leakage despite interleaving.
        #expect(surfaceA.executedCalls.map(\.name) == ["a_first", "a_second", "a_third"])
        #expect(surfaceB.executedCalls.map(\.name) == ["b_first", "b_second"])

        // Ordered batch outcomes are per-request as well.
        #expect(surfaceA.batchOutcomes.count == 1)
        #expect(surfaceA.batchOutcomes[0].map { $0.invocation.toolName } == ["a_first", "a_second", "a_third"])
        #expect(surfaceB.batchOutcomes.count == 1)
        #expect(surfaceB.batchOutcomes[0].map { $0.invocation.toolName } == ["b_first", "b_second"])
    }
}
