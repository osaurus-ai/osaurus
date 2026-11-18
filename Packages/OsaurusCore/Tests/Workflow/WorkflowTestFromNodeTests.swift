//
//  WorkflowTestFromNodeTests.swift
//  OsaurusCoreTests
//
//  Test From This Step: the reuse plan takes the last test's results for
//  every earlier step only when none changed and all finished, and the
//  runner marks reused steps, keeps their inputs, hashes, and files, and
//  runs only the chosen step and what follows it.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowTestFromNodeTests {

    static func definition(bInput: String = "{{nodes.a.output.v}}") -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["seed": WF.string]), outputSchema: WF.object(["final": WF.string]),
            nodes: [
                WF.code("a", input: .object(["seed": "{{input.seed}}"]), output: WF.object(["v": WF.string])),
                WF.code("b", input: .object(["x": bInput]), output: WF.object(["v": WF.string])),
                WF.code("c", input: .object(["x": "{{nodes.b.output.v}}"]), output: WF.object(["v": WF.string])),
            ],
            edges: [WorkflowEdge(from: "a", to: "b"), WorkflowEdge(from: "b", to: "c")],
            output: .object(["final": "{{nodes.c.output.v}}"]))
    }

    static func executor(_ log: NodeCallLog, failing: String? = nil) -> ClosureExecutor {
        ClosureExecutor { ctx, _ in
            await log.enter(ctx.node.id)
            if ctx.node.id == failing { throw WorkflowNodeError.unsupported("boom") }
            let seen = ctx.input.objectValue?.values.first.map(BindingRenderer.textValue) ?? ""
            var artifacts: [WorkflowArtifact] = []
            if ctx.node.id == "b" {
                let url = WF.tempDir().appendingPathComponent("b.png")
                try MediaFixtures.writePNG(url)
                artifacts.append(
                    WorkflowArtifact(
                        source: .generated, nodeID: "b", filename: "b.png", mimeType: "image/png", path: url.path))
            }
            return WorkflowNodeOutcome(
                output: .object(["v": .string("\(ctx.node.id)(\(seen))")]), artifacts: artifacts)
        }
    }

    static func run(
        _ def: WorkflowDefinition, executor: ClosureExecutor, startAt: String? = nil,
        pinned: [String: JSONValue] = [:], reusing: WorkflowRun? = nil, input: JSONValue = .object(["seed": .string("s")])
    ) async -> WorkflowRun {
        let template = WF.template(def)
        var request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: template.name, template: template, caller: WorkflowCaller(kind: .user),
            input: input, startAt: startAt, pinned: pinned, workspace: WF.tempDir())
        request.reusing = reusing
        return await WorkflowRunner(request: request, executor: executor).execute()
    }

    // MARK: - Plan

    @Test
    func plan_reusesEveryEarlierStepWhenNothingChanged() async throws {
        let def = Self.definition()
        let first = await Self.run(def, executor: Self.executor(NodeCallLog()))
        #expect(first.status == .completed)
        #expect(first.node("a")?.specHash != nil)

        guard case .success(let plan) = WorkflowDraftTester.reusePlan(from: first, nodeID: "c", definition: def) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.startAt == "c")
        #expect(plan.reused == ["a", "b"])
        #expect(plan.input == first.input)
        #expect(plan.pinned["b"] == first.node("b")?.output)
    }

    @Test
    func plan_refusesChangedUnfinishedAndUnknownSteps() async {
        let first = await Self.run(Self.definition(), executor: Self.executor(NodeCallLog()))
        let edited = Self.definition(bInput: "{{nodes.a.output.v}}!")
        #expect(
            WorkflowDraftTester.reusePlan(from: first, nodeID: "c", definition: edited) == .failure(.changed(["b"])))
        #expect(WorkflowDraftTester.reusePlan(from: first, nodeID: "b", definition: edited).isSuccess)
        #expect(
            WorkflowDraftTester.reusePlan(from: first, nodeID: "zzz", definition: edited)
                == .failure(.unknownStep("zzz")))

        let broken = await Self.run(Self.definition(), executor: Self.executor(NodeCallLog(), failing: "b"))
        #expect(broken.status == .failed)
        #expect(
            WorkflowDraftTester.reusePlan(from: broken, nodeID: "c", definition: Self.definition())
                == .failure(.unfinished(["b"])))
        #expect(WorkflowDraftTester.ReuseRefusal.changed(["b"]).message.contains("b"))
    }

    @Test
    func plan_refusesAStepWhoseFilesWereDeleted() async throws {
        let def = Self.definition()
        let first = await Self.run(def, executor: Self.executor(NodeCallLog()))
        let image = try #require(first.artifacts.first { $0.nodeID == "b" })
        #expect(WorkflowDraftTester.reusePlan(from: first, nodeID: "c", definition: def).isSuccess)

        try FileManager.default.removeItem(atPath: image.path)
        let refusal = WorkflowDraftTester.reusePlan(from: first, nodeID: "c", definition: def)
        #expect(refusal == .failure(.missingFiles(["b"])))
        #expect(WorkflowDraftTester.reusePlan(from: first, nodeID: "b", definition: def).isSuccess)
        #expect(WorkflowDraftTester.ReuseRefusal.missingFiles(["b"]).message.contains("Run the whole test again"))
    }

    // MARK: - Runner

    @Test
    func runner_runsOnlyFromTheStepAndCarriesReusedResults() async throws {
        let def = Self.definition()
        let first = await Self.run(def, executor: Self.executor(NodeCallLog()))
        guard case .success(let plan) = WorkflowDraftTester.reusePlan(from: first, nodeID: "c", definition: def) else {
            Issue.record("expected a plan")
            return
        }
        let log = NodeCallLog()
        let second = await Self.run(
            def, executor: Self.executor(log), startAt: plan.startAt, pinned: plan.pinned, reusing: first,
            input: plan.input)

        #expect(second.status == .completed)
        #expect(await log.calls == ["c"])
        for id in ["a", "b"] {
            let node = second.node(id)
            #expect(node?.status == .pinned)
            #expect(node?.reusedFrom == first.id)
            #expect(node?.input == first.node(id)?.input)
            #expect(node?.specHash == first.node(id)?.specHash)
        }
        #expect(second.node("c")?.reusedFrom == nil)
        #expect(second.output?.value(atPath: "final") == .string("c(b(a(s)))"))
        let carried = second.artifacts.filter { $0.nodeID == "b" }
        #expect(carried.map(\.path) == first.artifacts.filter { $0.nodeID == "b" }.map(\.path))

        // A reused run can be reused again: its hashes still match.
        #expect(WorkflowDraftTester.reusePlan(from: second, nodeID: "c", definition: def).isSuccess)
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
