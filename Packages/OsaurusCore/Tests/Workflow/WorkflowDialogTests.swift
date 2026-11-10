//
//  WorkflowDialogTests.swift
//  OsaurusCoreTests
//
//  Dialog nodes: what gets asked given saved answers and caller values,
//  the per-workflow queue, answer validation, and persistence of answers.
//

import Foundation
import Testing

@testable import OsaurusCore

struct DialogPlanTests {
    static let spec = DialogSpec(
        title: "Client",
        fields: [
            DialogField(key: "firm", label: "Firm", persistence: .remember),
            DialogField(key: "matter", label: "Matter"),
            DialogField(key: "partner", label: "Partner", persistence: .alwaysAsk(prefillLast: true)),
            DialogField(key: "rate", label: "Rate", type: .number, defaultValue: .number(300)),
        ])

    @Test
    func firstRun_asksEverythingWithDefaults() {
        let plan = DialogNodeExecutor.plan(spec: Self.spec, callInput: .object([:]), saved: [:])
        #expect(plan.known.isEmpty)
        #expect(plan.ask.map(\.key) == ["firm", "matter", "partner", "rate"])
        #expect(plan.prefill == ["rate": .number(300)])
    }

    @Test
    func rememberedAnswers_skipTheirFields_alwaysAskPrefillsTheLastOne() {
        let saved: [String: JSONValue] = ["firm": .string("Acme LLP"), "partner": .string("Kim"), "matter": .string("old")]
        let plan = DialogNodeExecutor.plan(spec: Self.spec, callInput: .object([:]), saved: saved)
        #expect(plan.known == ["firm": .string("Acme LLP")])
        #expect(plan.ask.map(\.key) == ["matter", "partner", "rate"])
        #expect(plan.prefill["partner"] == .string("Kim"))
        #expect(plan.prefill["matter"] == nil)
    }

    @Test
    func callerValues_overrideRememberedAndPrefillAlwaysAsk() {
        let plan = DialogNodeExecutor.plan(
            spec: Self.spec,
            callInput: .object(["firm": .string("Beta LLP"), "matter": .string("M-7"), "partner": .null]),
            saved: ["firm": .string("Acme LLP"), "partner": .string("Kim")])
        #expect(plan.known == ["firm": .string("Beta LLP")])
        #expect(plan.prefill["matter"] == .string("M-7"))
        #expect(plan.prefill["partner"] == .string("Kim"))
    }

    @Test
    func allRemembered_asksNothing() {
        let spec = DialogSpec(title: "x", fields: [DialogField(key: "firm", label: "Firm", persistence: .remember)])
        let plan = DialogNodeExecutor.plan(spec: spec, callInput: .object([:]), saved: ["firm": .string("A")])
        #expect(plan.ask.isEmpty)
        #expect(plan.known == ["firm": .string("A")])
    }

    @Test
    func fieldsDecodeFromTemplateJSON() throws {
        let json = """
            {"title": "Client", "fields": [
              {"key": "firm", "persistence": "remember"},
              {"key": "partner", "prefill_last": true},
              {"key": "tier", "type": "choice", "options": ["a", "b"], "required": false}
            ]}
            """
        let spec = try JSONDecoder().decode(DialogSpec.self, from: Data(json.utf8))
        #expect(spec.fields[0].persistence == .remember)
        #expect(spec.fields[1].persistence == .alwaysAsk(prefillLast: true))
        #expect(spec.fields[2].type == .choice)
        #expect(spec.fields[2].required == false)
    }
}

/// Both suites drive `DialogCoordinator.shared`.
@Suite(.serialized)
struct DialogSharedQueueTests {}

extension DialogSharedQueueTests {
@MainActor
struct DialogCoordinatorTests {

    static func dialog(workflowID: UUID, fields: [DialogField]) -> PendingDialog {
        PendingDialog(
            id: UUID(), runID: UUID(), workflowID: workflowID, workflowName: "Intake", nodeID: "ask",
            title: "Client", message: "", fields: fields, prefill: [:],
            caller: WorkflowCaller(kind: .user), createdAt: Date())
    }

    @Test
    func queuePerWorkflow_answersInOrderAndValidates() async throws {
        let coordinator = DialogCoordinator.shared
        coordinator.resetForTesting()
        defer { coordinator.resetForTesting() }
        let wf = UUID()
        let fields = [
            DialogField(key: "email", label: "Email"),
            DialogField(key: "count", label: "Count", type: .number, required: false),
        ]
        let first = Self.dialog(workflowID: wf, fields: fields)
        let second = Self.dialog(workflowID: wf, fields: fields)
        let other = Self.dialog(workflowID: UUID(), fields: fields)

        let t1 = Task { try await coordinator.present(first) }
        let t2 = Task { try await coordinator.present(second) }
        let t3 = Task { try await coordinator.present(other) }
        while coordinator.pending.count < 3 { await Task.yield() }

        #expect(Set(coordinator.presentable.map(\.id)) == [first.id, other.id])
        if case .failure(.notCurrent) = coordinator.answer(second.id, values: ["email": .string("x")]) {} else {
            Issue.record("a queued dialog behind another one is not answerable yet")
        }
        if case .failure(.invalid) = coordinator.answer(first.id, values: [:]) {} else {
            Issue.record("missing required field should be invalid")
        }
        if case .failure(let error) = coordinator.answer(
            first.id, values: ["email": .string("a@b.co"), "count": .string("3")])
        {
            Issue.record("valid answer rejected: \(error)")
        }
        let values = try await t1.value
        #expect(values == ["email": .string("a@b.co"), "count": .number(3)])
        #expect(coordinator.presentable.map(\.id).contains(second.id))

        coordinator.dismiss(second.id)
        await #expect(throws: WorkflowNodeError.self) { _ = try await t2.value }
        coordinator.cancelAll(runID: other.runID)
        await #expect(throws: (any Error).self) { _ = try await t3.value }
        #expect(coordinator.pending.isEmpty)
    }

    @Test
    func relayList_hidesSecretPrefills_andRemoteAnswersResolve() async throws {
        let coordinator = DialogCoordinator.shared
        coordinator.resetForTesting()
        defer { coordinator.resetForTesting() }
        let wf = UUID()
        var d = Self.dialog(
            workflowID: wf,
            fields: [DialogField(key: "email", label: "Email"), DialogField(key: "token", label: "Token", type: .secret)])
        d = PendingDialog(
            id: d.id, runID: d.runID, workflowID: wf, workflowName: d.workflowName, nodeID: "ask", title: d.title,
            message: d.message, fields: d.fields, prefill: ["email": .string("a@b.co"), "token": .string("sk")],
            caller: d.caller, createdAt: d.createdAt)
        let queued = Self.dialog(workflowID: wf, fields: [DialogField(key: "x", label: "X")])
        let t1 = Task { try await coordinator.present(d) }
        let t2 = Task { try await coordinator.present(queued) }
        while coordinator.pending.count < 2 { await Task.yield() }

        let list = try #require(JSONValue.parse(String(decoding: coordinator.remoteListJSON(), as: UTF8.self)))
        guard case .array(let items)? = list.objectValue?["dialogs"] else {
            Issue.record("expected a dialogs array")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].value(atPath: "prefill") == .object(["email": .string("a@b.co")]))
        #expect(items[0].value(atPath: "current") == .bool(true))
        #expect(items[1].value(atPath: "current") == .bool(false))

        if case .failure(.notCurrent) = coordinator.answerFromRemote(
            runID: queued.runID, nodeID: "ask", values: ["x": .string("1")], dismiss: false)
        {} else {
            Issue.record("queued dialog must not be answerable")
        }
        if case .failure(.notFound) = coordinator.answerFromRemote(
            runID: UUID(), nodeID: "ask", values: [:], dismiss: false)
        {} else {
            Issue.record("unknown run must be not found")
        }
        if case .failure(let e) = coordinator.answerFromRemote(
            runID: d.runID, nodeID: "ask", values: ["email": .string("z@y.co"), "token": .string("t")], dismiss: false)
        {
            Issue.record("remote answer rejected: \(e)")
        }
        #expect(try await t1.value == ["email": .string("z@y.co"), "token": .string("t")])
        _ = coordinator.answerFromRemote(runID: queued.runID, nodeID: "ask", values: nil, dismiss: true)
        await #expect(throws: WorkflowNodeError.self) { _ = try await t2.value }
    }

    @Test
    func cancellingThePresentingTask_removesTheDialog() async {
        let coordinator = DialogCoordinator.shared
        coordinator.resetForTesting()
        defer { coordinator.resetForTesting() }
        let d = Self.dialog(workflowID: UUID(), fields: [DialogField(key: "a", label: "A")])
        let task = Task { try await coordinator.present(d) }
        while coordinator.pending.isEmpty { await Task.yield() }
        task.cancel()
        _ = try? await task.value
        #expect(coordinator.pending.isEmpty)
    }
}

}

extension DialogSharedQueueTests {
struct DialogPersistenceTests {

    @Test
    func rememberedAnswersAreSaved_reusedNextRun_andMigrated() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            SavedAnswersStore.shared.resetForTesting()
            DialogCoordinator.shared.resetForTesting()
            defer {
                OsaurusPaths.overrideRoot = nil
                SavedAnswersStore.shared.resetForTesting()
                DialogCoordinator.shared.resetForTesting()
                try? FileManager.default.removeItem(at: root)
            }

            let spec = DialogSpec(
                title: "Client",
                fields: [
                    DialogField(key: "firm", label: "Firm", persistence: .remember),
                    DialogField(key: "matter", label: "Matter"),
                ])
            let node = WorkflowNode(id: "ask", name: "Ask", kind: .dialog(spec))
            let workflowID = UUID()

            func context(_ input: JSONValue) -> WorkflowNodeContext {
                WorkflowNodeContext(
                    runID: UUID(), workflowID: workflowID, workflowName: "Intake", node: node, input: input,
                    bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
                    caller: WorkflowCaller(kind: .user), workspace: root, attempt: 1, timeout: 60)
            }

            let firstRun = Task.detached {
                try await DialogNodeExecutor.run(spec: spec, context: context(.object([:])), awaitingUser: { _ in })
            }
            while DialogCoordinator.shared.pending.isEmpty { await Task.yield() }
            let shown = try #require(DialogCoordinator.shared.pending.first)
            #expect(shown.fields.map(\.key) == ["firm", "matter"])
            _ = DialogCoordinator.shared.answer(shown.id, values: ["firm": .string("Acme"), "matter": .string("M-1")])
            let out1 = try await firstRun.value.output
            #expect(out1 == .object(["firm": .string("Acme"), "matter": .string("M-1")]))
            #expect(
                SavedAnswersStore.shared.value(workflowID: workflowID, nodeID: "ask", fieldKey: "firm") == .string("Acme"))
            #expect(SavedAnswersStore.shared.value(workflowID: workflowID, nodeID: "ask", fieldKey: "matter") == nil)
            // Another dialog node asking the same key starts empty.
            #expect(SavedAnswersStore.shared.value(workflowID: workflowID, nodeID: "other", fieldKey: "firm") == nil)

            let secondRun = Task.detached {
                try await DialogNodeExecutor.run(spec: spec, context: context(.object([:])), awaitingUser: { _ in })
            }
            while DialogCoordinator.shared.pending.isEmpty { await Task.yield() }
            let shown2 = try #require(DialogCoordinator.shared.pending.first)
            #expect(shown2.fields.map(\.key) == ["matter"])
            _ = DialogCoordinator.shared.answer(shown2.id, values: ["matter": .string("M-2")])
            #expect(try await secondRun.value.output == .object(["firm": .string("Acme"), "matter": .string("M-2")]))

            var changed = spec
            changed.fields[0] = DialogField(key: "firm", label: "Firm", type: .number, persistence: .remember)
            SavedAnswersStore.shared.migrate(
                workflowID: workflowID,
                to: WorkflowDefinition(nodes: [WorkflowNode(id: "ask", name: "Ask", kind: .dialog(changed))]))
            #expect(SavedAnswersStore.shared.value(workflowID: workflowID, nodeID: "ask", fieldKey: "firm") == nil)
        }
    }

    /// Two dialog nodes that both remember `email` keep separate answers,
    /// and a file saved before answers were keyed by node is re-keyed.
    @Test
    func answersAreKeyedByNode_andLegacyFilesMigrate() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            SavedAnswersStore.shared.resetForTesting()
            defer {
                OsaurusPaths.overrideRoot = nil
                SavedAnswersStore.shared.resetForTesting()
                try? FileManager.default.removeItem(at: root)
            }
            let workflowID = UUID()
            let field = DialogField(key: "email", label: "Email", persistence: .remember)
            let store = SavedAnswersStore.shared
            store.save(workflowID: workflowID, nodeID: "sender", field: field, value: .string("me@a.test"))
            store.save(workflowID: workflowID, nodeID: "recipient", field: field, value: .string("you@b.test"))
            #expect(store.value(workflowID: workflowID, nodeID: "sender", fieldKey: "email") == .string("me@a.test"))
            #expect(store.value(workflowID: workflowID, nodeID: "recipient", fieldKey: "email") == .string("you@b.test"))
            #expect(store.all(workflowID: workflowID).map(\.id) == ["recipient/email", "sender/email"])

            store.clear(workflowID: workflowID, nodeID: "sender", fieldKey: "email")
            #expect(store.value(workflowID: workflowID, nodeID: "sender", fieldKey: "email") == nil)
            #expect(store.value(workflowID: workflowID, nodeID: "recipient", fieldKey: "email") == .string("you@b.test"))

            // Legacy file: bare field key, node recorded on the answer.
            let legacyID = UUID()
            let url = OsaurusPaths.workflowDirectory(legacyID).appendingPathComponent("answers.json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacy = """
                {"email":{"field_key":"email","node_id":"ask","type":"text","value":"old@c.test","updated_at":"2025-01-01T00:00:00Z"}}
                """
            try legacy.data(using: .utf8)!.write(to: url)
            #expect(store.value(workflowID: legacyID, nodeID: "ask", fieldKey: "email") == .string("old@c.test"))
            #expect(store.value(workflowID: legacyID, nodeID: "other", fieldKey: "email") == nil)
            let rewritten = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            #expect(Array(rewritten.keys) == ["ask/email"])
        }
    }

    @Test
    func callerValueCompletesARememberedNodeWithoutAForm() async throws {
        let spec = DialogSpec(title: "x", fields: [DialogField(key: "firm", label: "Firm", persistence: .remember)])
        let node = WorkflowNode(id: "ask", name: "Ask", kind: .dialog(spec))
        let input: JSONValue = .object(["firm": .string("Given")])
        let outcome = try await DialogNodeExecutor.run(
            spec: spec,
            context: WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "x", node: node, input: input,
                bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
                caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60),
            awaitingUser: { _ in Issue.record("should not wait for the user") })
        #expect(outcome.output == .object(["firm": .string("Given")]))
    }
}

}

@MainActor
struct WorkflowRunStoreTests {

    @Test
    func recordsAreLiveAndPersisted_newestFirst_andDeletable() throws {
        let db = WorkflowRunDatabase()
        try db.openInMemory()
        let store = WorkflowRunStore(database: db)
        let wf = UUID()
        func makeRun(_ offset: TimeInterval) -> WorkflowRun {
            WorkflowRun(
                workflowID: wf, workflowName: "Intake", templateID: UUID(), templateVersion: 1,
                caller: WorkflowCaller(kind: .user), input: .object(["a": .number(offset)]),
                nodeIDs: ["n"], startedAt: Date(timeIntervalSince1970: 1_000 + offset))
        }
        let older = makeRun(0)
        var newer = makeRun(10)
        store.record(older)
        newer.status = .completed
        newer.output = .object(["ok": .bool(true)])
        store.record(newer)

        #expect(store.runs(workflowID: wf).map(\.id) == [newer.id, older.id])

        let fresh = WorkflowRunStore(database: db)
        #expect(fresh.run(id: newer.id)?.output == .object(["ok": .bool(true)]))
        #expect(fresh.runs(workflowID: wf).count == 2)

        #expect(fresh.abandonedRuns().map(\.id) == [older.id])
        fresh.closeAbandonedRun(older, reason: "Osaurus quit before the run finished.")
        #expect(fresh.abandonedRuns().isEmpty)
        #expect(fresh.run(id: older.id)?.status == .cancelled)
        #expect(fresh.run(id: older.id)?.node("n")?.status == .skipped)
        #expect(fresh.live[older.id]?.status == .cancelled)
        #expect(fresh.live[newer.id] == nil)
        #expect(fresh.run(id: newer.id)?.status == .completed)
        #expect(WorkflowRunStore(database: db).run(id: older.id)?.status == .cancelled)

        fresh.deleteRuns(workflowID: wf)
        #expect(fresh.runs(workflowID: wf).isEmpty)
    }
}

@Suite(.serialized)
struct InstalledWorkflowStoreTests {

    @Test
    func installReusesTheSameTemplateAndPicksFreeToolNames() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer {
                store.resetForTesting()
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
            }

            let template = WF.template(WF.intake())
            let first = try store.install(template, bindings: InstallBindings(models: ["decision": "a/b"]))
            #expect(first.toolName == "workflow_client_intake")

            var v2 = template
            v2.version = 2
            let again = try store.install(v2.sealed(), bindings: InstallBindings(models: ["decision": "c/d"]))
            #expect(again.id == first.id)
            #expect(again.templateVersion == 2)
            #expect(store.workflows.count == 1)

            let other = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            #expect(other.id != first.id)
            #expect(other.toolName != first.toolName)
            #expect(store.workflow(named: "Client Intake")?.id == first.id)
            #expect(store.workflow(named: first.toolName)?.id == first.id)

            store.reload()
            #expect(store.workflow(id: first.id)?.bindings.models == ["decision": "c/d"])
        }
    }
}
