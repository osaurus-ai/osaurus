//
//  ToolNodeExecutorTests.swift
//  OsaurusCoreTests
//
//  Tool nodes with a scripted registry: bound input as arguments, a scope
//  that exposes only the node's tool, output normalization, failure
//  envelopes as typed node failures, and the tools no step may call.
//  Also the run/caller bindings and the context each attempt runs under.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolNodeExecutorTests {
    private actor Log {
        var calls: [(name: String, arguments: String, permitted: Bool, other: Bool)] = []
        func record(_ name: String, _ arguments: String, _ permitted: Bool, _ other: Bool) {
            calls.append((name, arguments, permitted, other))
        }
    }

    private static func tool(_ name: String) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil))
    }

    private static func context(
        tool: String = "file_write", input: JSONValue = .object(["path": .string("notes.md")]),
        outputSchema: JSONValue = .object([:])
    ) -> (ToolNodeSpec, WorkflowNodeContext) {
        let spec = ToolNodeSpec(tool: ToolRef(name: tool))
        let node = WorkflowNode(
            id: "save", name: "Save", kind: .tool(spec), input: .object(["path": "{{input.path}}"]),
            outputSchema: outputSchema)
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Notes", node: node, input: input,
            bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60)
        return (spec, context)
    }

    private static func runtime(
        log: Log, registered: Set<String> = ["file_write"], outputSchema: JSONValue? = nil,
        result: @escaping @Sendable (String) -> String
    ) -> ToolNodeExecutor.Runtime {
        ToolNodeExecutor.Runtime(
            resolve: { name in
                registered.contains(name)
                    ? ToolNodeExecutor.Resolved(spec: Self.tool(name), outputSchema: outputSchema) : nil
            },
            execute: { name, arguments, scope in
                await log.record(name, arguments, scope.permits(name), scope.permits("shell_run"))
                return result(name)
            })
    }

    @Test
    func callsTheToolWithTheBoundInput_inAScopeOfOnlyThatTool() async throws {
        let log = Log()
        let (spec, context) = Self.context()
        let outcome = try await ToolNodeExecutor.run(
            spec: spec, context: context,
            runtime: Self.runtime(log: log) { ToolEnvelope.success(tool: $0, result: ["bytes": 12]) })
        let calls = await log.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "file_write")
        #expect(JSONValue.parse(calls.first?.arguments ?? "") == .object(["path": .string("notes.md")]))
        #expect(calls.first?.permitted == true)
        #expect(calls.first?.other == false)
        #expect(outcome.output == .object(["bytes": .number(12)]))
        #expect(outcome.toolCalls == ["file_write"])
        #expect(outcome.toolCallRecords.count == 1)
        #expect(outcome.toolCallRecords.first?.isError == false)
    }

    @Test
    func emptyInput_sendsAnEmptyObject() async throws {
        let log = Log()
        let (spec, context) = Self.context(input: .object([:]))
        _ = try await ToolNodeExecutor.run(
            spec: spec, context: context, runtime: Self.runtime(log: log) { ToolEnvelope.success(tool: $0) })
        #expect(await log.calls.first?.arguments == "{}")
    }

    @Test
    func outputNormalization() {
        func out(_ result: Any?, schema: JSONValue? = nil) -> JSONValue {
            ToolNodeExecutor.output(of: ToolEnvelope.success(tool: "t", result: result), declaredSchema: schema)
        }
        #expect(out(["a": 1]) == .object(["a": .number(1)]))
        #expect(out([1, 2]) == .array([.number(1), .number(2)]))
        #expect(out(nil) == .object([:]))
        #expect(out("done") == .object(["text": .string("done")]))
        #expect(out(7) == .object(["value": .number(7)]))
        #expect(out(true) == .object(["value": .bool(true)]))
        // MCP mirrors structuredContent as JSON text; decoded only when a schema applies.
        let mirrored: [String: Any] = ["text": #"{"rows":3}"#]
        #expect(out(mirrored) == .object(["text": .string(#"{"rows":3}"#)]))
        #expect(out(mirrored, schema: WF.object(["rows": WF.number])) == .object(["rows": .number(3)]))
        // A tool that prints plain text instead of an envelope.
        #expect(ToolNodeExecutor.output(of: "hello", declaredSchema: nil) == .object(["text": .string("hello")]))
    }

    @Test
    func failureEnvelope_failsTheStepWithItsKind_andKeepsTheRecord() async {
        let log = Log()
        let (spec, context) = Self.context()
        do {
            _ = try await ToolNodeExecutor.run(
                spec: spec, context: context,
                runtime: Self.runtime(log: log) {
                    ToolEnvelope.failure(kind: .invalidArgs, message: "path is outside the folder", tool: $0, retryable: true)
                })
            Issue.record("expected a failure")
        } catch let failure as RecordedNodeFailure {
            #expect(failure.toolCallRecords.count == 1)
            #expect(failure.toolCallRecords.first?.isError == true)
            guard case WorkflowNodeError.toolFailed(let tool, let kind, let message, let retryable)? =
                failure.underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(failure.underlying)")
                return
            }
            #expect(tool == "file_write")
            #expect(kind == ToolEnvelope.Kind.invalidArgs.rawValue)
            #expect(message == "path is outside the folder")
            #expect(retryable)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func declaredToolSchema_checksTheResult() async {
        let log = Log()
        let (spec, context) = Self.context()
        await #expect(throws: RecordedNodeFailure.self) {
            _ = try await ToolNodeExecutor.run(
                spec: spec, context: context,
                runtime: Self.runtime(log: log, outputSchema: WF.object(["bytes": WF.number], required: ["bytes"])) {
                    ToolEnvelope.success(tool: $0, result: ["other": "x"])
                })
        }
    }

    @Test
    func excludedAndMissingTools_neverExecute() async {
        let log = Log()
        let cases: [(name: String, registered: Set<String>)] = [
            ("run_workflow", ["run_workflow"]), ("workflow_intake", ["workflow_intake"]), ("todo", ["todo"]),
            ("capabilities_load", ["capabilities_load"]), ("missing_tool", []),
        ]
        for (name, registered) in cases {
            let (spec, context) = Self.context(tool: name)
            await #expect(throws: WorkflowNodeError.self) {
                _ = try await ToolNodeExecutor.run(
                    spec: spec, context: context,
                    runtime: Self.runtime(log: log, registered: registered) { ToolEnvelope.success(tool: $0) })
            }
        }
        #expect(await log.calls.isEmpty)
    }

    @Test
    func thrownGateRefusals_becomeTypedEnvelopes() {
        func kind(_ code: Int) -> String? {
            let envelope = ToolNodeExecutor.failureEnvelope(
                for: NSError(domain: "ToolRegistry", code: code, userInfo: [NSLocalizedDescriptionKey: "no"]), tool: "t")
            return ToolNodeExecutor.parseFailure(envelope).kind
        }
        #expect(kind(4) == ToolEnvelope.Kind.userDenied.rawValue)
        #expect(kind(7) == ToolEnvelope.Kind.permissionDenied.rawValue)
        #expect(kind(3) == ToolEnvelope.Kind.rejected.rawValue)
        #expect(kind(99) == ToolEnvelope.Kind.executionError.rawValue)
    }

    @Test
    func failureHint_travelsWithTheMessage() {
        let envelope = ToolEnvelope.failure(
            kind: .notFound, message: "No results from any search provider.", tool: "search_and_extract",
            retryable: true, metadata: ["hint": "Try a broader query.", "attempts": [["provider": "ddg"]]])
        let failure = ToolNodeExecutor.parseFailure(envelope)
        #expect(failure.message == "No results from any search provider. Try a broader query.")
        #expect(failure.kind == ToolEnvelope.Kind.notFound.rawValue)
        #expect(failure.retryable)

        let plain = ToolEnvelope.failure(kind: .invalidArgs, message: "path is outside the folder", tool: "file_write")
        #expect(ToolNodeExecutor.parseFailure(plain).message == "path is outside the folder")
    }
}

struct ToolNodeModelTests {

    private static func toolNode(_ id: String, _ name: String, input: WorkflowBinding = .object([:])) -> WorkflowNode {
        WorkflowNode(id: id, name: id.capitalized, kind: .tool(ToolNodeSpec(tool: ToolRef(name: name))), input: input)
    }

    @Test
    func toolKind_roundTripsAndAcceptsShorthand() throws {
        let node = Self.toolNode("save", "file_write", input: .object(["path": "{{input.path}}"]))
        let data = try JSONEncoder().encode(node)
        #expect(try JSONDecoder().decode(WorkflowNode.self, from: data) == node)

        let shorthand = #"{"id":"s","name":"S","kind":"tool","tool":"shell_run"}"#
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: Data(shorthand.utf8))
        #expect(decoded.calledTools.map(\.name) == ["shell_run"])
        let nested = #"{"id":"s","name":"S","kind":"tool","tool":{"name":"search","server":"Linear"}}"#
        let mcp = try JSONDecoder().decode(WorkflowNode.self, from: Data(nested.utf8))
        #expect(mcp.calledTools == [ToolRef(name: "search", server: "Linear")])
    }

    @Test
    func validator_rejectsExcludedAndEmptyTools() {
        var def = WF.intake()
        def.nodes.append(Self.toolNode("save", "file_write"))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)

        def.nodes.append(Self.toolNode("nested", "run_workflow"))
        def.nodes.append(Self.toolNode("steer", "spawn_agent"))
        def.nodes.append(Self.toolNode("blank", " "))
        let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
        #expect(issues.contains { $0.nodeID == "nested" && $0.message.contains("is a workflow tool") })
        #expect(issues.contains { $0.nodeID == "steer" && $0.message.contains("cannot run as a workflow step") })
        #expect(issues.contains { $0.nodeID == "blank" && $0.message.contains("needs a tool name") })
        #expect(!issues.contains { $0.nodeID == "save" })
    }

    @Test
    func runAndCallerReferences_areValid_unknownFieldsAreNot() {
        var def = WF.intake()
        def.nodes.append(
            Self.toolNode(
                "save", "file_write",
                input: .object([
                    "path": "{{run.workspace}}/{{run.id}}.md",
                    "by": "{{caller.agent_name}} ({{caller.kind}}, {{caller.agent_id}})",
                ])))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)

        def.nodes[def.nodes.count - 1] = Self.toolNode("save", "file_write", input: .object(["p": "{{run.secret}}"]))
        let messages = WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
        #expect(messages.contains { $0.contains("invalid reference `{{run.secret}}`") })
    }

    @Test
    func calledTools_coverToolAndAgenticNodes_dedupedInOrder() {
        var def = WF.intake()
        def.nodes.append(Self.toolNode("save", "file_write"))
        def.nodes.append(
            WorkflowNode(
                id: "research", name: "Research",
                kind: .inference(
                    InferenceSpec(
                        modelSlot: "drafting", instructions: "Look it up",
                        mode: .agentic(tools: [ToolRef(name: "web_search"), ToolRef(name: "file_write")], maxSteps: 3))),
                outputSchema: WF.object(["summary": WF.string])))
        #expect(def.calledTools.map(\.name) == ["file_write", "web_search"])
        let reqs = WorkflowRequirementsDeriver.derive(def)
        #expect(reqs.tools == ["file_write", "web_search"])
    }

    @Test
    func declaredToolSchema_appliesOnlyWhenTheNodeLeavesItOpen() {
        let open = Self.toolNode("save", "file_write")
        let declared = WF.object(["bytes": WF.number])
        #expect(open.effectiveOutputSchema(toolOutputSchema: declared) == declared)
        var pinned = open
        pinned.outputSchema = WF.object(["ok": WF.bool])
        #expect(pinned.effectiveOutputSchema(toolOutputSchema: declared) == WF.object(["ok": WF.bool]))
    }

    @Test
    func runAndCallerBindings_resolve() {
        let runID = UUID()
        let agentID = UUID()
        let ctx = BindingContext(
            input: .object([:]),
            run: BindingContext.runValue(id: runID, workspace: URL(fileURLWithPath: "/tmp/run")),
            caller: BindingContext.callerValue(WorkflowCaller(kind: .agent, agentID: agentID, agentName: "Scout")))
        #expect(BindingRenderer.renderValue("{{run.id}}", in: ctx) == .string(runID.uuidString))
        #expect(BindingRenderer.renderText("{{run.workspace}}/out.md", in: ctx) == "/tmp/run/out.md")
        #expect(BindingRenderer.renderValue("{{caller.kind}}", in: ctx) == .string("agent"))
        #expect(BindingRenderer.renderValue("{{caller.agent_id}}", in: ctx) == .string(agentID.uuidString))
        #expect(BindingRenderer.renderValue("{{caller.agent_name}}", in: ctx) == .string("Scout"))
        #expect(BindingRenderer.parse(reference: "run.secret") == nil)
        #expect(BindingRenderer.parse(reference: "caller.agent_name.x") == nil)

        let user = BindingContext.callerValue(WorkflowCaller(kind: .user))
        #expect(
            user == .object(["kind": .string("user"), "agent_id": .null, "agent_name": .null, "channel": .null]))
    }
}

struct WorkflowExecutionContextTests {

    @Test
    func attemptsRunUnderTheRunsContext_andGrantOnlyTheirTools() async throws {
        let agentID = UUID()
        let folder = WF.tempDir()
        let node = WorkflowNode(
            id: "save", name: "Save", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write"))))
        let runID = UUID()
        let context = WorkflowNodeContext(
            runID: runID, workflowID: UUID(), workflowName: "Notes", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .agent, agentID: agentID, sessionID: "s1", isUnattendedDispatch: true),
            workspace: WF.tempDir(), folderRoot: folder, attempt: 1, timeout: 60)
        let seen = try await WorkflowExecutionContext.bind(context) {
            (
                ChatExecutionContext.currentWorkflowRunId, ChatExecutionContext.currentWorkflowNodeId,
                ChatExecutionContext.currentAgentId, ChatExecutionContext.currentSessionId,
                ChatExecutionContext.currentFolderRoot, ChatExecutionContext.isUnattendedDispatch,
                ChatExecutionContext.workflowGrantedToolNames
            )
        }
        #expect(seen.0 == runID)
        #expect(seen.1 == "save")
        #expect(seen.2 == agentID)
        #expect(seen.3 == "s1")
        #expect(seen.4 == folder)
        #expect(seen.5)
        #expect(seen.6 == ["file_write"])
        #expect(ChatExecutionContext.workflowGrantedToolNames == nil)
    }

    @MainActor
    @Test
    func callerFolder_prefersTheCallersFolder_thenTheAgents() {
        let agentID = UUID()
        let explicit = WorkflowRunService.callerFolder(
            WorkflowCaller(kind: .agent, agentID: agentID, folderPath: "/tmp/chat-folder"),
            agentFolder: { _ in (nil, "/tmp/agent-folder") })
        #expect(explicit == .init(url: URL(fileURLWithPath: "/tmp/chat-folder", isDirectory: true), isScoped: false))

        let fromAgent = WorkflowRunService.callerFolder(
            WorkflowCaller(kind: .agent, agentID: agentID), agentFolder: { _ in (nil, "/tmp/agent-folder") })
        #expect(fromAgent == .init(url: URL(fileURLWithPath: "/tmp/agent-folder", isDirectory: true), isScoped: false))

        #expect(
            WorkflowRunService.callerFolder(WorkflowCaller(kind: .agent, agentID: agentID), agentFolder: { _ in nil })
                == nil)
        #expect(WorkflowRunService.callerFolder(WorkflowCaller(kind: .user), agentFolder: { _ in (nil, "/x") }) == nil)
    }
}
