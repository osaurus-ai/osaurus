//
//  PhoneAgentEditingTests.swift
//  OsaurusCoreTests
//
//  The iPhone's agent edits through Sync (`ai.osaurus.manage-request/1`):
//  only the fields sent change, clearing puts temperature and max tokens
//  back to the default, and the Default agent and unknown agents can't be
//  edited or deleted.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Phone agent edits")
@MainActor
struct PhoneAgentEditingTests {
    private func request(_ build: (inout SyncDeviceFeedContract.ManageRequest) -> Void) -> SyncDeviceFeedContract.ManageRequest {
        var request = SyncDeviceFeedContract.ManageRequest(id: "r1", op: .updateAgent, agentId: UUID().uuidString, requestedMs: 0)
        build(&request)
        return request
    }

    @Test func onlyTheFieldsSentChange() {
        let edit = SyncManageFeed.patch(from: request {
            $0.name = "Scout"
            $0.memoryEnabled = false
            $0.temperature = 0.4
        })
        #expect(edit.name == "Scout")
        #expect(edit.memoryEnabled == false)
        #expect(edit.temperature == .set(0.4))
        #expect(edit.toolsEnabled == nil)
        #expect(edit.maxTokens == nil)
        #expect(edit.systemPrompt == nil)
    }

    @Test func clearingGoesBackToTheDefault() {
        let edit = SyncManageFeed.patch(from: request {
            $0.clearTemperature = true
            $0.clearMaxTokens = true
        })
        #expect(edit.temperature == .clear)
        #expect(edit.maxTokens == .clear)
    }

    @Test func anEmptyRequestChangesNothing() {
        #expect(SyncManageFeed.patch(from: request { _ in }).isEmpty)
    }

    @Test func outOfRangeValuesAreRefused() async {
        let hot = await SyncManageFeed.perform(request { $0.temperature = 2.5 })
        #expect(hot.ok == false)
        #expect(hot.error == "agent_not_found" || hot.error == "bad_request")
        let defaultAgent = await SyncManageFeed.perform(request {
            $0.agentId = Agent.defaultId.uuidString
            $0.name = "Renamed"
        })
        #expect(defaultAgent.ok == false)
        #expect(defaultAgent.error == "agent_not_editable")
    }
}

@Suite("Phone agent delete")
@MainActor
struct PhoneAgentDeleteTests {
    @Test func unknownOrBuiltInAgentIsNotEditable() async {
        for id in [UUID(), Agent.defaultId] {
            await #expect(throws: PhoneAgentEditing.EditError.notEditable) {
                _ = try await PhoneAgentEditing.delete(id)
            }
        }
    }

    @Test func sharedAgentIsRefusedAsAConflict() {
        let reply = PhoneAgentEditing.EditError.sharedInWorkspace.reply
        #expect(reply.status == 409)
        #expect(reply.code == "agent_shared")
    }

    @Test func loadingToolsIsAConflict() {
        #expect(PhoneAgentEditing.EditError.toolsLoading.reply.status == 409)
        #expect(PhoneAgentEditing.EditError.toolsLoading.reply.code == "tools_loading")
    }
}
