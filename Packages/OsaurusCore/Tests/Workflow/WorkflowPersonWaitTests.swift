//
//  WorkflowPersonWaitTests.swift
//  OsaurusCoreTests
//
//  A step's timeout counts its own work, never a person answering its
//  form or folder card. A form waits until it is answered unless it sets
//  `expires_after`, and what was typed into a form that closed unanswered
//  comes back the next time it is asked.
//

import Foundation
import Testing

@testable import OsaurusCore

extension DialogSharedQueueTests {
struct WorkflowPersonWaitTests {

    static func form(
        _ id: String = "ask", timeout: TimeInterval = 60, expiresAfter: TimeInterval? = nil,
        fields: [DialogField] = [DialogField(key: "jd", label: "Job description", type: .longText)],
        onError: NodeErrorPolicy = .fail
    ) -> WorkflowNode {
        WorkflowNode(
            id: id, name: "Ask for role and job description",
            kind: .dialog(DialogSpec(title: "Role", fields: fields, expiresAfter: expiresAfter)),
            timeout: timeout, retry: RetryPolicy(maxAttempts: 1), onError: onError)
    }

    /// Forms run through the real dialog executor; every other step returns `{}`.
    static let executor = ClosureExecutor { ctx, awaiting in
        if case .dialog(let spec) = ctx.node.kind {
            return try await DialogNodeExecutor.run(spec: spec, context: ctx, awaitingUser: awaiting)
        }
        return WorkflowNodeOutcome(output: .object([:]))
    }

    static func request(_ def: WorkflowDefinition, workflowID: UUID) -> WorkflowRunner.Request {
        WorkflowRunner.Request(
            workflowID: workflowID, workflowName: "Screener", template: WF.template(def),
            caller: WorkflowCaller(kind: .test), input: .object([:]), workspace: WF.tempDir())
    }

    static func shownDialog(workflowID: UUID) async throws -> PendingDialog {
        for _ in 0 ..< 5000 {
            if let dialog = await MainActor.run(body: {
                DialogCoordinator.shared.pending.first { $0.workflowID == workflowID }
            }) {
                return dialog
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CancellationError()
    }

    @Test
    func formAnsweredLongAfterItsStepTimeout_completes() async throws {
        let workflowID = UUID()
        let def = WorkflowDefinition(nodes: [Self.form(timeout: 0.5)])
        let running = Task { await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: Self.executor).execute() }
        let shown = try await Self.shownDialog(workflowID: workflowID)
        // The person spends three times the step's timeout writing.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let answered = await MainActor.run {
            DialogCoordinator.shared.answer(shown.id, values: ["jd": .string("Senior iOS engineer")])
        }
        #expect((try? answered.get()) != nil)
        let run = await running.value
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(run.node("ask")?.output == .object(["jd": .string("Senior iOS engineer")]))
    }

    @Test
    func folderCardAnsweredLongAfterItsStepTimeout_completes() async throws {
        let workflowID = UUID()
        let target = WF.tempDir().appendingPathComponent("Report.pdf").path
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "save", name: "Save", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                    input: .object([:]), timeout: 0.5, retry: RetryPolicy(maxAttempts: 1))
            ])
        let running = Task {
            await WorkflowRunner(
                request: Self.request(def, workflowID: workflowID),
                executor: ClosureExecutor { ctx, _ in
                    let ask = try #require(ctx.requestFolderGrant)
                    #expect(try await ask(target, .write) == .allowOnce)
                    return WorkflowNodeOutcome(output: .object([:]))
                }
            ).execute()
        }
        let shown = try await Self.shownDialog(workflowID: workflowID)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await MainActor.run {
            DialogCoordinator.shared.answer(
                shown.id,
                values: [WorkflowFolderGrantCoordinator.decisionKey: .string(WorkflowFolderGrantDecision.allowOnce.label)])
        }
        let run = await running.value
        #expect(run.status == .completed, "\(String(describing: run.error))")
    }

    @Test
    func formWithExpiresAfter_asTheFirstStep_failsAsExpired() async throws {
        let workflowID = UUID()
        let def = WorkflowDefinition(nodes: [Self.form(timeout: 60, expiresAfter: 0.5)])
        let started = Date()
        let run = await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: Self.executor)
            .execute()
        #expect(run.status == .failed)
        #expect(run.error?.nodeID == "ask")
        #expect(run.error?.reason.contains("Nobody answered the form") == true, "\(run.error?.reason ?? "")")
        #expect(run.node("ask")?.failure?.kind == "form_expired")
        #expect(run.node("ask")?.failure?.fixIn == .person)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(await MainActor.run { DialogCoordinator.shared.pending.allSatisfy { $0.workflowID != workflowID } })
    }

    @Test
    func formWithExpiresAfter_afterACodeStep_continuesWhenTheStepSaysSo() async throws {
        let workflowID = UUID()
        let def = WorkflowDefinition(
            nodes: [
                WF.code("prep"),
                Self.form(expiresAfter: 0.5, onError: .continue),
                WF.code("after", input: .object(["error": "{{nodes.ask.output.error.kind}}"])),
            ],
            edges: [WorkflowEdge(from: "prep", to: "ask"), WorkflowEdge(from: "ask", to: "after", on: .always)])
        let run = await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: Self.executor)
            .execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(run.node("ask")?.status == .failed)
        #expect(run.node("after")?.status == .done)
        #expect(run.node("after")?.input == .object(["error": .string("form_expired")]))
    }

    @Test
    func resumedForm_withExpiresAfter_waitsOnlyWhatIsLeft() async throws {
        let def = WorkflowDefinition(
            outputSchema: WF.object(["jd": WF.string]),
            nodes: [Self.form(expiresAfter: 61)],
            output: .object(["jd": "{{nodes.ask.output.jd}}"]))
        var request = WorkflowRunnerTests.request(def, input: .object([:]), caller: WorkflowCaller(kind: .test))
        request.resuming = WorkflowRunnerTests.abandonedAsk(request, waitingSince: Date(timeIntervalSinceNow: -60))
        let started = Date()
        let run = await WorkflowRunner(request: request, executor: Self.executor).execute()
        #expect(run.status == .failed)
        #expect(run.node("ask")?.failure?.kind == "form_expired")
        #expect(Date().timeIntervalSince(started) < 10, "it had about a second of its 61 left")
    }

    @Test
    func resumedForm_whoseExpiresAfterPassedWhileTheAppWasClosed_expiresAtOnce() async throws {
        let def = WorkflowDefinition(nodes: [Self.form(expiresAfter: 30)])
        var request = WorkflowRunnerTests.request(def, input: .object([:]), caller: WorkflowCaller(kind: .test))
        request.resuming = WorkflowRunnerTests.abandonedAsk(request, waitingSince: Date(timeIntervalSinceNow: -3_600))
        let workflowID = request.workflowID
        let run = await WorkflowRunner(request: request, executor: Self.executor).execute()
        #expect(run.status == .failed)
        #expect(run.node("ask")?.failure?.kind == "form_expired")
        #expect(await MainActor.run { DialogCoordinator.shared.pending.allSatisfy { $0.workflowID != workflowID } })
    }

    @Test
    func whatWasTypedComesBackOnRetry_withoutSecrets_untilTheFormIsAnswered() async throws {
        let workflowID = UUID()
        let fields = [
            DialogField(key: "jd", label: "Job description", type: .longText),
            DialogField(key: "token", label: "Token", type: .secret, required: false),
        ]
        let def = WorkflowDefinition(nodes: [Self.form(fields: fields)])

        let first = Task { await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: Self.executor).execute() }
        let shown = try await Self.shownDialog(workflowID: workflowID)
        await MainActor.run {
            let answer = WorkflowDialogAnswer(dialog: shown)
            answer.values["jd"] = .string("Two pages of requirements")
            answer.values["token"] = .string("sk-secret")
        }
        first.cancel()
        #expect(await first.value.status == .cancelled)

        let second = Task { await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: Self.executor).execute() }
        let again = try await Self.shownDialog(workflowID: workflowID)
        #expect(again.runID != shown.runID)
        #expect(again.prefill["jd"] == .string("Two pages of requirements"))
        #expect(again.prefill["token"] == nil)
        _ = await MainActor.run {
            DialogCoordinator.shared.answer(again.id, values: ["jd": .string("Two pages of requirements")])
        }
        #expect(await second.value.status == .completed)
        #expect(await MainActor.run { DialogCoordinator.shared.draft(workflowID: workflowID, nodeID: "ask") }.isEmpty)
    }

    /// A caller parked on the run reads the form the moment the run says
    /// it is waiting; the form has to be there by then.
    @Test
    func theFormIsQueued_beforeTheRunSaysItIsWaiting() async throws {
        actor Seen { var queued: [Bool] = []; func add(_ v: Bool) { queued.append(v) } }
        let seen = Seen()
        let workflowID = UUID()
        let executor = ClosureExecutor { ctx, awaiting in
            guard case .dialog(let spec) = ctx.node.kind else { return WorkflowNodeOutcome(output: .object([:])) }
            return try await DialogNodeExecutor.run(spec: spec, context: ctx) { waiting in
                if waiting {
                    await seen.add(
                        await MainActor.run { DialogCoordinator.shared.pending.contains { $0.workflowID == workflowID } })
                }
                await awaiting(waiting)
            }
        }
        let def = WorkflowDefinition(nodes: [Self.form()])
        let running = Task { await WorkflowRunner(request: Self.request(def, workflowID: workflowID), executor: executor).execute() }
        let shown = try await Self.shownDialog(workflowID: workflowID)
        _ = await MainActor.run { DialogCoordinator.shared.answer(shown.id, values: ["jd": .string("Barista")]) }
        #expect(await running.value.status == .completed)
        #expect(await seen.queued == [true])
    }
}
}

struct DialogExpiryValidationTests {

    @Test
    func expiresAfter_mustBePositive_andMayBeSetOnAnyForm() {
        func issues(_ expiresAfter: TimeInterval?) -> [String] {
            let def = WorkflowDefinition(
                nodes: [DialogSharedQueueTests.WorkflowPersonWaitTests.form(expiresAfter: expiresAfter)],
                output: .object([:]))
            return WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
                .filter { $0.contains("expires_after") }
        }
        #expect(issues(nil).isEmpty)
        #expect(issues(3_600).isEmpty, "a form that opens the workflow may expire too")
        #expect(issues(0).count == 1)
        #expect(issues(-5).count == 1)
        #expect(issues(.infinity).count == 1)
    }

    @Test
    func expiresAfter_roundTripsThroughJSON() throws {
        let json = #"{"title": "Role", "fields": [{"key": "jd"}], "expires_after": 900}"#
        let spec = try JSONDecoder().decode(DialogSpec.self, from: Data(json.utf8))
        #expect(spec.expiresAfter == 900)
        let encoded = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(DialogSpec.self, from: encoded).expiresAfter == 900)
        let plain = try JSONDecoder().decode(DialogSpec.self, from: Data(#"{"fields": [{"key": "jd"}]}"#.utf8))
        #expect(plain.expiresAfter == nil)
    }
}
