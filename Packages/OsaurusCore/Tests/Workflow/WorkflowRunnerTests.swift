//
//  WorkflowRunnerTests.swift
//  OsaurusCoreTests
//
//  The run loop against a scripted executor: input validation, decide
//  branches and skip propagation, retries, timeouts, cancellation,
//  concurrency, test-run pins, output assembly, and dialog status.
//

import Foundation
import Testing
import struct MLXLMCommon.GenerationFailure

@testable import OsaurusCore

struct WorkflowRunnerTests {

    /// Scripted outputs per node for the intake workflow.
    static func intakeExecutor(choice: String, log: NodeCallLog) -> ClosureExecutor {
        ClosureExecutor { ctx, _ in
            await log.enter(ctx.node.id)
            defer { Task { await log.leave() } }
            switch ctx.node.id {
            case "classify": return WorkflowNodeOutcome(output: .object(["choice": .string(choice)]), model: "fake/m")
            case "onboard": return WorkflowNodeOutcome(output: .object(["welcome": .string("Hi \(ctx.input.value(atPath: "client")?.stringValue ?? "")")]))
            case "lookup": return WorkflowNodeOutcome(output: .object(["id": .number(42)]))
            default: return WorkflowNodeOutcome(output: .object([:]))
            }
        }
    }

    static func request(
        _ def: WorkflowDefinition = WF.intake(), input: JSONValue = .object(["client": .string("Acme")]),
        caller: WorkflowCaller = WorkflowCaller(kind: .user), startAt: String? = nil,
        pinned: [String: JSONValue] = [:]
    ) -> WorkflowRunner.Request {
        let template = WF.template(def)
        return WorkflowRunner.Request(
            workflowID: UUID(), workflowName: template.name, template: template, caller: caller, input: input,
            startAt: startAt, pinned: pinned, workspace: WF.tempDir())
    }

    @Test
    func invalidInput_failsWithPathBeforeAnyNodeRuns() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(input: .object(["client": .number(1)])),
            executor: Self.intakeExecutor(choice: "new", log: log)
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.path == "$.client")
        #expect(await log.calls.isEmpty)
    }

    @Test
    func newClient_runsOnboardSkipsLookupAndAssemblesOutput() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(request: Self.request(), executor: Self.intakeExecutor(choice: "new", log: log))
            .execute()
        #expect(run.status == .completed)
        #expect(run.node("onboard")?.status == .done)
        #expect(run.node("lookup")?.status == .skipped)
        #expect(run.node("notify")?.status == .done)
        #expect(run.node("classify")?.model == "fake/m")
        #expect(
            run.output
                == .object(["category": .string("new"), "welcome": .string("Hi Acme"), "record": .null]))
        #expect(await log.count("lookup") == 0)
    }

    @Test
    func existingClient_takesTheOtherBranch() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(), executor: Self.intakeExecutor(choice: "existing", log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("onboard")?.status == .skipped)
        #expect(run.node("lookup")?.status == .done)
        #expect(run.output?.value(atPath: "record") == .object(["id": .number(42)]))
        #expect(run.output?.value(atPath: "welcome") == .null)
    }

    @Test
    func skipsCascadeThroughNodesWithNoPassingEdge() async {
        var def = WF.intake()
        def.edges.removeAll { $0.from == "lookup" }
        def.nodes.append(WF.code("archive"))
        def.edges.append(WorkflowEdge(from: "lookup", to: "archive"))
        let log = NodeCallLog()
        let run = await WorkflowRunner(request: Self.request(def), executor: Self.intakeExecutor(choice: "new", log: log))
            .execute()
        #expect(run.status == .completed)
        #expect(run.node("archive")?.status == .skipped)
    }

    @Test
    func retryableFailure_retriesThenSucceeds() async {
        var def = WF.intake()
        def.nodes[1].retry = RetryPolicy(maxAttempts: 3, backoffSeconds: 0)
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(def),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                await log.leave()
                if ctx.node.id == "classify" { return WorkflowNodeOutcome(output: .object(["choice": .string("new")])) }
                if ctx.node.id == "onboard", ctx.attempt < 2 {
                    struct Flaky: Error {}
                    throw Flaky()
                }
                return WorkflowNodeOutcome(output: .object(["welcome": .string("ok")]))
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("onboard")?.attempts == 2)
        #expect(await log.count("onboard") == 2)
    }

    @Test
    func toolStep_retriesARetryableFailure_keepsEveryCall_andBindsRunAndCaller() async {
        let agentID = UUID()
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "save", name: "Save", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write"))),
                    input: .object(["path": "{{run.id}}.md", "by": "{{caller.agent_name}}"]),
                    retry: RetryPolicy(maxAttempts: 3, backoffSeconds: 0))
            ])
        let request = Self.request(
            def, input: .object([:]), caller: WorkflowCaller(kind: .agent, agentID: agentID, agentName: "Scout"))
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { ctx, _ in
                let record = WorkflowToolCallRecord(
                    name: "file_write", arguments: ctx.input.compactJSONString, result: nil, durationMs: 1,
                    isError: ctx.attempt == 1)
                if ctx.attempt == 1 {
                    throw RecordedNodeFailure(
                        underlying: WorkflowNodeError.toolFailed(
                            tool: "file_write", kind: "execution_error", message: "busy", retryable: true),
                        toolCallRecords: [record])
                }
                return WorkflowNodeOutcome(output: .object([:]), toolCalls: ["file_write"], toolCallRecords: [record])
            }
        ).execute()
        #expect(run.status == .completed)
        let node = run.node("save")
        #expect(node?.attempts == 2)
        #expect(node?.toolCallRecords.map(\.isError) == [true, false])
        #expect(node?.input == .object(["path": .string("\(request.runID.uuidString).md"), "by": .string("Scout")]))
    }

    @Test
    func wrongShapedOutput_retriesThenFailsTheRunWithAttempts() async {
        var def = WF.intake()
        def.nodes[1].retry = RetryPolicy(maxAttempts: 2, backoffSeconds: 0)
        let run = await WorkflowRunner(
            request: Self.request(def),
            executor: ClosureExecutor { ctx, _ in
                if ctx.node.id == "classify" { return WorkflowNodeOutcome(output: .object(["choice": .string("new")])) }
                return WorkflowNodeOutcome(output: .object(["welcome": .number(1)]))
            }
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.nodeID == "onboard")
        #expect(run.error?.attempts == 2)
        #expect(run.node("onboard")?.status == .failed)
        #expect(run.node("notify")?.status == .skipped)
    }

    @Test
    func unsupportedModel_isNotRetried() async {
        var def = WF.intake()
        def.nodes[0].retry = RetryPolicy(maxAttempts: 3, backoffSeconds: 0)
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(def),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                await log.leave()
                throw StructuredOutputError.unsupportedModel(model: "mlx/local", reason: "no constrained decoding")
            }
        ).execute()
        #expect(run.status == .failed)
        #expect(await log.count("classify") == 1)
    }

    @Test
    func localDecodingFailure_isRetried() async {
        var def = WF.intake()
        def.nodes[0].retry = RetryPolicy(maxAttempts: 3, backoffSeconds: 0)
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(def),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                await log.leave()
                guard ctx.node.id == "classify" else { return WorkflowNodeOutcome(output: .object([:])) }
                if await log.count("classify") < 3 {
                    // The engine's grammar matcher did not reach a stop token
                    // within the token budget; another attempt can.
                    throw GenerationFailure(
                        stage: .decoding, cause: "Generation ended before the JSON schema matcher accepted a stop token")
                }
                return WorkflowNodeOutcome(output: .object(["choice": .string("new")]))
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(await log.count("classify") == 3)
        #expect(run.node("classify")?.attempts == 3)
    }

    @Test
    func slowNode_timesOut() async {
        var def = WF.intake()
        def.nodes[0].timeout = 0.2
        let started = Date()
        let run = await WorkflowRunner(
            request: Self.request(def),
            executor: ClosureExecutor { _, _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.nodeID == "classify")
        #expect(run.error?.reason.contains("0.2") == true || run.error?.reason.lowercased().contains("time") == true)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test
    func approvalWait_doesNotSpendTheStepTimeLimit_andShowsTheStepWaiting() async {
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "save", name: "Save", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write"))),
                    input: .object([:]), timeout: 1, retry: RetryPolicy(maxAttempts: 1))
            ])
        actor Seen { var statuses: [WorkflowRunStatus] = []; func add(_ s: WorkflowRunStatus) { statuses.append(s) } }
        let seen = Seen()
        let started = Date()
        let run = await WorkflowRunner(
            request: Self.request(def, input: .object([:])),
            executor: ClosureExecutor { _, _ in
                // The tool's approval card stays open three times longer
                // than the step's limit before the person allows it.
                let observer = ChatExecutionContext.approvalWaitObserver
                await observer?(true)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                await observer?(false)
                return WorkflowNodeOutcome(output: .object([:]))
            },
            observer: { await seen.add($0.status) }
        ).execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(Date().timeIntervalSince(started) >= 3)
        #expect(await seen.statuses.contains(.awaitingUser))
    }

    @Test
    func approvalWait_stillLeavesUnpausedWorkBounded() async {
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "save", name: "Save", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write"))),
                    input: .object([:]), timeout: 0.5, retry: RetryPolicy(maxAttempts: 1))
            ])
        let run = await WorkflowRunner(
            request: Self.request(def, input: .object([:])),
            executor: ClosureExecutor { _, _ in
                let observer = ChatExecutionContext.approvalWaitObserver
                await observer?(true)
                try await Task.sleep(nanoseconds: 200_000_000)
                await observer?(false)
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.nodeID == "save")
    }

    @Test
    func cancellingTheTask_cancelsTheRun() async {
        let runner = WorkflowRunner(
            request: Self.request(),
            executor: ClosureExecutor { _, _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return WorkflowNodeOutcome(output: .object([:]))
            })
        let task = Task { await runner.execute() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let run = await task.value
        #expect(run.status == .cancelled)
        #expect(run.nodes.allSatisfy { $0.status != .running && $0.status != .pending })
    }

    @Test
    func independentNodes_runConcurrently() async {
        let def = WorkflowDefinition(
            nodes: ["a", "b", "c"].map { WF.code($0) },
            output: .object([:]))
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(def, input: .object([:])),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                // Each node holds until all three have started; a serial
                // runner never gets there and the peak stays at 1.
                let deadline = Date().addingTimeInterval(10)
                while await log.calls.count < 3, Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                await log.leave()
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(await log.peak == 3)
    }

    @Test
    func startAt_withPinnedAncestor_runsOnlyTheSubgraph() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(
                caller: WorkflowCaller(kind: .test), startAt: "onboard",
                pinned: ["classify": .object(["choice": .string("new")])]),
            executor: Self.intakeExecutor(choice: "existing", log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("classify")?.status == .pinned)
        #expect(run.node("onboard")?.status == .done)
        #expect(await log.count("classify") == 0)
        #expect(run.output?.value(atPath: "category") == .string("new"))
    }

    @Test
    func startAt_withoutPinnedAncestors_fails() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: Self.request(caller: WorkflowCaller(kind: .test), startAt: "notify"),
            executor: Self.intakeExecutor(choice: "new", log: log)
        ).execute()
        #expect(run.status == .failed)
        #expect(await log.calls.isEmpty)
    }

    @Test
    func placeholderNodes_failOutsideTestRuns() async {
        var def = WF.intake()
        def.nodes.append(WorkflowNode(id: "later", name: "Later", intent: "Email", kind: nil))
        let log = NodeCallLog()
        let run = await WorkflowRunner(request: Self.request(def), executor: Self.intakeExecutor(choice: "new", log: log))
            .execute()
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("placeholder") == true)
    }

    @Test
    func outputNotMatchingSchema_failsTheRun() async {
        var def = WF.intake()
        def.output = .object(["category": "{{nodes.lookup.output.id}}"])
        let log = NodeCallLog()
        let run = await WorkflowRunner(request: Self.request(def), executor: Self.intakeExecutor(choice: "new", log: log))
            .execute()
        #expect(run.status == .failed)
        #expect(run.error?.path == "$.category")
    }

    @Test
    func awaitingUser_isPublishedWhileADialogIsOpen() async {
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "ask", name: "Ask",
                    kind: .dialog(DialogSpec(title: "Client", fields: [DialogField(key: "email", label: "Email")])))
            ])
        actor Seen { var statuses: [WorkflowRunStatus] = []; func add(_ s: WorkflowRunStatus) { statuses.append(s) } }
        let seen = Seen()
        let run = await WorkflowRunner(
            request: Self.request(def, input: .object([:])),
            executor: ClosureExecutor { _, awaiting in
                await awaiting(true)
                await awaiting(false)
                return WorkflowNodeOutcome(output: .object(["email": .string("a@b.co")]))
            },
            observer: { await seen.add($0.status) }
        ).execute()
        #expect(run.status == .completed)
        let statuses = await seen.statuses
        #expect(statuses.contains(.awaitingUser))
        #expect(statuses.last == .completed)
    }

    @Test
    func secretDialogAnswers_areRedactedInTheRecordButFlowDownstream() async {
        let def = WorkflowDefinition(
            nodes: [
                WorkflowNode(
                    id: "ask", name: "Ask",
                    kind: .dialog(
                        DialogSpec(
                            title: "Key",
                            fields: [DialogField(key: "token", label: "Token", type: .secret)]))),
                WF.code("use", input: .object(["token": "{{nodes.ask.output.token}}"])),
            ],
            edges: [WorkflowEdge(from: "ask", to: "use")])
        actor Box { var token: JSONValue?; func set(_ v: JSONValue?) { token = v } }
        let box = Box()
        let run = await WorkflowRunner(
            request: Self.request(def, input: .object([:])),
            executor: ClosureExecutor { ctx, _ in
                if ctx.node.id == "ask" { return WorkflowNodeOutcome(output: .object(["token": .string("s3cret")])) }
                await box.set(ctx.input.value(atPath: "token"))
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(await box.token == .string("s3cret"))
        #expect(run.node("ask")?.output?.value(atPath: "token") != .string("s3cret"))
    }

    // MARK: - Resuming after a relaunch

    /// A record a previous launch left open: `classify` done (existing),
    /// `onboard` skipped, `lookup` running when the app quit.
    static func abandonedIntake(_ request: WorkflowRunner.Request, startedAt: Date) -> WorkflowRun {
        var run = WorkflowRun(
            id: request.runID, workflowID: request.workflowID, workflowName: request.workflowName,
            templateID: request.template.id, templateVersion: request.template.version, caller: request.caller,
            input: request.input, nodeIDs: WF.intake().nodes.map(\.id), startedAt: startedAt)
        run.update("classify") {
            $0.status = .done
            $0.output = .object(["choice": .string("existing")])
            $0.model = "fake/m"
            $0.attempts = 1
            $0.startedAt = startedAt
            $0.finishedAt = startedAt.addingTimeInterval(1)
        }
        run.update("onboard") { $0.status = .skipped }
        run.update("lookup") {
            $0.status = .running
            $0.attempts = 1
            $0.startedAt = startedAt.addingTimeInterval(1)
        }
        return run
    }

    @Test
    func resumedRun_keepsFinishedNodesAndItsIdentity_andRunsOnlyTheRest() async {
        let log = NodeCallLog()
        let startedAt = Date(timeIntervalSinceNow: -600)
        var request = Self.request(caller: WorkflowCaller(kind: .agent, toolCallID: "call-7"))
        request.resuming = Self.abandonedIntake(request, startedAt: startedAt)
        let run = await WorkflowRunner(
            request: request, executor: Self.intakeExecutor(choice: "new", log: log)
        ).execute()

        #expect(run.status == .completed)
        #expect(run.id == request.runID)
        #expect(run.startedAt == startedAt, "the run keeps its original start")
        #expect(run.caller.toolCallID == "call-7")
        #expect(await log.count("classify") == 0, "a finished node is not run again")
        #expect(run.node("classify")?.status == .done)
        #expect(run.node("classify")?.model == "fake/m")
        #expect(run.node("onboard")?.status == .skipped)
        #expect(await log.count("lookup") == 1)
        #expect(run.node("lookup")?.status == .done)
        #expect(run.node("lookup")?.logs.contains { $0.contains("relaunched") } == true)
        #expect(run.node("notify")?.status == .done)
        // The saved `classify` output (existing) decides the branch, not
        // what the executor would say now (new).
        #expect(run.output?.value(atPath: "category") == .string("existing"))
        #expect(run.output?.value(atPath: "record") == .object(["id": .number(42)]))
    }

    static func askDefinition(timeout: TimeInterval) -> WorkflowDefinition {
        WorkflowDefinition(
            outputSchema: WF.object(["email": WF.string]),
            nodes: [
                WorkflowNode(
                    id: "ask", name: "Ask",
                    kind: .dialog(DialogSpec(title: "Client", fields: [DialogField(key: "email", label: "Email")])),
                    timeout: timeout, retry: RetryPolicy(maxAttempts: 1))
            ],
            output: .object(["email": "{{nodes.ask.output.email}}"]))
    }

    static func abandonedAsk(_ request: WorkflowRunner.Request, waitingSince: Date) -> WorkflowRun {
        var run = WorkflowRun(
            id: request.runID, workflowID: request.workflowID, workflowName: request.workflowName,
            templateID: request.template.id, templateVersion: request.template.version, caller: request.caller,
            input: request.input, nodeIDs: ["ask"], startedAt: waitingSince)
        run.status = .awaitingUser
        run.update("ask") {
            $0.status = .awaitingUser
            $0.attempts = 1
            $0.startedAt = waitingSince
        }
        return run
    }

    @Test
    func resumedDialog_isAskedAgainWithItsFullTimeout_andTheTimeItAlreadyWaited() async {
        let def = Self.askDefinition(timeout: 600)
        var request = Self.request(def, input: .object([:]))
        request.resuming = Self.abandonedAsk(request, waitingSince: Date(timeIntervalSinceNow: -500))
        actor Seen {
            var timeout: TimeInterval?
            var elapsed: TimeInterval?
            func set(_ t: TimeInterval, _ e: TimeInterval) { timeout = t; elapsed = e }
        }
        let seen = Seen()
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { ctx, awaiting in
                await seen.set(ctx.timeout, ctx.elapsedBeforeResume)
                await awaiting(true)
                await awaiting(false)
                return WorkflowNodeOutcome(output: .object(["email": .string("a@b.co")]))
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(await seen.timeout == 600)
        let elapsed = await seen.elapsed ?? 0
        #expect(elapsed >= 500 && elapsed < 510, "\(elapsed)")
        #expect(run.node("ask")?.status == .done)
        #expect(run.output == .object(["email": .string("a@b.co")]))
    }

    @Test
    func resumedDialog_whoseTimeoutPassedWhileTheAppWasClosed_isStillAsked() async {
        let def = Self.askDefinition(timeout: 0.5)
        var request = Self.request(def, input: .object([:]))
        request.resuming = Self.abandonedAsk(request, waitingSince: Date(timeIntervalSinceNow: -3_600))
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { _, awaiting in
                // The person takes three times the step's timeout to answer.
                await awaiting(true)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                await awaiting(false)
                return WorkflowNodeOutcome(output: .object(["email": .string("a@b.co")]))
            }
        ).execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(run.output == .object(["email": .string("a@b.co")]))
    }
}
