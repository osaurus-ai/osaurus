//
//  SyncWorkflowCardTests.swift
//  OsaurusCoreTests
//
//  The workflow card another device shows for a chat's workflow call
//  (`workflow_runs`): steps named from the definition, the failed step
//  named in the error, and the status the call's result reports.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Sync workflow card")
struct SyncWorkflowCardTests {

    private static func definition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["topic": WF.string]),
            outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "draft", name: "Draft Notes",
                    kind: .code(CodeSpec(source: "async function run(i){ return {} }"))),
                WorkflowNode(
                    id: "save", name: "Save Notes", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write")))),
            ],
            edges: [WorkflowEdge(from: "draft", to: "save")])
    }

    private static func run() -> WorkflowRun {
        WorkflowRun(
            workflowID: UUID(), workflowName: "Meeting Notes", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .agent, toolCallID: "call_1"), input: .object([:]),
            nodeIDs: ["draft", "save"], startedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func namesEachStepAndTheFailedOne() throws {
        var run = Self.run()
        run.update("draft") { $0.status = .done }
        run.update("save") { $0.status = .failed }
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "save", reason: "disk full")

        let card = SyncWorkflowCard.make(run, definition: Self.definition())
        #expect(card.runId == run.id.uuidString.lowercased())
        #expect(card.name == "Meeting Notes")
        #expect(card.status == "failed")
        #expect(card.steps.map(\.name) == ["Draft Notes", "Save Notes"])
        #expect(card.steps.map(\.status) == ["done", "failed"])
        #expect(card.error == "Save Notes: disk full")

        // Without the definition (uninstalled since), the step ids stand in.
        #expect(SyncWorkflowCard.make(run, definition: nil).steps.map(\.name) == ["draft", "save"])

        let json = try #require(card.jsonObject)
        #expect(json["runId"] as? String == card.runId)
        #expect((json["steps"] as? [[String: Any]])?.first?["status"] as? String == "done")
    }

    @Test func takesTheStatusTheResultReports() {
        var run = Self.run()
        run.update("draft") { $0.status = .done }
        run.update("save") { $0.status = .running }
        let card = SyncWorkflowCard.make(run, definition: Self.definition())
        #expect(card.status == "running")

        let done = ToolEnvelope.success(tool: "run_workflow", result: ["status": "completed", "run_id": card.runId])
        let settled = card.settled(by: done)
        #expect(settled.status == "completed")
        #expect(settled.steps.map(\.status) == ["done", "done"])

        let failed = ToolEnvelope.failure(
            kind: .executionError, message: "Meeting Notes failed", tool: "run_workflow",
            metadata: ["status": "failed", "run_id": card.runId])
        #expect(card.settled(by: failed).status == "failed")
        #expect(card.settled(by: failed).steps.map(\.status) == ["done", "running"])

        #expect(card.settled(by: nil) == card)
    }

    @Test func aPhoneRunOfAWorkflowThatIsNotInstalledIsRefused() {
        #expect(SyncWorkflowLibrary.start(workflowId: nil, values: nil) == .failure(.notFound))
        #expect(SyncWorkflowLibrary.start(workflowId: UUID().uuidString, values: nil) == .failure(.notFound))
    }

    @Test func runWorkflowRequestsDecodeTheirInput() throws {
        let json = #"{"id":"r1","op":"runWorkflow","workflowId":"abc","input":{"topic":"Q3"},"requestedMs":1}"#
        let request = try JSONDecoder().decode(SyncDeviceFeedContract.ManageRequest.self, from: Data(json.utf8))
        #expect(request.op == .runWorkflow)
        #expect(request.workflowId == "abc")
        #expect(request.input?.objectValue?["topic"]?.stringValue == "Q3")
    }

    @Test func anOutputCarriesItsInputItsOutputAndItsFiles() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let report = staging.appendingPathComponent("report.md")
        try Data("# Q3".utf8).write(to: report)

        var run = Self.run()
        run.status = .completed
        run.output = .object(["text": .string(String(repeating: "a", count: 20_000))])
        run.artifacts = [
            WorkflowArtifact(source: .shared, filename: "report.md", path: report.path, fileSize: 4),
            WorkflowArtifact(source: .shared, filename: "gone.md", path: staging.appendingPathComponent("gone").path),
        ]
        let payload = SyncWorkflowOutput.payload(for: run, staging: staging)

        #expect(payload.object["status"] == .string("completed"))
        #expect(payload.object["input"] == .object([:]))
        // The long output went to a blob, staged where it can be cleaned up after.
        #expect(payload.object["output"]?.objectValue?["$blob"] == .number(0))
        #expect(SyncWorkflowOutput.isStaged(payload.blobs[0].path))
        let files = try #require(payload.object["files"]?.arrayValue)
        #expect(files[0].objectValue?["blob"] == .number(1))
        #expect(payload.blobs[1].path == report.path)
        #expect(!SyncWorkflowOutput.isStaged(report.path))
        #expect(files[1].objectValue?["skipped"] == .string("missing"))

        // Same run, same files: the same digest, so the message isn't rewritten.
        #expect(SyncWorkflowOutput.payload(for: run, staging: staging).digest == payload.digest)
    }
}
