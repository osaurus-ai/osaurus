//
//  NotchTaskGroupingTests.swift
//  osaurusTests
//
//  Presentation-model tests for the agent-tabbed notch: grouping the
//  manager's pre-sorted toast tasks by agent, aggregate group state, and
//  id-based selection resolution with stable fallback when the selected
//  agent/session has since finalized.
//

import Foundation
import Testing

@testable import OsaurusCore

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
        status: status
    )
}

@MainActor
struct NotchTaskGroupingTests {

    // MARK: - Grouping

    @Test func groupsByAgent_preservingSortedOrder() {
        let agentA = UUID()
        let agentB = UUID()
        // Simulates `sortedToastTasks`: B's waiting task sorts first, then
        // A's running, then B's running, then A's completed.
        let bWaiting = makeTaskState(agentId: agentB, title: "b-waiting", status: .waitingForInput)
        let aRunning = makeTaskState(agentId: agentA, title: "a-running", status: .running)
        let bRunning = makeTaskState(agentId: agentB, title: "b-running", status: .running)
        let aDone = makeTaskState(agentId: agentA, title: "a-done", status: .completed(summary: "ok"))

        let groups = NotchTaskGrouping.groups(from: [bWaiting, aRunning, bRunning, aDone])

        // Group order follows each agent's first (highest-priority) task.
        #expect(groups.map(\.agentId) == [agentB, agentA])
        // Tasks inside a group keep their global order.
        #expect(groups[0].tasks.map(\.id) == [bWaiting.id, bRunning.id])
        #expect(groups[1].tasks.map(\.id) == [aRunning.id, aDone.id])
    }

    @Test func emptyInput_producesNoGroups() {
        #expect(NotchTaskGrouping.groups(from: []).isEmpty)
    }

    @Test func groupAggregates_reflectMemberTasks() throws {
        let agent = UUID()
        let waiting = makeTaskState(agentId: agent, title: "waiting", status: .waitingForInput)
        let done = makeTaskState(agentId: agent, title: "done", status: .completed(summary: "ok"))
        let cancelled = makeTaskState(agentId: agent, title: "cancelled", status: .cancelled)

        let groups = NotchTaskGrouping.groups(from: [waiting, done, cancelled])

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        // Head of the pre-sorted member list is the aggregate/primary task.
        #expect(group.primaryTask?.id == waiting.id)
        #expect(group.hasActiveTasks)
        #expect(group.activeTaskCount == 1)

        let terminalOnly = NotchTaskGrouping.groups(from: [done, cancelled])
        #expect(terminalOnly.first?.hasActiveTasks == false)
        #expect(terminalOnly.first?.activeTaskCount == 0)
    }

    // MARK: - Selection Resolution

    @Test func resolveSelection_keepsValidSelection() {
        let agentA = UUID()
        let agentB = UUID()
        let a1 = makeTaskState(agentId: agentA, title: "a1")
        let b1 = makeTaskState(agentId: agentB, title: "b1")
        let b2 = makeTaskState(agentId: agentB, title: "b2")
        let groups = NotchTaskGrouping.groups(from: [a1, b1, b2])

        let resolved = NotchTaskGrouping.resolveSelection(
            groups: groups,
            selectedAgentId: agentB,
            selectedTaskId: b2.id
        )

        #expect(resolved?.group.agentId == agentB)
        #expect(resolved?.task.id == b2.id)
    }

    @Test func resolveSelection_staleAgentFallsBackToFirstGroup() {
        let agent = UUID()
        let task = makeTaskState(agentId: agent, title: "only")
        let groups = NotchTaskGrouping.groups(from: [task])

        let resolved = NotchTaskGrouping.resolveSelection(
            groups: groups,
            selectedAgentId: UUID(),  // agent finalized / never existed
            selectedTaskId: nil
        )

        #expect(resolved?.group.agentId == agent)
        #expect(resolved?.task.id == task.id)
    }

    @Test func resolveSelection_staleTaskFallsBackToGroupHead() {
        let agent = UUID()
        let waiting = makeTaskState(agentId: agent, title: "waiting", status: .waitingForInput)
        let running = makeTaskState(agentId: agent, title: "running", status: .running)
        let groups = NotchTaskGrouping.groups(from: [waiting, running])

        let resolved = NotchTaskGrouping.resolveSelection(
            groups: groups,
            selectedAgentId: agent,
            selectedTaskId: UUID()  // session finalized
        )

        // Falls back to the group's highest-priority task, not nil.
        #expect(resolved?.task.id == waiting.id)
    }

    @Test func resolveSelection_selectedTaskFromAnotherAgentIsNotCrossMatched() {
        let agentA = UUID()
        let agentB = UUID()
        let a1 = makeTaskState(agentId: agentA, title: "a1")
        let b1 = makeTaskState(agentId: agentB, title: "b1")
        let groups = NotchTaskGrouping.groups(from: [a1, b1])

        // Agent A is selected but the stored task id belongs to agent B —
        // resolution must stay inside the selected tab.
        let resolved = NotchTaskGrouping.resolveSelection(
            groups: groups,
            selectedAgentId: agentA,
            selectedTaskId: b1.id
        )

        #expect(resolved?.group.agentId == agentA)
        #expect(resolved?.task.id == a1.id)
    }

    @Test func resolveSelection_noGroupsReturnsNil() {
        let resolved = NotchTaskGrouping.resolveSelection(
            groups: [],
            selectedAgentId: UUID(),
            selectedTaskId: UUID()
        )
        #expect(resolved == nil)
    }
}
