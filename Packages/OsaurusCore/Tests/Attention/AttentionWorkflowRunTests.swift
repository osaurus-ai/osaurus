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
}
