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
