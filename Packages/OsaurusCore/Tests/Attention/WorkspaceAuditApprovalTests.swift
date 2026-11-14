//
//  WorkspaceAuditApprovalTests.swift
//  osaurusTests
//
//  Owner approvals and owner messages on the workspace audit trail:
//  metadata only, named by handle, filed under Approvals, chain intact.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workspace audit approvals")
struct WorkspaceAuditApprovalTests {
    private func makeLog() async -> WorkspaceAuditLog {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-audit-approvals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = WorkspaceAuditLog()
        await log.setSeams(directoryURL: { dir })
        return log
    }

    private let caller = Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")

    @Test func approvalLifecycleIsRecorded() async throws {
        let log = await makeLog()
        let approval = UUID()
        await log.recordApproval(
            .approvalRequested, workspaceId: "ws", caller: caller, agentAddress: "0xAGENT", agentName: "Research Agent",
            approvalId: approval, toolName: "web_fetch"
        )
        await log.recordApproval(
            .approvalGranted, workspaceId: "ws", caller: caller, agentAddress: "0xAGENT", agentName: "Research Agent",
            approvalId: approval, toolName: "web_fetch", details: ["surface": "phone", "scope": "conversation"]
        )
        let records = await log.records(workspaceId: "ws")
        #expect(records.map(\.event) == [.approvalRequested, .approvalGranted])
        #expect(records.allSatisfy { $0.target == approval.uuidString })
        #expect(records[0].actor?.wallet == caller.wallet)
        #expect(records[0].details["caller_handle"] == "@alice")
        #expect(records[1].actor?.isSelf == true)
        #expect(records[1].details["scope"] == "conversation")
        #expect(records.allSatisfy { $0.event.category == .approvals })
        #expect(await log.verify(workspaceId: "ws").isIntact)
    }

    @Test func ownerMessagesCarryNoText() async {
        let log = await makeLog()
        await log.recordParticipantMessage(
            workspaceId: "ws", agentAddress: "0xagent", agentName: "Research Agent", conversation: "conv", caller: caller
        )
        let record = await log.records(workspaceId: "ws").first
        #expect(record?.event == .participantMessage)
        #expect(record?.event.category == .runs)
        #expect(record?.details.keys.sorted() == ["caller_handle", "caller_kind", "caller_wallet"])
    }
}
