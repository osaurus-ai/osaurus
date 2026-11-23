//
//  SyncWorkflowFileTests.swift
//  osaurusTests
//
//  A run's file too large for its output is sent on asking (`workflow_file_fetch`, docs/SYNC_MOBILE_CONTRACT.md
//  §5.5), named by ids only, and only a plain file under the cap.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SyncWorkflowFileTests {

    @Test func theFeatureIsListed() {
        #expect(SyncDeviceFeedContract.features.contains("workflow_file_fetch"))
    }

    @Test func aFileUpToTheCapCanBeAskedFor() {
        #expect(SyncWorkflowFile.fetchable(size: 100 * 1024 * 1024))
        #expect(SyncWorkflowFile.fetchable(size: SyncWorkflowFile.fetchLimit))
        #expect(!SyncWorkflowFile.fetchable(size: SyncWorkflowFile.fetchLimit + 1))
    }

    @Test func anUnknownRunOrFileFindsNothing() {
        #expect(SyncWorkflowFile.source(runId: UUID().uuidString, fileId: "x") == .failure(.notFound))
        #expect(SyncWorkflowFile.source(runId: "/etc/passwd", fileId: "x") == .failure(.notFound))
        #expect(SyncWorkflowFile.source(runId: nil, fileId: nil) == .failure(.notFound))
    }

    @Test func theRequestDecodesItsFileId() throws {
        let json = #"{"id":"r1","op":"workflowFile","runId":"a","fileId":"f","requestedMs":1}"#
        let request = try JSONDecoder().decode(SyncDeviceFeedContract.ManageRequest.self, from: Data(json.utf8))
        #expect(request.op == .workflowFile && request.fileId == "f")
    }
}
