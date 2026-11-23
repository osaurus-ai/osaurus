//
//  WorkflowFailureTests.swift
//  OsaurusCoreTests
//
//  What a failed step reports: the error's own words (never "error 2"),
//  its kind, whether another attempt helps, where the fix belongs, and a
//  hint; stored on the step and the run, bound for on_error: continue, and
//  read back from old runs that never had it. Also which surface owns a
//  workflow's model loads.
//

import Foundation
import Testing

@testable import OsaurusCore

enum PlainFailure: Error { case broke }

enum DescribedFailure: Error, CustomStringConvertible {
    case broke
    var description: String { "the widget broke" }
}

struct WorkflowFailureTests {

    // MARK: - Messages

    @Test
    func subagentError_saysWhatHappened() {
        let error: Error = SubagentError.unavailable("The image model is busy.")
        #expect(error.localizedDescription == "The image model is busy.")
        #expect(WorkflowFailure.message(error) == "The image model is busy.")
        #expect(SubagentError.unavailable("x").kindName == "unavailable")
        #expect(SubagentError.userDenied("x").kindName == "user_denied")
        #expect(SubagentError.invalidArgs(message: "bad").message == "bad")
        #expect(!SubagentError.unavailable("x").retryable)
        #expect(!SubagentError.denied("x").retryable)
        #expect(SubagentError.timedOut("x").retryable)
        #expect(SubagentError.executionFailed(message: "x").retryable)
        #expect(!SubagentError.executionFailed(message: "x", retryable: false).retryable)
    }

    @Test
    func message_neverFallsBackToTheBridgedErrorNumber() {
        #expect(WorkflowFailure.message(PlainFailure.broke) == "PlainFailure.broke")
        #expect(WorkflowFailure.message(DescribedFailure.broke) == "the widget broke")
        let ns = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "real words"])
        #expect(WorkflowFailure.message(ns) == "real words")
        let recorded = RecordedNodeFailure(underlying: SubagentError.unavailable("busy"), toolCallRecords: [])
        #expect(WorkflowFailure.message(recorded) == "busy")
        #expect(recorded.localizedDescription == "busy")
    }

    // MARK: - Classification

    @Test
    func classify_subagentRefusals() {
        let unavailable = WorkflowFailure.classify(SubagentError.unavailable("busy"))
        #expect(unavailable.kind == "unavailable")
        #expect(unavailable.fixIn == .settings)
        #expect(!unavailable.retryable)
        #expect(unavailable.errorType == "SubagentError.unavailable")
        #expect(unavailable.hint?.contains("Swap Local Models for Subagents") == true)

        let timedOut = WorkflowFailure.classify(SubagentError.timedOut("slow"))
        #expect(timedOut.fixIn == .retry && timedOut.retryable)

        let declined = WorkflowFailure.classify(SubagentError.userDenied("no"))
        #expect(declined.fixIn == .person)

        let denied = WorkflowFailure.classify(SubagentError.denied("policy"))
        #expect(denied.fixIn == .settings)
        #expect(denied.hint?.contains("do not use agent settings") == true)

        let wrapped = WorkflowFailure.classify(
            RecordedNodeFailure(underlying: SubagentError.unavailable("busy"), toolCallRecords: []))
        #expect(wrapped == unavailable)
    }

    @Test
    func classify_settingBlocksNameTheSetting() {
        let block = WorkflowSettingBlock(
            message: "Too big.", setting: "Server → Memory Safety", kind: "memory_admission")
        let failure = WorkflowFailure.classify(block)
        #expect(failure.kind == "memory_admission")
        #expect(failure.fixIn == .settings)
        #expect(!failure.retryable)
        #expect(failure.hint?.contains("Server → Memory Safety") == true)
        #expect(WorkflowFailure.message(block) == "Too big.")
    }

    @Test
    func classify_stepErrors() {
        let noModel = WorkflowFailure.classify(WorkflowNodeError.noModel(slot: "main"))
        #expect(noModel.fixIn == .setup)
        #expect(noModel.errorType == "WorkflowNodeError.noModel")
        #expect(WorkflowFailure.classify(WorkflowNodeError.dialogDismissed).fixIn == .person)
        #expect(WorkflowFailure.classify(WorkflowNodeError.outputMismatch(["x"])).fixIn == .workflow)

        func tool(_ kind: String, retryable: Bool = false) -> NodeRunFailure {
            WorkflowFailure.classify(
                WorkflowNodeError.toolFailed(tool: "web_fetch", kind: kind, message: "m", retryable: retryable))
        }
        #expect(tool("http_503", retryable: true).fixIn == .retry)
        #expect(tool("http_429", retryable: true).fixIn == .retry)
        #expect(tool("http_401").fixIn == .setup)
        #expect(tool("command_not_found").fixIn == .setup)
        #expect(tool("permission_denied").fixIn == .settings)
        #expect(tool("user_denied").fixIn == .person)
        #expect(tool("bad_args").fixIn == .workflow)
        #expect(tool("http_503", retryable: true).kind == "http_503")

        let unknown = WorkflowFailure.classify(PlainFailure.broke)
        #expect(unknown.kind == "error")
        #expect(unknown.errorType == "PlainFailure")
    }

    @Test
    func classify_providerErrors_byStatus() {
        func provider(_ error: RemoteProviderServiceError) -> NodeRunFailure { WorkflowFailure.classify(error) }
        let auth = provider(.requestFailed("HTTP 401: invalid api key"))
        #expect(auth.kind == "provider_auth" && auth.fixIn == .setup && !auth.retryable)
        #expect(auth.errorType == "RemoteProviderServiceError.requestFailed")
        #expect(provider(.requestFailed("HTTP 403: forbidden")).kind == "provider_auth")
        let funds = provider(.requestFailed(#"HTTP 402: {"error":{"code":"INSUFFICIENT_FUNDS"}}"#))
        #expect(funds.kind == "insufficient_funds" && funds.fixIn == .person && !funds.retryable)
        #expect(
            provider(.requestFailed(#"HTTP 402: {"error":{"code":"WORKSPACE_INSUFFICIENT_FUNDS"}}"#)).kind
                == "workspace_insufficient_funds")
        let server = provider(.requestFailed("HTTP 502: bad gateway"))
        #expect(server.kind == "provider_http_5xx" && server.fixIn == .retry && server.retryable)
        let refused = provider(.requestFailed("HTTP 400: context too long"))
        #expect(refused.kind == "provider_http_4xx" && refused.fixIn == .workflow && !refused.retryable)
        #expect(provider(.requestFailed("connection reset")).kind == "provider_error")
        #expect(provider(.rateLimited(retryAfter: 2, statusCode: 429)).kind == "provider_rate_limited")
        #expect(provider(.notConnected).kind == "provider_disconnected")
        #expect(provider(.outputTruncated(finishReason: "length")).kind == "output_truncated")
        #expect(provider(.invalidURL).fixIn == .setup)

        #expect(!WorkflowNodeError.isRetryable(RemoteProviderServiceError.requestFailed("HTTP 401: no")))
        #expect(WorkflowNodeError.isRetryable(RemoteProviderServiceError.requestFailed("HTTP 503: down")))
        #expect(WorkflowFailure.httpStatus(in: "Request failed: HTTP 429: slow down") == 429)
        #expect(WorkflowFailure.httpStatus(in: "no status here") == nil)
    }

    @Test
    func classify_engineAndRouterErrors() {
        let missing = WorkflowFailure.classify(ChatEngine.EngineError(kind: .modelNotFound(requested: "x/y")))
        #expect(missing.kind == "model_unavailable" && missing.fixIn == .setup && !missing.retryable)
        #expect(missing.errorType == "ChatEngine.EngineError.modelNotFound")
        #expect(
            WorkflowFailure.classify(ChatEngine.EngineError(kind: .routerSpendNotAuthorized)).fixIn == .settings)

        #expect(WorkflowFailure.classify(OsaurusRouterAPIError.insufficientFunds).kind == "insufficient_funds")
        #expect(WorkflowFailure.classify(OsaurusRouterAPIError.firstActionPending).fixIn == .person)
        #expect(WorkflowFailure.classify(OsaurusRouterAPIError.noIdentity).kind == "router_no_identity")
        let server = WorkflowFailure.classify(OsaurusRouterAPIError.server(code: "X", message: "m", status: 503))
        #expect(server.kind == "provider_http_5xx" && server.retryable)
        #expect(!WorkflowNodeError.isRetryable(OsaurusRouterAPIError.accountFrozen))
    }

    @Test
    func carriedCause_survivesAWorkerEnvelope() throws {
        let error = ChatEngine.EngineError(kind: .modelNotFound(requested: "gone/model"))
        let plain = ToolEnvelope.fromError(error, tool: "agent")
        let carried = WorkflowFailure.attachingCause(of: error, to: plain)
        #expect(ToolEnvelope.isError(carried))
        #expect(WorkflowFailure.attachingCause(of: PlainFailure.broke, to: plain) == plain)

        do {
            _ = try BuiltInWorkerRunner.delegated(from: carried, worker: .research)
            Issue.record("expected the worker failure to throw")
        } catch {
            let failure = WorkflowFailure.classify(error)
            #expect(failure.kind == "model_unavailable")
            #expect(failure.errorType == "ChatEngine.EngineError.modelNotFound")
            #expect(failure.fixIn == .setup)
            #expect(!WorkflowNodeError.isRetryable(error))
            #expect(WorkflowFailure.message(error).contains("gone/model"))
        }

        do {
            _ = try BuiltInWorkerRunner.delegated(from: plain, worker: .research)
            Issue.record("expected the worker failure to throw")
        } catch {
            #expect(WorkflowFailure.classify(error).kind == "execution_error")
        }
    }

    @Test
    func runner_runLevelFailures_areClassified() async {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["topic": .object(["type": .string("string")])], required: ["topic"]),
            outputSchema: WF.object([:]), nodes: [WF.code("a")], edges: [], output: .object([:]))
        let template = WF.template(def)
        let run = await WorkflowRunner(
            request: WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template,
                caller: WorkflowCaller(kind: .user), input: .object([:]), workspace: WF.tempDir()),
            executor: ClosureExecutor { _, _ in WorkflowNodeOutcome(output: .object([:])) }
        ).execute()
        #expect(run.status == .failed)
        #expect(run.primaryFailure?.kind == "input_mismatch")
        #expect(run.primaryFailure?.errorType == "WorkflowRunError.inputMismatch")
        #expect(run.primaryFailure?.fixIn == .workflow)
        #expect(WorkflowRunTelemetry.stage(kind: "input_mismatch", nodeID: nil) == "preflight")
    }

    // MARK: - Telemetry tokens

    @Test
    func telemetry_failureFields_comeFromTheRun() {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .orchestrator), input: .object([:]), nodeIDs: ["fetch", "write"])
        run.status = .failed
        run.update("fetch") { $0.status = .done }
        run.update("write") {
            $0.status = .failed
            $0.model = "osaurus/deepseek-v4-1-flash"
            $0.failure = NodeRunFailure(
                kind: "provider_disconnected", retryable: true, errorType: "RemoteProviderUnavailable.stillConnecting",
                fixIn: .retry)
        }
        run.error = WorkflowRunError(nodeID: "write", reason: "r", failure: run.node("write")?.failure)
        run.wrapperAgentID = UUID()

        let failure = WorkflowRunTelemetry.failure(
            run, stepKinds: ["fetch": "http", "write": "inference"], route: { _ in ("remote", "osaurus") })
        #expect(failure?.stage == "step")
        #expect(failure?.kind == "provider_disconnected")
        #expect(failure?.fixIn == "retry")
        #expect(failure?.stepKind == "inference")
        #expect(failure?.stepsDone == 1)
        #expect(failure?.modelSource == "remote" && failure?.providerType == "osaurus")
        #expect(WorkflowRunTelemetry.runKind(run) == "wrapper")

        run.status = .completed
        #expect(WorkflowRunTelemetry.failure(run, stepKinds: [:], route: { _ in ("local", "mlx") }) == nil)

        var early = WorkflowRun(
            workflowID: UUID(), workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: ["a"])
        early.status = .failed
        early.error = WorkflowRunError(reason: "legacy, no classification")
        let unclassified = WorkflowRunTelemetry.failure(early, stepKinds: ["a": "code"], route: { _ in ("local", "mlx") })
        #expect(unclassified?.kind == "unclassified" && unclassified?.stage == "run")
        #expect(unclassified?.stepKind == nil && unclassified?.modelSource == nil)
        #expect(WorkflowRunTelemetry.runKind(early) == "test")
        #expect(WorkflowRunTelemetry.stage(kind: "sandbox_unavailable", nodeID: nil) == "sandbox")
        #expect(WorkflowRunTelemetry.stage(kind: "output_mismatch", nodeID: nil) == "output")
        #expect(WorkflowRunTelemetry.stage(kind: "output_mismatch", nodeID: "a") == "step")
        #expect(ProcessLaunch.date <= Date())
    }

    // MARK: - Stored and bound

    @Test
    func failure_decodesOldRunsAndUnknownValues() throws {
        let legacy = try JSONDecoder().decode(
            NodeRun.self, from: Data(#"{"node_id": "a", "status": "failed", "attempts": 1, "logs": []}"#.utf8))
        #expect(legacy.failure == nil)

        let odd = try JSONDecoder().decode(NodeRunFailure.self, from: Data(#"{"fix_in": "martian"}"#.utf8))
        #expect(odd.kind == "error" && odd.fixIn == .workflow && !odd.retryable)

        var node = NodeRun(nodeID: "a", status: .failed)
        node.failure = NodeRunFailure(
            kind: "unavailable", retryable: false, errorType: "SubagentError.unavailable", fixIn: .settings, hint: "h")
        let back = try JSONDecoder().decode(NodeRun.self, from: JSONEncoder().encode(node))
        #expect(back.failure == node.failure)
        let json = try #require(String(data: JSONEncoder().encode(node.failure), encoding: .utf8))
        #expect(json.contains("\"fix_in\"") && json.contains("\"error_type\""))

        let error = WorkflowRunError(nodeID: "a", reason: "r", failure: node.failure)
        #expect(try JSONDecoder().decode(WorkflowRunError.self, from: JSONEncoder().encode(error)) == error)
    }

    @Test
    func errorOutput_carriesRetryableAndWhereTheFixBelongs() {
        let out = WorkflowRunner.errorOutput(SubagentError.unavailable("busy"), attempts: 1)
        #expect(out.value(atPath: "error.message") == .string("busy"))
        #expect(out.value(atPath: "error.kind") == .string("unavailable"))
        #expect(out.value(atPath: "error.retryable") == .bool(false))
        #expect(out.value(atPath: "error.fix_in") == .string("settings"))
        #expect(out.value(atPath: "error.attempts") == .number(1))
    }

    @Test
    func errorOutput_kindMatchesTheRecordedFailure() {
        for error: Error in [
            CodeNodeError.memoryLimit(mb: 64), CodeNodeError.runtimeMissing,
            CodeNodeError.scriptError(message: "x", stack: ""), WorkflowNodeError.noModel(slot: "main"),
        ] {
            let out = WorkflowRunner.errorOutput(error, attempts: nil)
            #expect(out.value(atPath: "error.kind") == .string(WorkflowFailure.classify(error).kind))
        }
    }

    /// write (inference) -> img (code) -> after (code).
    static func chain(onError: NodeErrorPolicy) -> WorkflowDefinition {
        var img = WF.code("img", input: .object([:]))
        img.onError = onError
        return WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "write", name: "Write", kind: .inference(InferenceSpec(modelSlot: "main", instructions: "x"))),
                img,
                WF.code("after", input: .object(["fix": "{{nodes.img.output.error.fix_in}}"])),
            ],
            edges: [WorkflowEdge(from: "write", to: "img"), WorkflowEdge(from: "img", to: "after", on: .always)],
            output: .object([:]))
    }

    static func run(_ def: WorkflowDefinition, seen: ParentLog) async -> WorkflowRun {
        let template = WF.template(def)
        return await WorkflowRunner(
            request: WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template,
                caller: WorkflowCaller(kind: .user), input: .object([:]), workspace: WF.tempDir()),
            executor: ClosureExecutor { ctx, _ in
                await seen.record(ctx.node.id, parent: ctx.residentParentModel, input: ctx.input)
                switch ctx.node.id {
                case "write": return WorkflowNodeOutcome(output: .object(["text": .string("hi")]), model: "qwen3.8-27b")
                case "img": throw SubagentError.unavailable("Another model is loaded for an API request.")
                default: return WorkflowNodeOutcome(output: .object([:]))
                }
            }
        ).execute()
    }

    actor ParentLog {
        var parents: [String: String?] = [:]
        var inputs: [String: JSONValue] = [:]
        func record(_ id: String, parent: String?, input: JSONValue) {
            parents[id] = parent
            inputs[id] = input
        }
    }

    @Test
    func runner_recordsTheFailureOnTheStepAndTheRun_andHandsOnTheModel() async {
        let seen = ParentLog()
        let run = await Self.run(Self.chain(onError: .fail), seen: seen)
        #expect(run.status == .failed)
        #expect(run.error?.reason == "Another model is loaded for an API request.")
        #expect(run.error?.failure?.fixIn == .settings)
        #expect(run.node("img")?.failure?.kind == "unavailable")
        #expect(run.node("img")?.error == "Another model is loaded for an API request.")
        #expect(run.primaryFailure?.errorType == "SubagentError.unavailable")
        #expect(await seen.parents["write"] == .some(nil))
        #expect(await seen.parents["img"] == .some("qwen3.8-27b"))
    }

    @Test
    func runner_onErrorContinue_bindsWhereTheFixBelongs() async {
        let seen = ParentLog()
        let run = await Self.run(Self.chain(onError: .continue), seen: seen)
        #expect(run.status == .completed, "\(run.error?.reason ?? "")")
        #expect(run.node("img")?.failure?.fixIn == .settings)
        #expect(await seen.inputs["after"]?.value(atPath: "fix") == .string("settings"))
    }

    // MARK: - Who owns the model loads

    @Test
    func caller_residencySource() {
        #expect(WorkflowCaller(kind: .user).residencySource == .chat)
        #expect(WorkflowCaller(kind: .test).residencySource == .chat)
        #expect(WorkflowCaller(kind: .agent, isExternalSurface: true).residencySource == .http)
        #expect(WorkflowCaller(kind: .event).residencySource == .automation)
        #expect(WorkflowCaller(kind: .agent, isUnattendedDispatch: true).residencySource == .schedule)
    }

    @Test
    func bind_setsTheResidencySource_andCloudModelsKeepTheAPIOwner() async throws {
        let node = WF.code("a")
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .agent, isUnattendedDispatch: true), workspace: WF.tempDir(), attempt: 1,
            timeout: 30)
        #expect(WorkflowExecutionContext.residencySource == nil)
        let (source, owner) = try await WorkflowExecutionContext.bind(context) {
            (
                WorkflowExecutionContext.residencySource,
                InferenceNodeExecutor.residencyRequestSource(model: "openai/gpt-test")
            )
        }
        #expect(source == .schedule)
        #expect(owner == .httpAPI)
        #expect(InferenceNodeExecutor.residencyRequestSource(model: "openai/gpt-test") == .httpAPI)
    }

    @Test
    func mediaInvocation_isEmptyWithoutAResidentParent() async {
        var runtime = MediaNodeRuntime.live
        runtime.residentLocalModel = { $0 == "loaded" ? "canonical-loaded" : nil }
        func context(_ parent: String?) -> WorkflowNodeContext {
            WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "W", node: WF.code("a"), input: .object([:]),
                bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
                caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30,
                residentParentModel: parent)
        }
        let loaded = await MediaNodeExecutor.invocation(context: context("loaded"), runtime: runtime)
        #expect(loaded == ModelJobInvocation(parentModelName: "canonical-loaded", source: .chat))
        let unloaded = await MediaNodeExecutor.invocation(context: context("gone"), runtime: runtime)
        #expect(unloaded == ModelJobInvocation(parentModelName: nil, source: nil))
        let none = await MediaNodeExecutor.invocation(context: context(nil), runtime: runtime)
        #expect(none == ModelJobInvocation(parentModelName: nil, source: nil))
    }
}
