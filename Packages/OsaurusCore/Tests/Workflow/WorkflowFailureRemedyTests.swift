//
//  WorkflowFailureRemedyTests.swift
//  OsaurusCoreTests
//
//  The fix a failed workflow call offers on its chat card, read back from
//  the call's result envelope: a permission, a folder, search, or a model.
//  Failures the person cannot fix offer nothing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowFailureRemedyTests {

    private func failedEnvelope(_ error: Error, agent: String? = nil) -> String {
        var failure = WorkflowFailure.classify(error)
        failure.agent = agent
        let result = WorkflowCallResult(
            status: .failed, runID: UUID(),
            error: WorkflowRunError(nodeID: "step", reason: WorkflowFailure.message(error), failure: failure))
        return WorkflowToolCall.envelope(result, workflow: "Repo Digest", tool: "run_workflow")
    }

    private func toolFailed(_ tool: String, _ kind: String, _ message: String) -> Error {
        WorkflowNodeError.toolFailed(tool: tool, kind: kind, message: message, retryable: false)
    }

    @Test
    func aPermissionDenial_opensSystemSettings_forTheTool() {
        let result = failedEnvelope(toolFailed("calendar_events", "permission_denied", "Calendar is off."))
        #expect(WorkflowFailureRemedy.from(result: result) == .systemSettings(tool: "calendar_events"))
    }

    @Test
    func noFolderOrNotARepository_choosesAFolder_forTheStepsAgent() {
        let builder = Teammate.builder.templateID.uuidString
        let noFolder = failedEnvelope(
            toolFailed("git_status", "unavailable", FolderToolHelpers.noActiveFolderMessage + " Attach one."),
            agent: builder)
        #expect(WorkflowFailureRemedy.from(result: noFolder) == .chooseFolder(agent: builder))
        let notARepo = failedEnvelope(
            toolFailed("git_log", "execution_error", "fatal: not a git repository (or any of the parent directories)"),
            agent: builder)
        #expect(WorkflowFailureRemedy.from(result: notARepo) == .chooseFolder(agent: builder))
        let otherGitError = failedEnvelope(toolFailed("git_log", "execution_error", "fatal: bad revision"))
        #expect(WorkflowFailureRemedy.from(result: otherGitError) == nil)
    }

    @Test
    func aFailedSearch_opensSearchSettings() {
        let result = failedEnvelope(toolFailed("search", "unavailable", "No search provider answered."))
        #expect(WorkflowFailureRemedy.from(result: result) == .searchSettings)
    }

    @Test
    func noModel_choosesAModel_fromAStepOrFromSetUp() {
        #expect(
            WorkflowFailureRemedy.from(result: failedEnvelope(WorkflowNodeError.noModel(slot: "main")))
                == .chooseModel)
        let setup = WorkflowCallResult(status: .needsSetup, reasons: ["Writer: No default model is set."], noModel: true)
        let envelope = WorkflowToolCall.envelope(setup, workflow: "Repo Digest", tool: "run_workflow")
        #expect(WorkflowFailureRemedy.from(result: envelope) == .chooseModel)
        let message = JSONValue.parse(envelope)?.objectValue?["message"]?.stringValue ?? ""
        #expect(message.contains("Choose a Model"))
        #expect(!message.contains("Main window → Workflows"))
    }

    @Test
    func otherFailures_andOtherSetUp_offerNothing() {
        #expect(WorkflowFailureRemedy.from(result: failedEnvelope(WorkflowNodeError.outputMismatch(["x"]))) == nil)
        let setup = WorkflowCallResult(status: .needsSetup, reasons: ["Key: missing"])
        let envelope = WorkflowToolCall.envelope(setup, workflow: "Repo Digest", tool: "run_workflow")
        #expect(WorkflowFailureRemedy.from(result: envelope) == nil)
        #expect(JSONValue.parse(envelope)?.objectValue?["message"]?.stringValue?.contains("Workflows") == true)
        #expect(WorkflowFailureRemedy.from(result: ToolEnvelope.success(tool: "run_workflow", result: [:])) == nil)
    }

    @Test
    func theFailuresToolAndAgent_surviveARoundTrip() throws {
        let failure = NodeRunFailure(
            kind: "unavailable", retryable: false, errorType: "x", fixIn: .settings, tool: "git_log", agent: "Builder")
        let decoded = try JSONDecoder().decode(NodeRunFailure.self, from: JSONEncoder().encode(failure))
        #expect(decoded == failure)
        let old = try JSONDecoder().decode(
            NodeRunFailure.self, from: Data(#"{"kind":"unavailable","fix_in":"settings"}"#.utf8))
        #expect(old.tool == nil && old.agent == nil)
    }

    @Test
    func theDownloadStrip_showsInOtherChats_onlyWhenStalled() {
        #expect(PendingLocalSetupStrip.shows(ownsFirstRun: true, state: .downloading(progress: 0.2)))
        #expect(!PendingLocalSetupStrip.shows(ownsFirstRun: false, state: .downloading(progress: 0.2)))
        #expect(PendingLocalSetupStrip.shows(ownsFirstRun: false, state: .paused(progress: 0.4)))
        #expect(PendingLocalSetupStrip.shows(ownsFirstRun: false, state: .failed(error: "network")))
        #expect(!PendingLocalSetupStrip.shows(ownsFirstRun: false, state: nil))
    }
}
