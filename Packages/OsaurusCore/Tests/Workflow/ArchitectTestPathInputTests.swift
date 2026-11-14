//
//  ArchitectTestPathInputTests.swift
//  OsaurusCoreTests
//
//  `workflow_test` fills a draft's folder and file inputs the Architect
//  left out: an earlier test's pick while it still exists, else what the
//  person picks in a form card in the chat. The Architect never asks for a
//  typed path.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ArchitectTestPathInputTests {

    private static func folderField(_ title: String) -> JSONValue {
        .object(["type": .string("string"), "format": .string("folder"), "title": .string(title)])
    }

    /// `svgs` is required, `extra` optional but bound by a step, `unused`
    /// optional and never bound; `title` is plain text.
    private static func definition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(
                [
                    "svgs": folderField("Folder with SVGs"), "extra": folderField("Extra"),
                    "unused": folderField("Unused"), "title": WF.string,
                ],
                required: ["svgs", "title"]),
            outputSchema: WF.object(["exists": WF.bool]),
            nodes: [
                WorkflowNode(
                    id: "lookup", name: "Lookup",
                    kind: .state(StateSpec(action: .get, table: "seen", key: "{{input.svgs}}|{{input.extra}}")))
            ],
            output: .object(["exists": "{{nodes.lookup.output.exists}}"]))
    }

    private func asArchitect<T>(session: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) { try await body() }
        }
    }

    /// The picker cards a test showed. The shared coordinator is left alone
    /// so suites that count its forms are not disturbed.
    @MainActor
    private final class PickerLog {
        var shown: [PendingDialog] = []
    }

    /// Runs `body` with the picker answered by `answer`, or dismissed when
    /// it is nil.
    private func withPicker<T>(
        _ log: PickerLog, answer: [String: JSONValue]?, _ body: () async throws -> T
    ) async rethrows -> T {
        let previous = WorkflowTestTool.presentPathDialog
        WorkflowTestTool.presentPathDialog = { dialog in
            log.shown.append(dialog)
            guard let answer else { throw WorkflowNodeError.dialogDismissed }
            return answer
        }
        defer { WorkflowTestTool.presentPathDialog = previous }
        return try await body()
    }

    // MARK: - Which fields

    @Test
    func missingPathFields_areRequiredOrBoundFolders_withNoValue() {
        let def = Self.definition()
        #expect(Set(WorkflowDraftTester.missingPathFields(def, input: .object([:])).map(\.key)) == ["svgs", "extra"])
        let some = WorkflowDraftTester.missingPathFields(def, input: .object(["svgs": .string("/tmp")]))
        #expect(some.map(\.key) == ["extra"])
        #expect(some.allSatisfy { $0.type == .folder })
        let blank = WorkflowDraftTester.missingPathFields(def, input: .object(["svgs": .string("  "), "extra": .string("/tmp")]))
        #expect(blank.map(\.key) == ["svgs"])
    }

    @Test
    func reusablePick_isTheNewestExistingPathOfTheRightKind() throws {
        let folder = WF.tempDir()
        let file = folder.appendingPathComponent("a.svg")
        try Data("<svg/>".utf8).write(to: file)
        let field = DialogField(key: "svgs", label: "Folder", type: .folder)
        let previous: [JSONValue] = [
            .object(["svgs": .string("/nonexistent/\(UUID().uuidString)")]),
            .object(["svgs": .string(file.path)]),
            .object(["svgs": .string(folder.path)]),
        ]
        #expect(WorkflowDraftTester.reusablePick(field, previousInputs: previous) == folder.path)
        let fileField = DialogField(key: "svgs", label: "File", type: .file)
        #expect(WorkflowDraftTester.reusablePick(fileField, previousInputs: previous) == file.path)
        #expect(WorkflowDraftTester.reusablePick(field, previousInputs: [.object(["svgs": .string("relative")])]) == nil)
    }

    // MARK: - workflow_test

    @Test
    func workflowTest_asksForMissingFolders_thenRunsWithThePick_andLaterTestsReuseIt() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.definition() }
        defer { WorkflowRunStore.shared.deleteRuns(workflowID: draft.id) }
        let svgs = WF.tempDir().path
        let extra = WF.tempDir().path
        let log = PickerLog()

        let text = try await withPicker(log, answer: ["svgs": .string(svgs), "extra": .string(extra)]) {
            try await asArchitect(session: session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {"title": "Dinos"}}"#)
            }
        }
        let dialog = try #require(log.shown.first)
        #expect(Set(dialog.fields.map(\.key)) == ["svgs", "extra"])
        #expect(dialog.fields.allSatisfy { $0.type == .folder && $0.required })
        #expect(dialog.workflowID == draft.id)
        #expect(dialog.caller.kind == .test)
        #expect(dialog.caller.sessionID == session, "the card shows in the Architect's chat")
        #expect(dialog.nodeID == WorkflowTestTool.pathDialogNodeID)
        let answers: [String: JSONValue] = ["svgs": .string(svgs), "extra": .string(extra)]
        #expect(
            JSONSchemaValidator.validate(.object(answers), against: dialog.answerSchema).isEmpty,
            "the coordinator accepts a picked path")

        let envelope = try #require(JSONValue.parse(text)?.objectValue, "\(text.prefix(300))")
        let result = try #require(envelope["result"]?.objectValue, "\(envelope)")
        #expect(result["picked_inputs"]?.objectValue?["svgs"]?.stringValue == svgs)
        #expect(result["picked_inputs"]?.objectValue?["extra"]?.stringValue == extra)
        let runID = try #require(result["run_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let run = try #require(WorkflowRunStore.shared.run(id: runID))
        #expect(run.input.objectValue?["svgs"]?.stringValue == svgs)
        #expect(run.input.objectValue?["title"]?.stringValue == "Dinos")

        // The next test asks nobody and says which picks it reused.
        let againText = try await withPicker(log, answer: [:]) {
            try await asArchitect(session: session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {"title": "Dinos"}}"#)
            }
        }
        let again = try #require(JSONValue.parse(againText)?.objectValue?["result"]?.objectValue, "\(againText.prefix(300))")
        #expect(again["reused_inputs"]?.objectValue?["svgs"]?.stringValue == svgs)
        #expect(again["picked_inputs"] == nil)
        #expect(log.shown.count == 1)
    }

    @Test
    func workflowTest_whenThePersonClosesThePicker_runsNothing_andSaysNotToAskForAPath() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.definition() }

        let log = PickerLog()
        let text = try await withPicker(log, answer: nil) {
            try await asArchitect(session: session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {"title": "Dinos"}}"#)
            }
        }
        #expect(log.shown.count == 1)
        let envelope = try #require(JSONValue.parse(text)?.objectValue, "\(text.prefix(300))")
        #expect(envelope["ok"]?.boolValue == false)
        #expect(envelope["kind"]?.stringValue == ToolEnvelope.Kind.userDenied.rawValue)
        #expect(envelope["message"]?.stringValue?.contains("Do not ask them to type a path") == true)
        #expect(!WorkflowRunStore.shared.recentRuns().contains { $0.workflowID == draft.id })
    }

    @Test
    func workflowTest_onADraftWithIssues_reportsThemWithoutAsking() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        var broken = Self.definition()
        broken.edges = [WorkflowEdge(from: "lookup", to: "missing")]
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = broken }

        let log = PickerLog()
        let refused = try await withPicker(log, answer: [:]) {
            try await asArchitect(session: session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {"title": "Dinos"}}"#)
            }
        }
        #expect(refused.contains("issues to fix"), "\(refused.prefix(300))")
        #expect(log.shown.isEmpty)
    }
}
