//
//  WorkflowWorkModeResumeTests.swift
//  OsaurusCoreTests
//
//  Runs that outlive a turn or a launch: a Work Mode task parked on
//  several forms at once, the parked set saved with the session and picked
//  up again on load, and runs a previous launch left open resumed from
//  their saved node outputs on relaunch.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowWorkModeResumeTests {

    private func withStore(_ body: @MainActor (InstalledWorkflowStore) async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            try await body(store)
        }
    }

    private func withSilentNotifier(_ body: @MainActor () async throws -> Void) async rethrows {
        let previous = WorkflowDialogNotifier.onPresented
        WorkflowDialogNotifier.onPresented = { _ in }
        defer {
            WorkflowDialogNotifier.onPresented = previous
            DialogCoordinator.shared.resetForTesting()
        }
        try await body()
    }

    private static func askOnly() -> WorkflowDefinition {
        let spec = DialogSpec(title: "Client", fields: [DialogField(key: "firm", label: "Firm")])
        return WorkflowDefinition(
            outputSchema: WF.object(["firm": WF.string]),
            nodes: [WorkflowNode(id: "ask", name: "Ask", kind: .dialog(spec))],
            output: .object(["firm": "{{nodes.ask.output.firm}}"]))
    }

    /// A transcript whose assistant turn issued `calls` workflow calls, each
    /// answered `awaiting_user` for its run, as the park intercept writes.
    private static func parkedTranscript(
        _ session: ChatSession, calls: [(callId: String, runID: UUID, tool: String)]
    ) {
        let user = ChatTurn(role: .user, content: "Run both")
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.toolCalls = calls.map {
            ToolCall(id: $0.callId, type: "function", function: ToolCallFunction(name: $0.tool, arguments: "{}"))
        }
        var turns = [user, assistant]
        for call in calls {
            let parked = WorkflowToolCall.envelope(
                WorkflowCallResult(status: .awaitingUser, runID: call.runID), workflow: "Ask", tool: call.tool)
            assistant.setToolResult(parked, for: call.callId)
            let tool = ChatTurn(role: .tool, content: parked)
            tool.toolCallId = call.callId
            turns.append(tool)
        }
        session.turns = turns
    }

    private static func toolTurn(_ session: ChatSession, callId: String) -> ChatTurn? {
        session.turns.last { $0.role == .tool && $0.toolCallId == callId }
    }

    /// The run publishes `awaiting_user` just before its form reaches the
    /// coordinator's queue; give the form a moment to land.
    private static func pendingDialog(_ runID: UUID?) async -> PendingDialog? {
        for _ in 0 ..< 200 {
            if let dialog = DialogCoordinator.shared.pending.first(where: { runID == nil || $0.runID == runID }) {
                return dialog
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    private static func answer(_ runID: UUID, firm: String) async throws {
        let dialog = try #require(await pendingDialog(runID))
        if case .failure(let error) = DialogCoordinator.shared.answer(dialog.id, values: ["firm": .string(firm)]) {
            throw error
        }
    }

    /// Run records round-trip through JSON, which keeps whole seconds.
    private static func sameSecond(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 1 }

    // MARK: - Routed runs from a chat

    /// A routed run from a foreground chat parks the turn on a form; the
    /// same call unrouted (a custom agent's workflow tool) holds the turn
    /// until the form is answered.
    @Test
    func aRoutedChatRunParksOnAForm_anUnroutedOneWaits() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let caller = WorkflowCaller(kind: .orchestrator, sessionID: "chat-1", toolCallID: "call-routed")
                let parked = await WorkflowToolCall.run(
                    workflowID: installed.id, input: .object([:]), caller: caller, tool: "run_workflow", routed: true)
                #expect(parked.contains(WorkflowCallResult.Status.awaitingUser.rawValue))
                #expect(parked.contains("resumes with the result"))
                let parkedRun = try #require(WorkflowToolCall.runID(inResult: parked))
                try await Self.answer(parkedRun, firm: "Acme")
                #expect(await WorkflowRunService.shared.result(of: parkedRun)?.status == .completed)

                var inline = caller
                inline.toolCallID = "call-inline"
                let waiting = Task { @MainActor in
                    await WorkflowToolCall.run(
                        workflowID: installed.id, input: .object([:]), caller: inline, tool: "run_workflow")
                }
                let inlineRun = try #require(await Self.pendingDialog(nil)?.runID)
                try await Self.answer(inlineRun, firm: "Globex")
                let finished = await waiting.value
                #expect(finished.contains(WorkflowCallResult.Status.completed.rawValue))
                #expect(finished.contains("Globex"))
            }
        }
    }

    // MARK: - Several parked calls in one turn

    @Test
    func twoParkedCalls_eachLandTheirResult_andTheTaskWaitsForBoth() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let caller = WorkflowCaller(kind: .agent, background: true)
                // One workflow shows one form at a time, oldest first. Start
                // the second run only after the first form is waiting, so
                // answering the first is the head of that queue.
                let first = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                #expect(await WorkflowRunService.shared.settledOrParked(first)?.status == .awaitingUser)
                let second = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                #expect(await WorkflowRunService.shared.settledOrParked(second)?.status == .awaitingUser)

                let session = ChatSession()
                Self.parkedTranscript(
                    session,
                    calls: [("call-a", first, installed.toolName), ("call-b", second, installed.toolName)])
                session.parkOnWorkflowRun(first, callId: "call-a", toolName: installed.toolName)
                session.parkOnWorkflowRun(second, callId: "call-b", toolName: installed.toolName)
                #expect(session.awaitingWorkflowRuns.count == 2, "parking the second call keeps the first")
                #expect(session.parkedWorkflowCalls.map(\.callId) == ["call-a", "call-b"])

                try await Self.answer(first, firm: "Acme")
                _ = await WorkflowRunService.shared.result(of: first)
                await Task.yield()
                #expect(session.awaitingWorkflowRuns.count == 1)
                #expect(session.awaitingWorkflowRuns[second]?.callId == "call-b")
                let landed = try #require(Self.toolTurn(session, callId: "call-a")?.content)
                #expect(landed.contains(WorkflowCallResult.Status.completed.rawValue))
                #expect(landed.contains("Acme"))
                let stillParked = try #require(Self.toolTurn(session, callId: "call-b")?.content)
                #expect(stillParked.contains(WorkflowCallResult.Status.awaitingUser.rawValue))
                #expect(!session.isStreaming, "the task does not go on while a run is still waiting")

                try await Self.answer(second, firm: "Globex")
                _ = await WorkflowRunService.shared.result(of: second)
                await Task.yield()
                #expect(session.awaitingWorkflowRuns.isEmpty)
                let landedB = try #require(Self.toolTurn(session, callId: "call-b")?.content)
                #expect(landedB.contains("Globex"))
                session.stop()
            }
        }
    }

    @Test
    func stoppingATaskWithTwoParkedCalls_cancelsBothRuns() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let caller = WorkflowCaller(kind: .agent, background: true)
                let first = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                let second = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                _ = await WorkflowRunService.shared.settledOrParked(first)
                _ = await WorkflowRunService.shared.settledOrParked(second)

                let session = ChatSession()
                session.parkOnWorkflowRun(first, callId: "call-a", toolName: installed.toolName)
                session.parkOnWorkflowRun(second, callId: "call-b", toolName: installed.toolName)
                session.stop()
                #expect(session.awaitingWorkflowRuns.isEmpty)
                #expect(await WorkflowRunService.shared.result(of: first)?.status == .cancelled)
                #expect(await WorkflowRunService.shared.result(of: second)?.status == .cancelled)
            }
        }
    }

    // MARK: - The parked set survives a save and a load

    @Test
    func parkedCalls_areSavedWithTheSession_andPickedUpOnLoad() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let caller = WorkflowCaller(kind: .agent, background: true)
                let runID = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                _ = await WorkflowRunService.shared.settledOrParked(runID)

                let session = ChatSession()
                Self.parkedTranscript(session, calls: [("call-a", runID, installed.toolName)])
                session.parkOnWorkflowRun(runID, callId: "call-a", toolName: installed.toolName)
                let saved = session.toSessionData()
                #expect(saved.parkedWorkflowRuns == [ParkedWorkflowCall(runID: runID, callId: "call-a", toolName: installed.toolName)])

                // Through the session row's JSON column and the Codable path.
                let json = try #require(ParkedWorkflowCall.encodedJSON(saved.parkedWorkflowRuns))
                #expect(json.contains(runID.uuidString))
                #expect(ParkedWorkflowCall.decode(json: json) == saved.parkedWorkflowRuns)
                #expect(ParkedWorkflowCall.encodedJSON([]) == nil)
                let data = try JSONEncoder().encode(saved)
                let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)
                #expect(decoded.parkedWorkflowRuns == saved.parkedWorkflowRuns)

                // Drop the live session without stopping it (a relaunch), then
                // load the saved one: it waits on the same run again.
                session.removeAllWorkflowRunObservers()
                let reopened = ChatSession()
                reopened.load(from: decoded)
                #expect(reopened.awaitingWorkflowRuns[runID]?.callId == "call-a")

                try await Self.answer(runID, firm: "Acme")
                _ = await WorkflowRunService.shared.result(of: runID)
                await Task.yield()
                #expect(reopened.awaitingWorkflowRuns.isEmpty)
                let landed = try #require(Self.toolTurn(reopened, callId: "call-a")?.content)
                #expect(landed.contains("Acme"))
                reopened.stop()
            }
        }
    }

    @Test
    func loadingASessionWhoseRunAlreadyEnded_landsTheResultAtOnce() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let caller = WorkflowCaller(kind: .agent, background: true)
                let runID = WorkflowRunService.shared.start(installed, input: .object([:]), caller: caller)
                _ = await WorkflowRunService.shared.settledOrParked(runID)
                WorkflowRunService.shared.cancel(runID)
                #expect(await WorkflowRunService.shared.result(of: runID)?.status == .cancelled)

                let session = ChatSession()
                Self.parkedTranscript(session, calls: [("call-a", runID, installed.toolName)])
                var saved = session.toSessionData()
                saved.parkedWorkflowRuns = [ParkedWorkflowCall(runID: runID, callId: "call-a", toolName: installed.toolName)]

                let reopened = ChatSession()
                reopened.load(from: saved)
                #expect(reopened.awaitingWorkflowRuns.isEmpty)
                let landed = try #require(Self.toolTurn(reopened, callId: "call-a")?.content)
                #expect(landed.contains(WorkflowCallResult.Status.cancelled.rawValue))
                #expect(!reopened.isStreaming, "a cancelled run is nothing to go on with")
                #expect(reopened.resumesAfterParkedWorkflowRuns, "the flag is one-shot")
            }
        }
    }

    // MARK: - Runs left open by a previous launch

    private static func twoCodeSteps() -> WorkflowDefinition {
        WorkflowDefinition(
            outputSchema: WF.object(["a": .object([:]), "b": .object([:])]),
            nodes: [WF.code("a"), WF.code("b", input: .object(["from": "{{nodes.a.output.value}}"]))],
            edges: [WorkflowEdge(from: "a", to: "b")],
            output: .object(["a": "{{nodes.a.output}}", "b": "{{nodes.b.output}}"]))
    }

    /// A record of `installed` a previous launch left open: `a` done,
    /// `b` running.
    private static func abandoned(_ installed: InstalledWorkflow, caller: WorkflowCaller) -> WorkflowRun {
        let startedAt = Date(timeIntervalSinceNow: -300)
        var run = WorkflowRun(
            workflowID: installed.id, workflowName: installed.name, templateID: installed.template.id,
            templateVersion: installed.template.version, caller: caller, input: .object([:]),
            nodeIDs: ["a", "b"], startedAt: startedAt)
        run.update("a") {
            $0.status = .done
            $0.output = .object(["value": .string("saved")])
            $0.attempts = 1
            $0.startedAt = startedAt
            $0.finishedAt = startedAt.addingTimeInterval(1)
        }
        run.update("b") {
            $0.status = .running
            $0.attempts = 1
            $0.startedAt = startedAt.addingTimeInterval(1)
        }
        return run
    }

    private func withExecutor(
        _ executor: WorkflowNodeExecuting, _ body: @MainActor () async throws -> Void
    ) async rethrows {
        try await WorkflowExecutorOverride.with({ executor }, body)
    }

    @Test
    func relaunch_resumesAnOpenRunFromItsSavedOutputs() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(Self.twoCodeSteps(), name: "Steps"), bindings: InstallBindings())
            let caller = WorkflowCaller(kind: .agent, sessionID: "s1", background: true, toolCallID: "call-9")
            let abandoned = Self.abandoned(installed, caller: caller)
            WorkflowRunStore.shared.record(abandoned)
            WorkflowRunStore.shared.resetForTesting()
            #expect(WorkflowRunStore.shared.abandonedRuns().contains { $0.id == abandoned.id })

            let log = NodeCallLog()
            try await withExecutor(
                ClosureExecutor { ctx, _ in
                    await log.enter(ctx.node.id)
                    return WorkflowNodeOutcome(output: .object(["got": ctx.input.value(atPath: "from") ?? .null]))
                }
            ) {
                let resumed = WorkflowRunService.shared.resumeAbandonedRuns(limitedTo: [abandoned.id])
                #expect(resumed == [abandoned.id])
                #expect(WorkflowRunService.shared.liveRunID(forToolCall: "call-9") == abandoned.id)
                let run = try #require(await WorkflowRunService.shared.result(of: abandoned.id))
                #expect(run.status == .completed)
                #expect(Self.sameSecond(run.startedAt, abandoned.startedAt))
                #expect(run.caller == caller)
                #expect(await log.calls == ["b"], "only the unfinished node runs")
                #expect(run.node("a")?.output == .object(["value": .string("saved")]))
                #expect(run.node("b")?.output == .object(["got": .string("saved")]))
                #expect(WorkflowRunStore.shared.abandonedRuns().isEmpty)
            }
        }
    }

    @Test
    func relaunch_closesTestRuns_andRunsOfWorkflowsThatAreGoneOrChanged() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(Self.twoCodeSteps(), name: "Steps"), bindings: InstallBindings())
            let test = Self.abandoned(installed, caller: WorkflowCaller(kind: .test))
            var gone = Self.abandoned(installed, caller: WorkflowCaller(kind: .user))
            gone.workflowID = UUID()
            var changed = Self.abandoned(installed, caller: WorkflowCaller(kind: .user))
            changed.templateVersion += 1
            for run in [test, gone, changed] { WorkflowRunStore.shared.record(run) }
            WorkflowRunStore.shared.resetForTesting()

            let resumed = WorkflowRunService.shared.resumeAbandonedRuns(limitedTo: [test.id, gone.id, changed.id])
            #expect(resumed.isEmpty)
            for (run, word) in [(test, "test run"), (gone, "no longer installed"), (changed, "changed")] {
                let closed = try #require(WorkflowRunStore.shared.run(id: run.id))
                #expect(closed.status == .cancelled)
                #expect(closed.error?.reason.contains(word) == true, "\(closed.error?.reason ?? "")")
                #expect(closed.node("b")?.status == .skipped)
                #expect(closed.node("a")?.status == .done, "finished nodes keep their record")
            }
        }
    }

    @Test
    func relaunch_showsAWaitingFormAgain_andTheRunFinishesWhenItIsAnswered() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let waitingSince = Date(timeIntervalSinceNow: -30)
                var waiting = WorkflowRun(
                    workflowID: installed.id, workflowName: installed.name, templateID: installed.template.id,
                    templateVersion: installed.template.version,
                    caller: WorkflowCaller(kind: .agent, background: true), input: .object([:]),
                    nodeIDs: ["ask"], startedAt: waitingSince)
                waiting.status = .awaitingUser
                waiting.update("ask") {
                    $0.status = .awaitingUser
                    $0.attempts = 1
                    $0.startedAt = waitingSince
                }
                WorkflowRunStore.shared.record(waiting)
                WorkflowRunStore.shared.resetForTesting()

                let resumed = WorkflowRunService.shared.resumeAbandonedRuns(limitedTo: [waiting.id])
                #expect(resumed == [waiting.id])
                #expect(await WorkflowRunService.shared.settledOrParked(waiting.id)?.status == .awaitingUser)
                #expect(await Self.pendingDialog(waiting.id) != nil, "the form is shown again")

                try await Self.answer(waiting.id, firm: "Acme")
                let run = try #require(await WorkflowRunService.shared.result(of: waiting.id))
                #expect(run.status == .completed)
                #expect(run.output == .object(["firm": .string("Acme")]))
                #expect(Self.sameSecond(run.startedAt, waiting.startedAt))
            }
        }
    }
}
