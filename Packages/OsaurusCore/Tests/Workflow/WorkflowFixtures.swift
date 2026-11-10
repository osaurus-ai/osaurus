//
//  WorkflowFixtures.swift
//  OsaurusCoreTests
//
//  Shared builders for workflow tests: schemas, a small intake workflow
//  with a decide branch, and a closure-backed node executor.
//

import Foundation

@testable import OsaurusCore

enum WF {
    static let string: JSONValue = .object(["type": .string("string")])
    static let number: JSONValue = .object(["type": .string("number")])
    static let bool: JSONValue = .object(["type": .string("boolean")])

    static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static func code(_ id: String, input: WorkflowBinding = .object([:]), output: JSONValue = object([:]))
        -> WorkflowNode
    {
        WorkflowNode(
            id: id, name: id.capitalized,
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }")),
            input: input, outputSchema: output)
    }

    /// classify (decide new|existing) -> onboard | lookup -> notify (join).
    static func intake() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: object(["client": string], required: ["client"]),
            outputSchema: object(
                ["category": string, "welcome": .object(["type": .array([.string("string"), .string("null")])]), "record": .object([:])],
                required: ["category"]),
            nodes: [
                WorkflowNode(
                    id: "classify", name: "Classify",
                    kind: .inference(
                        InferenceSpec(
                            modelSlot: "decision", instructions: "Is {{input.client}} new or existing?",
                            mode: .decide(options: ["new", "existing"]))),
                    input: .object(["client": "{{input.client}}"])),
                code("onboard", input: .object(["client": "{{input.client}}"]), output: object(["welcome": string])),
                code("lookup", input: .object(["client": "{{input.client}}"]), output: object(["id": number])),
                code("notify", input: .object(["welcome": "{{nodes.onboard.output.welcome}}"])),
            ],
            edges: [
                WorkflowEdge(from: "classify", to: "onboard", when: WorkflowCondition(path: "choice", value: .string("new"))),
                WorkflowEdge(
                    from: "classify", to: "lookup", when: WorkflowCondition(path: "choice", value: .string("existing"))),
                WorkflowEdge(from: "onboard", to: "notify"),
                WorkflowEdge(from: "lookup", to: "notify"),
            ],
            output: .object([
                "category": "{{nodes.classify.output.choice}}",
                "welcome": "{{nodes.onboard.output.welcome}}",
                "record": "{{nodes.lookup.output}}",
            ]))
    }

    static func template(_ def: WorkflowDefinition, name: String = "Client Intake") -> Template {
        Template(name: name, summary: "Test workflow", payload: .workflow(def))
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ClosureExecutor: WorkflowNodeExecuting {
    let body: @Sendable (WorkflowNodeContext, WorkflowAwaitingUserHandler) async throws -> WorkflowNodeOutcome

    init(_ body: @escaping @Sendable (WorkflowNodeContext, WorkflowAwaitingUserHandler) async throws -> WorkflowNodeOutcome) {
        self.body = body
    }

    func execute(_ context: WorkflowNodeContext, awaitingUser: WorkflowAwaitingUserHandler) async throws
        -> WorkflowNodeOutcome
    {
        try await body(context, awaitingUser)
    }
}

/// Counts calls per node and tracks peak concurrency.
actor NodeCallLog {
    private(set) var calls: [String] = []
    private(set) var peak = 0
    private var inFlight = 0

    func enter(_ id: String) {
        calls.append(id)
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func leave() { inFlight -= 1 }

    func count(_ id: String) -> Int { calls.filter { $0 == id }.count }
}

/// Every run a runner published to its observer, in order.
actor PublishedRuns {
    private(set) var runs: [WorkflowRun] = []

    func add(_ run: WorkflowRun) { runs.append(run) }
}
