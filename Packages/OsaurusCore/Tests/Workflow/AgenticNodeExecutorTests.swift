//
//  AgenticNodeExecutorTests.swift
//  OsaurusCoreTests
//
//  The agentic node loop with a scripted model: listed tools only, the step
//  budget, the scope that gates execution, and the final structured call
//  built from the tool results.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgenticNodeExecutorTests {
    private actor Log {
        var executed: [String] = []
        var permitted: [Bool] = []
        var finalPrompt = ""
        var finalSystem = ""
        var steps = 0
        func exec(_ name: String, permitted ok: Bool) { executed.append(name); permitted.append(ok) }
        func finish(_ prompt: String, system: String) { finalPrompt = prompt; finalSystem = system }
        func step() -> Int { steps += 1; return steps }
    }

    private static func tool(_ name: String) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil))
    }

    private static func call(_ id: String, _ name: String) -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: #"{"q":"acme"}"#))
    }

    private static func context(maxSteps: Int, tools: [String]) -> (InferenceSpec, WorkflowNodeContext) {
        let spec = InferenceSpec(
            modelSlot: "research", instructions: "Look up {{input.client}}.",
            mode: .agentic(tools: tools.map { ToolRef(name: $0, server: "crm") }, maxSteps: maxSteps))
        let node = WorkflowNode(
            id: "lookup", name: "Lookup", kind: .inference(spec), input: .object(["client": "{{input.client}}"]),
            outputSchema: WF.object(["summary": WF.string], required: ["summary"]))
        let input: JSONValue = .object(["client": .string("Acme")])
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Intake", node: node, input: input,
            bindings: BindingContext(input: input), model: "openai/gpt-test", secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60)
        return (spec, context)
    }

    private static func runtime(
        log: Log, registered: [String], script: @escaping @Sendable (Int) -> AgenticNodeExecutor.Turn
    ) -> AgenticNodeExecutor.Runtime {
        AgenticNodeExecutor.Runtime(
            step: { _, _, tools in
                #expect(Set(tools.map(\.function.name)) == Set(["crm_search"]))
                return script(await log.step())
            },
            execute: { name, _, scope in
                await log.exec(name, permitted: scope.permits(name))
                return ToolEnvelope.success(tool: name, result: ["hit": "Acme Corp, 12 seats"])
            },
            finish: { _, prompt, system, _, _ in
                await log.finish(prompt, system: system)
                return "Acme Corp has 12 seats.\n"
            },
            specs: { names in names.filter(registered.contains).map(Self.tool) })
    }

    @Test
    func loopsOverListedTools_thenAnswersFromTheirResults() async throws {
        let log = Log()
        let (spec, context) = Self.context(maxSteps: 4, tools: ["crm_search"])
        let outcome = try await AgenticNodeExecutor.run(
            spec: spec, tools: [ToolRef(name: "crm_search")], maxSteps: 4, context: context,
            runtime: Self.runtime(log: log, registered: ["crm_search", "file_write"]) { step in
                step == 1
                    ? .init(text: nil, calls: [Self.call("c1", "crm_search")])
                    : .init(text: "Found the account.", calls: [])
            })
        #expect(outcome.output == .object(["summary": .string("Acme Corp has 12 seats.")]))
        #expect(outcome.toolCalls == ["crm_search"])
        #expect(await log.executed == ["crm_search"])
        #expect(await log.permitted == [true])
        let prompt = await log.finalPrompt
        #expect(prompt.contains("Acme Corp, 12 seats"))
        #expect(prompt.contains("Found the account."))
        let finalSystem = await log.finalSystem
        #expect(finalSystem.contains("as plain text, not as JSON"), "a single text field is answered as text")
        #expect(!finalSystem.contains("Reply with one JSON object"))
    }

    @Test
    func theStepBudgetCapsToolCalls() async throws {
        let log = Log()
        let (spec, context) = Self.context(maxSteps: 2, tools: ["crm_search"])
        _ = try await AgenticNodeExecutor.run(
            spec: spec, tools: [ToolRef(name: "crm_search")], maxSteps: 2, context: context,
            runtime: Self.runtime(log: log, registered: ["crm_search"]) { step in
                .init(text: nil, calls: [Self.call("a\(step)", "crm_search"), Self.call("b\(step)", "crm_search")])
            })
        #expect(await log.executed.count == 2)
        #expect(await log.steps == 1)

        let unbounded = Log()
        _ = try await AgenticNodeExecutor.run(
            spec: spec, tools: [ToolRef(name: "crm_search")], maxSteps: 500, context: context,
            runtime: Self.runtime(log: unbounded, registered: ["crm_search"]) { step in
                .init(text: nil, calls: [Self.call("c\(step)", "crm_search")])
            })
        #expect(await unbounded.executed.count == AgenticNodeExecutor.stepCeiling)
    }

    @Test
    func aMissingToolFailsBeforeAnyModelCall() async throws {
        let log = Log()
        let (spec, context) = Self.context(maxSteps: 3, tools: ["crm_search", "crm_update"])
        await #expect(throws: WorkflowNodeError.self) {
            try await AgenticNodeExecutor.run(
                spec: spec, tools: [ToolRef(name: "crm_search"), ToolRef(name: "crm_update")], maxSteps: 3,
                context: context,
                runtime: Self.runtime(log: log, registered: ["crm_search"]) { _ in .init(text: "x", calls: []) })
        }
        #expect(await log.steps == 0)
    }

    @Test
    func aWorkflowToolFailsBeforeAnyModelCall() async throws {
        let log = Log()
        let (spec, context) = Self.context(maxSteps: 3, tools: ["crm_search", "workflow_intake"])
        await #expect(throws: WorkflowNodeError.self) {
            try await AgenticNodeExecutor.run(
                spec: spec, tools: [ToolRef(name: "crm_search"), ToolRef(name: "workflow_intake")], maxSteps: 3,
                context: context,
                runtime: Self.runtime(log: log, registered: ["crm_search", "workflow_intake"]) { _ in
                    .init(text: "x", calls: [])
                })
        }
        #expect(await log.steps == 0)
        #expect(await log.executed.isEmpty)
    }

    @Test
    func theScopePermitsOnlyListedTools() {
        let scope = ToolExecutionScope(exposed: [Self.tool("crm_search")])
        #expect(scope.permits("crm_search"))
        #expect(!scope.permits("file_write"))
    }
}
