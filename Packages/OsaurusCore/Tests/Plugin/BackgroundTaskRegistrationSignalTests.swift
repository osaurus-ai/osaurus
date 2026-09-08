//
//  BackgroundTaskRegistrationSignalTests.swift
//  osaurusTests
//
//  `BackgroundTaskManager.taskRegistered` is how chat windows learn that a
//  run should appear as a tab of its agent. It must fire for visible runs
//  backed by a chat session (dispatched, adopted, and runs hosted for a
//  remote caller of a shared agent) and stay silent for spawned-helper
//  mirrors (no chat of their own) and headless `showToast == false` runs.
//  `tasksForTabs()` applies the same filter for windows that open later.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private func makeState(
    agentId: UUID = UUID(),
    status: BackgroundTaskStatus = .running,
    source: SessionSource = .schedule,
    showToast: Bool = true,
    mirror: Bool = false
) -> BackgroundTaskState {
    let id = UUID()
    if mirror {
        let state = BackgroundTaskState(
            subagentMirrorId: id,
            toolCallId: "call-\(id.uuidString)",
            parentSessionId: nil,
            taskTitle: "helper",
            agentId: agentId
        )
        state.status = status
        state.source = source
        state.showToast = showToast
        return state
    }
    let context = ExecutionContext(id: id, agentId: agentId, title: "run", source: source)
    context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
    return BackgroundTaskState(
        id: id,
        taskTitle: "run",
        agentId: agentId,
        chatSession: context.chatSession,
        executionContext: context,
        status: status,
        currentStep: nil,
        source: source,
        sourcePluginId: nil,
        externalSessionKey: nil,
        showToast: showToast
    )
}

@MainActor
struct BackgroundTaskRegistrationSignalTests {

    private let mgr = BackgroundTaskManager.makeForTesting()

    @Test func taskRegistered_firesForVisibleRunsWithASession() {
        var received: [UUID] = []
        let sub = mgr.taskRegistered.sink { received.append($0.id) }
        defer { sub.cancel() }

        let scheduled = makeState(source: .schedule)
        let api = makeState(source: .http)
        let adopted = makeState(source: .chat)
        [scheduled, api, adopted].forEach { mgr.registerTaskThroughProductionPathForTesting($0) }
        defer { [scheduled, api, adopted].forEach { mgr.finalizeTask($0.id) } }

        #expect(received == [scheduled.id, api.id, adopted.id], "one synchronous signal per registration, in order")
    }

    @Test func taskRegistered_staysSilentForMirrorsAndHeadlessRuns() {
        var received: [UUID] = []
        let sub = mgr.taskRegistered.sink { received.append($0.id) }
        defer { sub.cancel() }

        let helper = makeState(source: .delegation, mirror: true)
        let headless = makeState(source: .http, showToast: false)
        [helper, headless].forEach { mgr.registerTaskThroughProductionPathForTesting($0) }
        defer { [helper, headless].forEach { mgr.finalizeTask($0.id) } }

        #expect(received.isEmpty)
    }

    @Test func taskRegistered_firesForInboundSharedAgentRuns_whichAreTabWorthy() {
        var received: [UUID] = []
        let sub = mgr.taskRegistered.sink { received.append($0.id) }
        defer { sub.cancel() }

        // A teammate / invite-link peer driving one of our shared agents is
        // hosted as a real session-backed task (not a mirror): it opens as a
        // tab of the agent and never holds a dispatch execution slot.
        let id = UUID()
        let agentId = UUID()
        let context = ExecutionContext(id: id, agentId: agentId, title: "Alice → Agent", source: .workspace)
        context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
        let inbound = BackgroundTaskState(
            inboundRunId: id,
            taskTitle: "Alice → Agent",
            agentId: agentId,
            chatSession: context.chatSession,
            executionContext: context,
            externalSessionKey: "Alice"
        )
        mgr.registerInboundRun(inbound)
        defer { mgr.finalizeTask(inbound.id) }

        #expect(inbound.isInboundRun)
        #expect(!inbound.isSubagentMirror)
        #expect(received == [inbound.id])
        #expect(mgr.tasksForTabs().map(\.id).contains(inbound.id))
        #expect(mgr.liveTask(forSessionId: id) === inbound)
    }

    @Test func tasksForTabs_matchesTheSignalsFilter_andOrdersByCreation() {
        let first = makeState(source: .schedule)
        let mirror = makeState(source: .delegation, mirror: true)
        let headless = makeState(showToast: false)
        let finished = makeState(status: .completed(summary: "ok"))
        [first, mirror, headless, finished].forEach { mgr.registerTaskForTesting($0) }
        defer { [first, mirror, headless, finished].forEach { mgr.finalizeTask($0.id) } }

        let ids = mgr.tasksForTabs().map(\.id)
        #expect(ids.contains(first.id))
        #expect(ids.contains(finished.id), "finished runs stay visible as tabs until dismissed")
        #expect(!ids.contains(mirror.id))
        #expect(!ids.contains(headless.id))
    }

    @Test func taskOwningSession_resolvesLiveInstanceAndIdStandIn() {
        let run = makeState()
        let mirror = makeState(mirror: true)
        mgr.registerTaskForTesting(run)
        mgr.registerTaskForTesting(mirror)
        defer {
            mgr.finalizeTask(run.id)
            mgr.finalizeTask(mirror.id)
        }
        let live = run.chatSession!

        #expect(mgr.task(owning: live) === run)

        // A cold stand-in for the same persisted row (hibernated / retained
        // tab) resolves by id.
        let standIn = ChatSession()
        standIn.sessionId = run.id
        #expect(mgr.task(owning: standIn) === run)

        // A session that merely shares a mirror's id is not owned by it.
        let mirrorLookalike = ChatSession()
        mirrorLookalike.sessionId = mirror.id
        #expect(mgr.task(owning: mirrorLookalike) == nil)

        let unrelated = ChatSession()
        unrelated.sessionId = UUID()
        #expect(mgr.task(owning: unrelated) == nil)
    }
}
