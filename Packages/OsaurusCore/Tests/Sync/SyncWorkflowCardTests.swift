//
//  SyncWorkflowCardTests.swift
//  OsaurusCoreTests
//
//  The workflow card another device shows for a chat's workflow call
//  (`workflow_runs`): steps named from the definition, the failed step
//  named in the error, and the status the call's result reports.
//

import Foundation
import OsaurusSync
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
        // A copy of the file, made from what was opened and checked, is what the core reads.
        #expect(payload.blobs[1].path != report.path)
        #expect(SyncWorkflowOutput.isStaged(payload.blobs[1].path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: payload.blobs[1].path)) == Data("# Q3".utf8))
        #expect(!SyncWorkflowOutput.isStaged(report.path))
        #expect(files[1].objectValue?["skipped"] == .string("missing"))

        // Same run, same files: the same digest, so the message isn't rewritten.
        #expect(SyncWorkflowOutput.payload(for: run, staging: staging).digest == payload.digest)
    }

    @Test func anOutputCarriesEachStepsDetailsLeavingOutSkippedOnes() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var run = Self.run()
        run.status = .completed
        var research = NodeRun(nodeID: "research", status: .done)
        research.model = "claude-sonnet"
        research.attempts = 2
        research.input = .object(["company": .string("Raycast")])
        research.output = .object(["notes": .string(String(repeating: "n", count: 5_000))])
        research.logs = ["searched"]
        research.toolCallRecords = [
            WorkflowToolCallRecord(
                name: "web_search", arguments: "{}", result: "3 hits", durationMs: 40, isError: false)
        ]
        run.nodes = [research, NodeRun(nodeID: "branch", status: .skipped)]
        let before = SyncWorkflowOutput.payload(for: run, staging: staging)

        let steps = try #require(before.object["steps"]?.arrayValue)
        #expect(steps.count == 1)
        let step = try #require(steps[0].objectValue)
        #expect(step["id"] == .string("research"))
        #expect(step["model"] == .string("claude-sonnet"))
        #expect(step["attempts"] == .number(2))
        #expect(step["input"] == .object(["company": .string("Raycast")]))
        // Over the steps' lower limit: a blob.
        #expect(step["output"]?.objectValue?["$blob"] == .number(0))
        #expect(step["logs"] == .array([.string("searched")]))
        let call = try #require(step["toolCalls"]?.arrayValue?.first?.objectValue)
        #expect(call["name"] == .string("web_search"))
        #expect(call["result"] == .string("3 hits"))

        // A step's details changing changes the digest, so the message is written again.
        run.nodes[0].logs.append("summarised")
        #expect(SyncWorkflowOutput.payload(for: run, staging: staging).digest != before.digest)
    }

    @Test func aStepsLogIsCappedAndAnOversizedOutputGoesWithoutLogsOrToolCalls() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var run = Self.run()
        run.status = .completed
        var chatty = NodeRun(nodeID: "chatty", status: .done)
        // Many short lines and one long one, the newest.
        chatty.logs = (0 ..< 1_000).map { "line \($0) " + String(repeating: "x", count: 80) }
        chatty.logs.append(String(repeating: "y", count: 2_000))
        run.nodes = [chatty]
        let capped = try #require(
            SyncWorkflowOutput.payload(for: run, staging: staging).object["steps"]?.arrayValue?.first?.objectValue)
        let logs = try #require(capped["logs"]?.arrayValue)
        #expect(logs.count == SyncWorkflowOutput.logLimit)
        // The newest lines, cut short.
        #expect(logs.dropLast().last?.stringValue?.hasPrefix("line 999 ") == true)
        #expect(logs.allSatisfy { ($0.stringValue?.count ?? 0) <= SyncWorkflowOutput.lineLimit })

        // Enough steps to pass the message limit even capped: none keeps its log, so the event stays small.
        run.nodes = (0 ..< 20).map { index in
            var node = chatty
            node.nodeID = "step\(index)"
            return node
        }
        let payload = SyncWorkflowOutput.payload(for: run, staging: staging)
        let steps = try #require(payload.object["steps"]?.arrayValue)
        #expect(steps.count == 20)
        #expect(steps.allSatisfy { $0.objectValue?["logs"] == nil })
        let size = try JSONEncoder().encode(JSONValue.object(payload.object)).count
        #expect(size < SyncWorkflowOutput.messageLimit)
    }

    @Test func aLinkInPlaceOfAFileIsNeverSent() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let secret = staging.appendingPathComponent("secret")
        try Data("key".utf8).write(to: secret)
        let link = staging.appendingPathComponent("report.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let copy = SyncWorkflowOutput.copyRegularFile(
            link.path, to: staging.appendingPathComponent("copy"), limit: 1_000)
        #expect(copy == .missing)
        let big = staging.appendingPathComponent("big")
        try Data(count: 2_000).write(to: big)
        #expect(
            SyncWorkflowOutput.copyRegularFile(big.path, to: staging.appendingPathComponent("copy"), limit: 1_000)
                == .tooLarge)
    }

    @Test func anOutputWithManyLargeStepsStaysUnderTheMessageLimit() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var run = Self.run()
        run.status = .failed
        // The run's own input and output just under their inline limit, and a long error.
        let nearly = String(repeating: "r", count: SyncWorkflowOutput.inlineLimit - 100)
        run.input = .object(["text": .string(nearly)])
        run.output = .object(["text": .string(nearly)])
        run.error = WorkflowRunError(nodeID: "step0", reason: String(repeating: "e", count: 10_000))
        // Many steps, each with input and output just under the steps' limit and a long error.
        let step = String(repeating: "s", count: SyncWorkflowOutput.stepInlineLimit - 100)
        run.nodes = (0 ..< 200).map { index in
            var node = NodeRun(nodeID: "step\(index)", status: .done)
            node.input = .object(["text": .string(step)])
            node.output = .object(["text": .string(step)])
            node.error = String(repeating: "x", count: 5_000)
            node.logs = ["one"]
            return node
        }
        let payload = SyncWorkflowOutput.payload(for: run, staging: staging)
        #expect(SyncWorkflowOutput.encodedSize(payload.object) <= SyncWorkflowOutput.messageLimit)
        // Every step is still listed, the oldest without their details.
        let steps = try #require(payload.object["steps"]?.arrayValue)
        #expect(steps.count == 200)
        #expect(steps.first?.objectValue?["trimmed"] == .bool(true))
        // Every blob referred to is one of the payload's, and staged files no longer referred to are gone.
        let kept = Set(payload.blobs.map(\.path))
        let staged = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .map { staging.appendingPathComponent($0).path }
        #expect(Set(staged) == kept)
        // The same run gives the same digest.
        #expect(SyncWorkflowOutput.payload(for: run, staging: staging).digest == payload.digest)
    }

    @Test
    func eachRunIsItsOwnEntryWrittenOnlyWhenItChanges() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let scope = try core.createConversation(title: "Manage", replication: .synced)
            func run(_ id: String, _ status: String) -> SyncDeviceFeedContract.WorkflowRunEntry {
                SyncDeviceFeedContract.WorkflowRunEntry(
                    workflowId: "w", card: SyncWorkflowCard(runId: id, name: "Report", status: status, steps: []),
                    caller: "user", startedMs: 1, finishedMs: nil)
            }
            func write(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry]) throws -> (Int, Int) {
                let conversation = try #require(try core.conversation(scope: scope))
                return try SyncWorkflowRunsFeed.write(runs, to: conversation, core: core)
            }
            // The old whole list, cleared on the first write.
            try core.setConversationAppData(
                scope: scope, namespace: SyncDeviceFeedContract.workflowRunsNamespace, bytes: Data("{}".utf8))

            #expect(try write([run("a", "running"), run("b", "completed")]) == (2, 1))
            // Nothing changed: nothing written.
            #expect(try write([run("a", "running"), run("b", "completed")]) == (0, 0))
            // One run moving on rewrites only that run; one no longer listed is removed.
            #expect(try write([run("a", "completed")]) == (1, 1))
            let conversation = try #require(try core.conversation(scope: scope))
            let prefix = SyncDeviceFeedContract.workflowRunNamespacePrefix
            #expect(conversation.appData.map(\.namespace).filter { $0.hasPrefix(prefix) } == [prefix + "a"])
            #expect(conversation.appData(SyncDeviceFeedContract.workflowRunsNamespace) == nil)
        }
    }

    @Test
    func pinsAreOneEntryPerWorkflowAndRunWritesLeaveThemAlone() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let scope = try core.createConversation(title: "Manage", replication: .synced)
            func conversation() throws -> Conversation { try #require(try core.conversation(scope: scope)) }

            try SyncWorkflowPins.set("A", pinned: true, nowMs: 10, conversation: conversation(), core: core)
            try SyncWorkflowPins.set("b", pinned: true, nowMs: 20, conversation: conversation(), core: core)
            #expect(SyncWorkflowPins.pins(in: try conversation()) == ["a": 10, "b": 20])

            // Writing (and clearing) the recent runs leaves pins alone.
            _ = try SyncWorkflowRunsFeed.write([], to: conversation(), core: core)
            try SyncWorkflowPins.set("b", pinned: false, nowMs: 30, conversation: conversation(), core: core)
            #expect(SyncWorkflowPins.pins(in: try conversation()) == ["a": 10])
        }
    }
}
