//
//  SharedRunParkResumeTests.swift
//  osaurusTests
//
//  A hosted shared run parks while its owner approval or owner question is
//  open: the task shows Waiting for Input, and goes back to Running only
//  once every card of it has settled — approved, denied, timed out, or the
//  wait cancelled.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private func hostedTask() -> BackgroundTaskState {
    let context = ExecutionContext(agentId: Agent.defaultId)
    let state = BackgroundTaskState(
        id: UUID(), taskTitle: "shared run", agentId: Agent.defaultId,
        chatSession: context.chatSession, executionContext: context, status: .running, showToast: false)
    BackgroundTaskManager.shared.registerTaskForTesting(state)
    return state
}

@MainActor
private func hostedRoute(task: UUID, timeout: TimeInterval = 30) -> OwnerApprovalRoute {
    OwnerApprovalRoute(
        agentId: UUID(),
        agentName: "Research Agent",
        agentAddress: "0xab1200000000000000000000000000000000f291",
        caller: Participant(kind: .teammate, handle: "alice", wallet: "0x\(UUID().uuidString.prefix(8))cafe"),
        workspaceId: nil,
        hostedSessionId: task,
        conversationKey: UUID().uuidString,
        timeout: timeout,
        onStatus: { _ in }
    )
}

@MainActor
private func pendingItem(tool: String) async -> AttentionItem? {
    for _ in 0 ..< 300 {
        if let item = AttentionCenter.shared.pending.first(where: { $0.toolName == tool }) { return item }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
}

@Suite("Shared run park and resume", .serialized)
@MainActor
struct SharedRunParkResumeTests {
    init() {
        OwnerApprovalService.shared.resetForTesting(
            leasesFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-leases-\(UUID().uuidString).json"))
    }

    private func park(
        _ outcome: AttentionResolution.Outcome,
        expect decision: OwnerApprovalDecision
    ) async throws {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let tool = "tool-\(UUID().uuidString)"
        let route = hostedRoute(task: task.id)
        let request = Task { @MainActor in
            await OwnerApprovalService.shared.request(route: route, toolName: tool, callId: nil, perCallApproval: false)
        }
        let item = try #require(await pendingItem(tool: tool))
        #expect(task.status == .waitingForInput)
        #expect(item.taskId == task.id)

        AttentionCenter.shared.resolve(id: item.id, with: AttentionResolution(outcome: outcome, surface: .desktop))
        #expect(await request.value == decision)
        #expect(task.status == .running)
    }

    @Test func approvalResumes() async throws { try await park(.approved, expect: .approved) }

    @Test func denialResumes() async throws { try await park(.denied, expect: .denied) }

    @Test func timeoutResumes() async {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let decision = await OwnerApprovalService.shared.request(
            route: hostedRoute(task: task.id, timeout: 0.05), toolName: "slow-\(UUID().uuidString)",
            callId: nil, perCallApproval: false
        )
        #expect(decision == .timedOut)
        #expect(task.status == .running)
    }

    @Test func cancellingTheWaitResumes() async throws {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let tool = "tool-\(UUID().uuidString)"
        let route = hostedRoute(task: task.id)
        let request = Task { @MainActor in
            await OwnerApprovalService.shared.request(route: route, toolName: tool, callId: nil, perCallApproval: false)
        }
        let item = try #require(await pendingItem(tool: tool))
        #expect(task.status == .waitingForInput)
        request.cancel()
        #expect(await request.value == .abandoned)
        #expect(task.status == .running)
        #expect(!AttentionCenter.shared.pending.contains { $0.id == item.id })
    }

    @Test func overlappingWaitsResumeOnlyWhenBothSettle() async throws {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let first = "tool-\(UUID().uuidString)"
        let second = "tool-\(UUID().uuidString)"
        let route = hostedRoute(task: task.id)
        let a = Task { @MainActor in
            await OwnerApprovalService.shared.request(route: route, toolName: first, callId: nil, perCallApproval: false)
        }
        let b = Task { @MainActor in
            await OwnerApprovalService.shared.request(route: route, toolName: second, callId: nil, perCallApproval: false)
        }
        let one = try #require(await pendingItem(tool: first))
        let two = try #require(await pendingItem(tool: second))

        AttentionCenter.shared.resolve(id: one.id, with: AttentionResolution(outcome: .approved, surface: .phone))
        #expect(await a.value == .approved)
        #expect(task.status == .waitingForInput)

        AttentionCenter.shared.resolve(id: two.id, with: AttentionResolution(outcome: .denied, surface: .phone))
        #expect(await b.value == .denied)
        #expect(task.status == .running)
    }

    @Test func ownerQuestionParksAndResumes() async throws {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let route = hostedRoute(task: task.id)
        let question = Task { @MainActor in
            await OwnerApprovalService.shared.ask(route: route, question: "Which branch?", callId: "c1")
        }
        let item = try #require(await pendingItem(tool: AskOwnerTool.toolName))
        #expect(item.kind == .clarification)
        #expect(task.status == .waitingForInput)

        AttentionCenter.shared.resolve(
            id: item.id, with: AttentionResolution(outcome: .replied, surface: .phone, replyText: "  main  "))
        #expect(await question.value == .replied("main"))
        #expect(task.status == .running)
    }

    @Test func waitingDataNamesTheOpenCard() async throws {
        let task = hostedTask()
        defer { BackgroundTaskManager.shared.finalizeTask(task.id) }
        let tool = "tool-\(UUID().uuidString)"
        let route = hostedRoute(task: task.id)
        let request = Task { @MainActor in
            await OwnerApprovalService.shared.request(route: route, toolName: tool, callId: nil, perCallApproval: false)
        }
        let item = try #require(await pendingItem(tool: tool))

        let data = BackgroundTaskManager.waitingData(taskId: task.id, sessionId: UUID())
        #expect(data["attention_id"] == item.id.uuidString)
        #expect(data["attention_kind"] == AttentionKind.ownerApproval.rawValue)
        #expect(data["tool"] == tool)
        #expect(data["asked"] == "agent_owner")
        #expect(data["who"]?.contains("alice") == true)
        #expect(BackgroundTaskManager.waitingData(taskId: UUID(), sessionId: UUID()).isEmpty)

        AttentionCenter.shared.resolve(id: item.id, with: AttentionResolution(outcome: .denied, surface: .desktop))
        _ = await request.value
        #expect(BackgroundTaskManager.waitingData(taskId: task.id, sessionId: UUID()).isEmpty)
    }
}
