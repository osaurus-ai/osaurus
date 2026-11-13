//
//  WorkflowTeammateRunTests.swift
//  OsaurusCoreTests
//
//  Workflows reached through a shared agent: who counts as a teammate
//  caller, the per-workflow "Teammates can run this" opt-in, the approval
//  policy it resolves to, the refusal when it is off, attribution on the
//  run, and the workspace audit rows.
//

import Foundation
import Testing

@testable import OsaurusCore

private let teammate = Participant(kind: .teammate, handle: "rex-42", wallet: "0xABCDEF")

private func asSharedRun<T>(
    _ participant: Participant? = teammate, workspaceId: String? = "ws-team",
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    let route = workspaceId.map { OsaurusRouterWorkspaceContext(workspaceId: $0, agentAddress: "0xagent") }
    return try await ChatExecutionContext.$isExternalSurface.withValue(true) {
        try await ChatExecutionContext.$currentParticipant.withValue(participant) {
            try await ChatExecutionContext.$workspaceBillingContext.withValue(route) {
                try await body()
            }
        }
    }
}

struct WorkflowTeammateCallerTests {
    @Test
    func onlyTeammatesGuestsAndRemoteAgentsOnAnExternalSurfaceAreSharedRunCallers() async {
        #expect(WorkflowToolCall.sharedRunCaller == nil, "in-app chat")
        let inAppTeammate = await ChatExecutionContext.$currentParticipant.withValue(teammate) {
            WorkflowToolCall.sharedRunCaller
        }
        #expect(inAppTeammate == nil, "a participant without an external surface is not a shared run")

        for kind in [ParticipantKind.teammate, .invitePeer, .remoteAgent] {
            let found = await asSharedRun(Participant(kind: kind, handle: "x")) { WorkflowToolCall.sharedRunCaller }
            #expect(found?.kind == kind)
        }
        for kind in [ParticipantKind.owner, .ownerDevice, .channelSender] {
            let found = await asSharedRun(Participant(kind: kind)) { WorkflowToolCall.sharedRunCaller }
            #expect(found == nil, "\(kind)")
        }
    }

    @Test
    func theCallerCarriesTheTeammateAndWorkspace_throughNestedSteps() async throws {
        let caller = await asSharedRun { await WorkflowToolCall.caller(kind: .agent) }
        #expect(caller.onBehalfOf == teammate)
        #expect(caller.workspaceId == "ws-team")

        let guest = await asSharedRun(Participant(kind: .invitePeer, handle: "guest"), workspaceId: nil) {
            await WorkflowToolCall.caller(kind: .agent)
        }
        #expect(guest.onBehalfOf?.kind == .invitePeer)
        #expect(guest.workspaceId == nil)

        let owner = await WorkflowToolCall.caller(kind: .agent)
        #expect(owner.onBehalfOf == nil)

        let nested = caller.nested(parentRunID: UUID(), parentWorkflowID: UUID())
        #expect(nested.onBehalfOf == teammate)
        #expect(nested.workspaceId == "ws-team")

        let decoded = try JSONDecoder().decode(WorkflowCaller.self, from: JSONEncoder().encode(nested))
        #expect(decoded.onBehalfOf == teammate)
        #expect(decoded.workspaceId == "ws-team")

        let legacy = try JSONDecoder().decode(WorkflowCaller.self, from: Data(#"{"kind":"agent"}"#.utf8))
        #expect(legacy.onBehalfOf == nil)
        #expect(legacy.workspaceId == nil)
    }

    @Test
    func aParkedTeammateRunTellsTheCallerTheOwnerAnswers() {
        let parked = WorkflowCallResult(status: .awaitingUser, runID: UUID())
        let forOwner = WorkflowToolCall.envelope(parked, workflow: "Intake", tool: "workflow_intake", waitingOn: .owner)
        let forUser = WorkflowToolCall.envelope(parked, workflow: "Intake", tool: "workflow_intake")
        #expect(forOwner != forUser)
        #expect(forOwner.contains("owner"))
        #expect(!ToolEnvelope.isError(forOwner))
    }
}

@Suite(.serialized)
@MainActor
struct WorkflowTeammateGateTests {
    private func withStore(_ body: @MainActor (InstalledWorkflowStore) async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            try await body(store)
        }
    }

    @Test
    func theOptInDefaultsOff_persists_andSurvivesAnOldRecord() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            #expect(!installed.teammatesCanRun)

            try store.setTeammatesCanRun(true, id: installed.id)
            store.reload()
            #expect(store.workflow(id: installed.id)?.teammatesCanRun == true)

            var json = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(installed)) as? [String: Any])
            json.removeValue(forKey: "teammates_can_run")
            let old = try JSONDecoder().decode(
                InstalledWorkflow.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(!old.teammatesCanRun)
        }
    }

    @Test
    func aSharedRunAsksOnlyForAWorkflowOpenToTeammates() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let tool = WorkflowTool(installed)
            let byName = RunWorkflowTool()
            let args = #"{"workflow":"\#(installed.name)","input":{}}"#

            #expect(await tool.resolveContextualPermissionPolicy(argumentsJSON: "{}") == .auto)
            #expect(await asSharedRun { await tool.resolveContextualPermissionPolicy(argumentsJSON: "{}") } == .auto)

            try store.setTeammatesCanRun(true, id: installed.id)
            #expect(await tool.resolveContextualPermissionPolicy(argumentsJSON: "{}") == .auto, "the owner is not asked")
            #expect(await asSharedRun { await tool.resolveContextualPermissionPolicy(argumentsJSON: "{}") } == .ask)
            #expect(await asSharedRun { await byName.resolveContextualPermissionPolicy(argumentsJSON: args) } == .ask)
            #expect(
                await asSharedRun {
                    await byName.resolveContextualPermissionPolicy(argumentsJSON: #"{"workflow":"nope"}"#)
                } == .auto)
        }
    }

    @Test
    func aTeammateCannotRunAWorkflowThatIsNotOpen_andNothingStarts() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            var caller = WorkflowCaller(kind: .agent)
            caller.onBehalfOf = teammate

            let refused = await WorkflowToolCall.run(
                workflowID: installed.id, input: .object(["client": .string("Acme")]), caller: caller,
                tool: installed.toolName)
            #expect(ToolEnvelope.isError(refused))
            #expect(refused.contains("not open to people this agent is shared with"))
            #expect(WorkflowToolCall.runID(inResult: refused) == nil)
            #expect(store.workflow(id: installed.id)?.needsSetup == false, "a refusal is not a setup problem")

            try store.setTeammatesCanRun(true, id: installed.id)
            let reached = await WorkflowToolCall.run(
                workflowID: installed.id, input: .object(["client": .string("Acme")]), caller: caller,
                tool: installed.toolName)
            #expect(!reached.contains("not open to people"), "an open workflow goes on to its setup check")
            #expect(reached.contains(WorkflowCallResult.Status.needsSetup.rawValue))
        }
    }
}

@Suite("Workspace audit log workflow runs")
struct WorkspaceAuditWorkflowRunTests {
    @Test func workflowRunsRecordTheTeammateAndWorkflow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-audit-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = WorkspaceAuditLog()
        await log.setSeams(directoryURL: { dir })
        let runId = UUID()

        await log.recordWorkflowRun(
            .workflowRunStarted, workspaceId: "ws-wf", caller: teammate, agentAddress: "0xAGENT", agentName: "HR",
            workflowName: "Intake", runId: runId)
        await log.recordWorkflowRun(
            .workflowRunFinished, workspaceId: "ws-wf", caller: teammate, agentAddress: "0xAGENT", agentName: "HR",
            workflowName: "Intake", runId: runId, details: ["status": "completed", "success": "true"])
        await log.recordWorkflowRun(
            .workflowRunRefused, workspaceId: "ws-wf", caller: teammate, agentAddress: "0xAGENT", agentName: "HR",
            workflowName: "Payroll", runId: nil, details: ["reason": "not_open_to_teammates"])

        let records = await log.records(workspaceId: "ws-wf")
        #expect(records.map(\.event) == [.workflowRunStarted, .workflowRunFinished, .workflowRunRefused])
        #expect(records[0].target == runId.uuidString)
        #expect(records[0].details["workflow"] == "Intake")
        #expect(records[0].details["caller_handle"] == "@rex-42")
        #expect(records[0].actor?.wallet == "0xabcdef")
        #expect(records[1].details["success"] == "true")
        #expect(records[2].details["reason"] == "not_open_to_teammates")
        #expect(WorkspaceAuditEventKind.workflowRunRefused.category == .denials)
        #expect(WorkspaceAuditEventKind.workflowRunStarted.category == .runs)
        #expect(await log.verify(workspaceId: "ws-wf").isIntact)
    }
}

@Suite("Guest-started workflow runs")
struct WorkflowGuestRunRecordTests {
    private let guest = Participant(kind: .invitePeer, handle: "gia-7", wallet: "0x1234567890ABCDEF1234")

    private var guestCaller: WorkflowCaller {
        var caller = WorkflowCaller(kind: .agent, agentID: UUID(), agentName: "HR")
        caller.onBehalfOf = guest
        return caller
    }

    @MainActor @Test func theInsightsRunRowNamesTheGuest() {
        let label = WorkflowActivityLogger.callerLabel(guestCaller)
        #expect(label.contains("@gia-7"), "\(label)")
        #expect(label.contains("HR"))
    }

    @Test func startFinishAndRefusalAreInteractionsWithTheGuest() throws {
        let runID = UUID()
        let started = try #require(
            WorkflowToolCall.interaction(.workflowRunStarted, caller: guestCaller, workflow: "Intake", runID: runID))
        #expect(started.method == "START")
        #expect(started.details["requester"]?.contains("@gia-7") == true)
        #expect(started.details["requester_kind"] == "invite_peer")
        #expect(started.details["run_id"] == runID.uuidString)
        #expect(started.details["workspace_id"] == nil, "an invite link has no workspace")

        let finished = try #require(
            WorkflowToolCall.interaction(
                .workflowRunFinished, caller: guestCaller, workflow: "Intake", runID: runID,
                details: ["status": "failed", "success": "false"]))
        #expect(finished.method == "FINISH")
        #expect(finished.statusCode == 500)
        #expect(finished.details["status"] == "failed")

        let refused = try #require(
            WorkflowToolCall.interaction(
                .workflowRunRefused, caller: guestCaller, workflow: "Payroll", runID: nil,
                details: ["reason": "not_open_to_teammates"]))
        #expect(refused.method == "REFUSE")
        #expect(refused.statusCode == 403)
        #expect(refused.details["reason"] == "not_open_to_teammates")

        #expect(
            WorkflowToolCall.interaction(
                .workflowRunStarted, caller: WorkflowCaller(kind: .user), workflow: "Intake", runID: runID) == nil,
            "the owner's own runs are not interactions")
    }
}
