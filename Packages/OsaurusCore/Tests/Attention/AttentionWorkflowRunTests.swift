//
//  AttentionWorkflowRunTests.swift
//  osaurusTests
//
//  An item a workflow run raises names the run (`run_id`), so an iPhone that
//  started it shows a step's tool approval on the run, not only its forms
//  (docs/SYNC_MOBILE_CONTRACT.md §4, `workflow_run_approvals`).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AttentionWorkflowRunTests {

    @Test func aToolApprovalRaisedInARunNamesTheRun() {
        let runId = UUID()
        let item = ChatExecutionContext.$currentWorkflowRunId.withValue(runId) {
            AttentionProducers.item(id: UUID(), kind: .toolApproval, title: "Run a shell command?")
        }
        #expect(item.workflowRunId == runId)
        #expect(PairedDeviceChannel.wire(item)["run_id"] as? String == runId.uuidString)
    }

    @Test func anItemOutsideARunNamesNone() {
        let item = AttentionProducers.item(id: UUID(), kind: .toolApproval, title: "Allow web_fetch?")
        #expect(item.workflowRunId == nil)
        #expect(PairedDeviceChannel.wire(item)["run_id"] == nil)
    }

    @Test func theFeatureIsListed() {
        #expect(SyncDeviceFeedContract.features.contains("workflow_run_approvals"))
    }

    // MARK: Sub-workflows

    @Test func aSubRunNamesTheRunAPersonStarted() {
        let top = UUID()
        let child = WorkflowCaller(kind: .user).nested(parentRunID: top, parentWorkflowID: UUID())
        #expect(child.rootRunID == top)
        let grandchild = child.nested(parentRunID: UUID(), parentWorkflowID: UUID())
        #expect(grandchild.rootRunID == top, "two levels down still names the outermost run")
    }

    @Test func aSubRunsToolApprovalNamesTheOutermostRun() {
        let top = UUID()
        let item = ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
            ChatExecutionContext.$currentRootWorkflowRunId.withValue(top) {
                AttentionProducers.item(id: UUID(), kind: .toolApproval, title: "Run a shell command?")
            }
        }
        #expect(item.workflowRunId == top)
    }

    @Test func theRootRunIdSurvivesTheRunRecord() throws {
        let top = UUID()
        let child = WorkflowCaller(kind: .user).nested(parentRunID: top, parentWorkflowID: UUID())
        let decoded = try JSONDecoder().decode(WorkflowCaller.self, from: JSONEncoder().encode(child))
        #expect(decoded.rootRunID == top)
    }
}
