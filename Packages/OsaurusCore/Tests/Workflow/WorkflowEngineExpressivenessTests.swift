//
//  WorkflowEngineExpressivenessTests.swift
//  OsaurusCoreTests
//
//  The engine features the Architect builds with beyond a straight DAG:
//  rich `when` conditions, error edges and `on_error`, `join: all`
//  merges, map fan-out, wait steps, retry-from-failed-step, Python and
//  sub-workflow steps against scripted runtimes, HTTP steps against a
//  scripted transport, and the format round trip for every new field.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowEngineExpressivenessTests {

    // MARK: - Conditions

    @Test
    func conditions_compareNumbersStringsDatesAndGroups() {
        let output: JSONValue = .object([
            "score": .number(7), "tier": .string("gold"), "tags": .array([.string("a"), .string("b")]),
            "when": .string("2026-03-01T09:00:00Z"), "empty": .string(""), "flag": .bool(true),
            "nested": .object(["n": .string("12")]),
        ])
        func holds(_ c: WorkflowCondition) -> Bool { c.evaluate(output) }
        #expect(holds(WorkflowCondition(path: "score", op: .greaterThan, value: .number(5))))
        #expect(!holds(WorkflowCondition(path: "score", op: .lessThan, value: .number(5))))
        #expect(holds(WorkflowCondition(path: "nested.n", op: .greaterOrEqual, value: .number(12))))
        #expect(holds(WorkflowCondition(path: "tier", op: .in, value: .array([.string("gold"), .string("silver")]))))
        #expect(holds(WorkflowCondition(path: "tier", op: .notIn, value: .array([.string("bronze")]))))
        #expect(holds(WorkflowCondition(path: "tags", op: .contains, value: .string("b"))))
        #expect(holds(WorkflowCondition(path: "tier", op: .startsWith, value: .string("go"))))
        #expect(holds(WorkflowCondition(path: "tier", op: .endsWith, value: .string("ld"))))
        #expect(holds(WorkflowCondition(path: "tier", op: .matches, value: .string("^g.*d$"))))
        #expect(holds(WorkflowCondition(path: "when", op: .lessThan, value: .string("2026-04-01T00:00:00Z"))))
        #expect(holds(WorkflowCondition(path: "empty", op: .isEmpty)))
        #expect(holds(WorkflowCondition(path: "tags", op: .notEmpty)))
        #expect(holds(WorkflowCondition(path: "flag", op: .isTrue)))
        #expect(holds(WorkflowCondition(path: "missing", op: .notExists)))
        #expect(
            holds(
                .all([
                    WorkflowCondition(path: "score", op: .greaterThan, value: .number(5)),
                    .not(WorkflowCondition(path: "tier", op: .equals, value: .string("bronze"))),
                ])))
        #expect(
            !holds(
                .any([
                    WorkflowCondition(path: "score", op: .greaterThan, value: .number(50)),
                    WorkflowCondition(path: "tier", op: .equals, value: .string("bronze")),
                ])))
    }

    @Test
    func conditions_roundTripAndReportIssues() throws {
        let json = """
            {"all": [{"path": "score", "op": "greater_than", "value": 3}, {"not": {"path": "tier", "op": "equals", "value": "x"}}]}
            """
        let decoded = try JSONDecoder().decode(WorkflowCondition.self, from: Data(json.utf8))
        #expect(decoded.all?.count == 2)
        #expect(decoded.all?[1].not?.first?.path == "tier")
        let encoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(WorkflowCondition.self, from: encoded)
        #expect(again == decoded)
        #expect(WorkflowCondition(path: "x", op: .greaterThan).issues.contains { $0.contains("value") })
        #expect(WorkflowCondition(path: "x", op: .matches, value: .string("(")).issues.contains { $0.contains("regular expression") })
    }

    // MARK: - Error edges and on_error

    /// fetch (fails) -> summarize (success edge) ; fetch -> fallback (error edge) -> done (join any).
    static func errorBranchDefinition(onError: NodeErrorPolicy) -> WorkflowDefinition {
        var fetch = WF.code("fetch", output: WF.object(["text": WF.string]))
        fetch.onError = onError
        return WorkflowDefinition(
            inputSchema: WF.object([:]),
            outputSchema: WF.object(["result": .object([:])]),
            nodes: [
                fetch,
                WF.code("summarize", input: .object(["text": "{{nodes.fetch.output.text}}"]), output: WF.object(["summary": WF.string])),
                WF.code("fallback", input: .object(["why": "{{nodes.fetch.output.error.message}}"]), output: WF.object(["summary": WF.string])),
                WF.code("done"),
            ],
            edges: [
                WorkflowEdge(from: "fetch", to: "summarize"),
                WorkflowEdge(from: "fetch", to: "fallback", on: .error),
                WorkflowEdge(from: "summarize", to: "done"),
                WorkflowEdge(from: "fallback", to: "done"),
            ],
            output: .object(["result": "{{nodes.done.output}}"]))
    }

    static func errorBranchExecutor(fetchFails: Bool, log: NodeCallLog) -> ClosureExecutor {
        ClosureExecutor { ctx, _ in
            await log.enter(ctx.node.id)
            defer { Task { await log.leave() } }
            switch ctx.node.id {
            case "fetch":
                if fetchFails {
                    throw WorkflowNodeError.toolFailed(tool: "http", kind: "http_503", message: "down", retryable: false)
                }
                return WorkflowNodeOutcome(output: .object(["text": .string("page")]))
            case "summarize": return WorkflowNodeOutcome(output: .object(["summary": .string("S")]))
            case "fallback":
                return WorkflowNodeOutcome(output: .object(["summary": .string("fallback: \(ctx.input.value(atPath: "why")?.stringValue ?? "")")]))
            default: return WorkflowNodeOutcome(output: .object(["ok": .bool(true)]))
            }
        }
    }

    @Test
    func validator_requiresContinueForErrorEdges() {
        let issues = WorkflowValidator.validate(Self.errorBranchDefinition(onError: .fail), allowPlaceholders: false)
        #expect(issues.contains { $0.message.contains("on_error") })
        #expect(WorkflowValidator.validate(Self.errorBranchDefinition(onError: .continue), allowPlaceholders: false).isEmpty)
    }

    @Test
    func errorEdge_carriesWhenTheSourceFailsWithContinue() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(Self.errorBranchDefinition(onError: .continue), input: .object([:])),
            executor: Self.errorBranchExecutor(fetchFails: true, log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("fetch")?.status == .failed)
        #expect(run.node("fetch")?.output?.value(atPath: "error.kind") == .string("http_503"))
        #expect(run.node("summarize")?.status == .skipped)
        #expect(run.node("fallback")?.status == .done)
        #expect(run.node("fallback")?.output?.value(atPath: "summary")?.stringValue?.contains("down") == true)
        #expect(run.node("done")?.status == .done)
        #expect(await log.count("summarize") == 0)
    }

    @Test
    func errorEdge_doesNotCarryWhenTheSourceSucceeds() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(Self.errorBranchDefinition(onError: .continue), input: .object([:])),
            executor: Self.errorBranchExecutor(fetchFails: false, log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("summarize")?.status == .done)
        #expect(run.node("fallback")?.status == .skipped)
        #expect(await log.count("fallback") == 0)
    }

    @Test
    func onErrorSkip_treatsTheFailureAsABranchNotTaken() async {
        var def = Self.errorBranchDefinition(onError: .skip)
        def.edges.removeAll { $0.on == .error }
        def.nodes.removeAll { $0.id == "fallback" }
        def.edges.removeAll { $0.from == "fallback" }
        // `done` must still run: give it a second path from a node that succeeds.
        def.nodes.append(WF.code("always"))
        def.edges.append(WorkflowEdge(from: "always", to: "done"))
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object([:])),
            executor: Self.errorBranchExecutor(fetchFails: true, log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("fetch")?.status == .skipped)
        #expect(run.node("fetch")?.error?.contains("down") == true)
        #expect(run.node("summarize")?.status == .skipped)
        #expect(run.node("done")?.status == .done)
    }

    // MARK: - join: all

    @Test
    func joinAll_runsOnlyWhenEveryIncomingEdgePasses() async {
        // classify -> onboard | lookup -> notify(join: all): only one branch is taken, so notify is skipped.
        var def = WF.intake()
        if let i = def.nodes.firstIndex(where: { $0.id == "notify" }) { def.nodes[i].join = .all }
        def.output = .object(["category": "{{nodes.classify.output.choice}}"])
        def.outputSchema = WF.object(["category": WF.string])
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def), executor: WorkflowRunnerTests.intakeExecutor(choice: "new", log: log)
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("notify")?.status == .skipped)
        #expect(await log.count("notify") == 0)
    }

    @Test
    func joinAll_mergesParallelBranches() async {
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object(["both": .object([:])]),
            nodes: [
                WF.code("a", output: WF.object(["v": WF.number])), WF.code("b", output: WF.object(["v": WF.number])),
                {
                    var merge = WF.code("merge", input: .object(["a": "{{nodes.a.output.v}}", "b": "{{nodes.b.output.v}}"]))
                    merge.join = .all
                    return merge
                }(),
            ],
            edges: [WorkflowEdge(from: "a", to: "merge"), WorkflowEdge(from: "b", to: "merge")],
            output: .object(["both": "{{nodes.merge.output}}"]))
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object([:])),
            executor: ClosureExecutor { ctx, _ in
                switch ctx.node.id {
                case "a": return WorkflowNodeOutcome(output: .object(["v": .number(1)]))
                case "b": return WorkflowNodeOutcome(output: .object(["v": .number(2)]))
                default: return WorkflowNodeOutcome(output: ctx.input)
                }
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(run.node("merge")?.output == .object(["a": .number(1), "b": .number(2)]))
    }

    // MARK: - Map

    static func mapDefinition(concurrency: Int = 3, onItemError: MapSpec.ItemErrorPolicy = .fail) -> WorkflowDefinition {
        let step: JSONValue = .object([
            "name": .string("Shout"),
            "kind": .string("code"),
            "code": .object(["source": .string("async function run(input, ctx) { return {} }")]),
            "input": .object(["word": .string("{{item.word}}"), "n": .string("{{index}}")]),
            "output_schema": WF.object(["loud": WF.string], required: ["loud"]),
        ])
        return WorkflowDefinition(
            inputSchema: WF.object(["words": .object(["type": .string("array")])], required: ["words"]),
            outputSchema: WF.object(["all": .object([:])]),
            nodes: [
                WorkflowNode(
                    id: "each", name: "Each word",
                    kind: .map(MapSpec(items: "{{input.words}}", step: step, concurrency: concurrency, onItemError: onItemError))),
                WF.code("collect", input: .object(["items": "{{nodes.each.output.items}}", "count": "{{nodes.each.output.count}}"])),
            ],
            edges: [WorkflowEdge(from: "each", to: "collect")],
            output: .object(["all": "{{nodes.collect.output}}"]))
    }

    static let words: JSONValue = .array([
        .object(["word": .string("a")]), .object(["word": .string("b")]), .object(["word": .string("c")]),
        .object(["word": .string("d")]), .object(["word": .string("e")]),
    ])

    @Test
    func map_validatesBodyAndItemReferences() {
        #expect(WorkflowValidator.validate(Self.mapDefinition(), allowPlaceholders: false).isEmpty)
        // {{item}} outside a map step is an error.
        var def = Self.mapDefinition()
        def.nodes[1].input = .object(["bad": "{{item.word}}"])
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).contains { $0.message.contains("map step") })
        // A dialog body is refused.
        var nested = Self.mapDefinition()
        if case .map(var spec) = nested.nodes[0].kind {
            spec.step = .object(["kind": .string("dialog"), "dialog": .object(["title": .string("x"), "message": .string("y"), "fields": .array([])])])
            nested.nodes[0].kind = .map(spec)
        }
        #expect(WorkflowValidator.validate(nested, allowPlaceholders: false).contains { $0.message.contains("dialog") })
    }

    @Test
    func map_runsTheStepPerItemBoundedByConcurrencyAndKeepsOrder() async {
        let log = NodeCallLog()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(Self.mapDefinition(concurrency: 2), input: .object(["words": Self.words])),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                defer { Task { await log.leave() } }
                if ctx.node.id == "each.item" {
                    #expect(ctx.bindings.item != nil)
                    try await Task.sleep(nanoseconds: 20_000_000)
                    let word = ctx.input.value(atPath: "word")?.stringValue ?? "?"
                    let n = ctx.input.value(atPath: "n")?.numberValue ?? -1
                    return WorkflowNodeOutcome(output: .object(["loud": .string("\(word.uppercased())\(Int(n))")]))
                }
                return WorkflowNodeOutcome(output: ctx.input)
            }
        ).execute()
        #expect(run.status == .completed)
        #expect(await log.count("each.item") == 5)
        #expect(await log.peak <= 2)
        let items = run.node("each")?.output?.value(atPath: "items")?.arrayValue ?? []
        #expect(items.map { $0.value(atPath: "loud") } == [.string("A0"), .string("B1"), .string("C2"), .string("D3"), .string("E4")])
        #expect(run.node("each")?.output?.value(atPath: "count") == .number(5))
        #expect(run.node("collect")?.output?.value(atPath: "count") == .number(5))
    }

    @Test
    func map_publishesLiveItemStatesBoundedByConcurrencyThenClearsThem() async {
        let published = PublishedRuns()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(
                Self.mapDefinition(concurrency: 2, onItemError: .skip), input: .object(["words": Self.words])),
            executor: ClosureExecutor { ctx, _ in
                guard ctx.node.id == "each.item" else { return WorkflowNodeOutcome(output: ctx.input) }
                // Longer than the publish interval, so each round of items is published.
                try await Task.sleep(nanoseconds: 250_000_000)
                if ctx.input.value(atPath: "word") == .string("c") { throw WorkflowNodeError.unsupported("no c") }
                return WorkflowNodeOutcome(output: .object(["loud": .string("ok")]))
            },
            observer: { await published.add($0) }
        ).execute()
        #expect(run.status == .completed)
        let snapshots = await published.runs.compactMap { $0.node("each")?.mapItems }
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.count == 5 })
        #expect(snapshots.allSatisfy { states in states.filter { $0 == .running }.count <= 2 })
        #expect(snapshots.first?.filter { $0 == .running }.count == 2)
        #expect(snapshots.last == [.done, .done, .failed, .done, .done])
        #expect(run.node("each")?.mapItems == nil)
        #expect(await published.runs.last?.node("each")?.mapItems == nil)
    }

    @Test
    func map_liveItemStatesAreNotSaved() throws {
        var node = NodeRun(nodeID: "each", status: .running)
        node.mapItems = [.done, .running, .pending]
        let data = try JSONEncoder().encode(node)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("map_items") && !json.contains("mapItems"))
        #expect(try JSONDecoder().decode(NodeRun.self, from: data).mapItems == nil)
    }

    @Test
    func map_itemFailureFailsTheStepOrIsSkippedPerPolicy() async {
        let failing = ClosureExecutor { ctx, _ in
            if ctx.node.id == "each.item", ctx.input.value(atPath: "word") == .string("c") {
                throw WorkflowNodeError.unsupported("no c")
            }
            if ctx.node.id == "each.item" {
                return WorkflowNodeOutcome(output: .object(["loud": .string("ok")]))
            }
            return WorkflowNodeOutcome(output: ctx.input)
        }
        let strict = await WorkflowRunner(
            request: WorkflowRunnerTests.request(Self.mapDefinition(), input: .object(["words": Self.words])),
            executor: failing
        ).execute()
        #expect(strict.status == .failed)
        #expect(strict.error?.nodeID == "each")
        #expect(strict.error?.reason.contains("no c") == true)

        let lenient = await WorkflowRunner(
            request: WorkflowRunnerTests.request(
                Self.mapDefinition(onItemError: .skip), input: .object(["words": Self.words])),
            executor: failing
        ).execute()
        #expect(lenient.status == .completed)
        let items = lenient.node("each")?.output?.value(atPath: "items")?.arrayValue ?? []
        #expect(items.count == 5)
        #expect(items[2] == .null)
        let failed = lenient.node("each")?.output?.value(atPath: "failed")?.arrayValue ?? []
        #expect(failed.count == 1)
        #expect(failed.first?.value(atPath: "index") == .number(2))
    }

    @Test
    func map_nonArrayItemsFailsTheStep() async {
        var def = Self.mapDefinition()
        def.inputSchema = WF.object(["words": .object([:])])
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object(["words": .string("nope")])),
            executor: ClosureExecutor { ctx, _ in WorkflowNodeOutcome(output: ctx.input) }
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("must bind to an array") == true)
    }

    // MARK: - Wait

    @Test
    func wait_sleepsForSecondsAndSkipsInTests() async throws {
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object(["waited": WF.number]),
            nodes: [WorkflowNode(id: "pause", name: "Pause", kind: .wait(WaitSpec(seconds: "0.2")))],
            output: .object(["waited": "{{nodes.pause.output.waited_seconds}}"]))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        let started = Date()
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object([:])), executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(run.status == .completed)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        #expect(run.output?.value(atPath: "waited") == .number(0))

        let test = await WorkflowRunner(
            request: WorkflowRunnerTests.request(
                {
                    var long = def
                    long.nodes[0].kind = .wait(WaitSpec(seconds: "3600"))
                    return long
                }(), input: .object([:]), caller: WorkflowCaller(kind: .test)),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(test.status == .completed, "\(String(describing: test.error))")
        #expect(test.node("pause")?.logs.contains { $0.contains("skipped the wait") } == true)
    }

    @Test
    func wait_validatesSpec() {
        func def(_ spec: WaitSpec, timeout: TimeInterval? = nil) -> WorkflowDefinition {
            var node = WorkflowNode(id: "w", name: "W", kind: .wait(spec))
            if let timeout { node.timeout = timeout }
            return WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [node])
        }
        #expect(WorkflowValidator.validate(def(WaitSpec()), allowPlaceholders: false).contains { $0.message.contains("exactly one") })
        #expect(WorkflowValidator.validate(def(WaitSpec(seconds: "10", until: "2026-01-01T00:00:00Z")), allowPlaceholders: false).contains { $0.message.contains("exactly one") })
        #expect(WorkflowValidator.validate(def(WaitSpec(until: "tomorrow")), allowPlaceholders: false).contains { $0.message.contains("ISO 8601") })
        #expect(WorkflowValidator.validate(def(WaitSpec(seconds: "600"), timeout: 30), allowPlaceholders: false).contains { $0.message.contains("shorter than the wait") })
        #expect(WorkflowValidator.validate(def(WaitSpec(until: "{{input.at}}")), allowPlaceholders: false).isEmpty)
    }

    @Test
    func nonFiniteTimeouts_areRejected_largeOnesClamped() {
        func messages(_ node: WorkflowNode) -> [String] {
            WorkflowValidator.validate(
                WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [node]),
                allowPlaceholders: false
            ).map(\.message)
        }
        for timeout in [Double.nan, -.infinity, .infinity] {
            var wait = WorkflowNode(id: "w", name: "W", kind: .wait(WaitSpec(seconds: "10")))
            wait.timeout = timeout
            #expect(messages(wait).contains { $0.hasPrefix("w: timeout must be") }, "timeout \(timeout)")

            let code = WorkflowNode(
                id: "c", name: "C",
                kind: .code(CodeSpec(language: .python, source: "def run(input, ctx):\n    return {}", timeout: timeout)))
            #expect(messages(code).contains { $0.hasPrefix("c: code timeout must be") }, "code timeout \(timeout)")
        }
        var huge = WorkflowNode(id: "w", name: "W", kind: .wait(WaitSpec(seconds: "10")))
        huge.timeout = 1e19
        #expect(messages(huge).isEmpty, "the registry publishes large finite timeouts; runners clamp them")
        let nan = WorkflowNode(id: "w", name: "W", kind: .wait(WaitSpec(seconds: "nan")))
        #expect(messages(nan).contains { $0.contains("must be a number") })
    }

    @Test
    func clampedInt_neverTraps() {
        #expect(Double.nan.clampedInt(in: 1...Int.max) == 1)
        #expect(Double.infinity.clampedInt() == Int.max)
        #expect((-Double.infinity).clampedInt() == Int.min)
        #expect(1e19.clampedInt() == Int.max)
        #expect(2.5.clampedInt(.up, in: 1...Int.max) == 3)
        #expect(0.2.clampedInt(in: 1...Int.max) == 1)
        #expect(119.9.clampedInt() == 119)
    }

    @Test
    func wait_fromAHugeBoundSecondsFailsTheStepInsteadOfTrapping() async {
        let node = WorkflowNode(
            id: "pause", name: "Pause", kind: .wait(WaitSpec(seconds: "{{input.s}}")))
        let def = WorkflowDefinition(
            inputSchema: WF.object(["s": WF.number]), outputSchema: WF.object([:]), nodes: [node])
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object(["s": .number(1e20)])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("pauses at most") == true, "\(String(describing: run.error))")
    }

    // MARK: - Retry from failed step

    @Test
    func retry_keepsFinishedStepsAndRunsTheFailedOneAgain() async {
        let def = Self.errorBranchDefinition(onError: .fail)
        var cleaned = def
        cleaned.edges.removeAll { $0.on == .error }
        cleaned.nodes.removeAll { $0.id == "fallback" }
        cleaned.edges.removeAll { $0.from == "fallback" }
        // fetch succeeds, summarize fails the first time.
        let log = NodeCallLog()
        let first = await WorkflowRunner(
            request: WorkflowRunnerTests.request(cleaned, input: .object([:])),
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                defer { Task { await log.leave() } }
                switch ctx.node.id {
                case "fetch": return WorkflowNodeOutcome(output: .object(["text": .string("page")]))
                case "summarize": throw WorkflowNodeError.unsupported("model down")
                default: return WorkflowNodeOutcome(output: .object(["ok": .bool(true)]))
                }
            }
        ).execute()
        #expect(first.status == .failed)
        #expect(first.error?.nodeID == "summarize")
        #expect(first.node("done")?.status == .skipped)

        var request = WorkflowRunnerTests.request(cleaned, input: .object([:]))
        request.retrying = first
        let second = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { ctx, _ in
                await log.enter(ctx.node.id)
                defer { Task { await log.leave() } }
                switch ctx.node.id {
                case "fetch": Issue.record("fetch ran again"); return WorkflowNodeOutcome(output: .object([:]))
                case "summarize":
                    #expect(ctx.input.value(atPath: "text") == .string("page"))
                    return WorkflowNodeOutcome(output: .object(["summary": .string("S")]))
                default: return WorkflowNodeOutcome(output: .object(["ok": .bool(true)]))
                }
            }
        ).execute()
        #expect(second.status == .completed)
        #expect(second.id != first.id)
        #expect(second.retryOf == first.id)
        #expect(second.workspaceRunID == first.id)
        #expect(second.node("fetch")?.status == .done)
        #expect(second.node("summarize")?.status == .done)
        #expect(second.node("done")?.status == .done)
        #expect(await log.count("fetch") == 1)
        #expect(await log.count("summarize") == 2)
    }

    @Test
    func http_refusesOsaurusOwnServerPort_onLoopbackOnly() {
        let hosts: Set<String> = ["localhost", "127.0.0.1", "::1", "api.example.com"]
        for blocked in ["http://127.0.0.1:1337/admin/config", "http://localhost:1337/v1", "http://[::1]:1337/"] {
            let reason = HTTPNodeExecutor.isAllowed(URL(string: blocked)!, hosts: hosts, osaurusPort: 1337)
            #expect(reason?.contains("Osaurus's own server") == true, "\(blocked) → \(reason ?? "allowed")")
        }
        #expect(HTTPNodeExecutor.isAllowed(URL(string: "http://localhost:8080/x")!, hosts: hosts, osaurusPort: 1337) == nil)
        #expect(HTTPNodeExecutor.isAllowed(URL(string: "https://api.example.com/x")!, hosts: hosts, osaurusPort: 443) == nil)
        // No explicit port: the scheme's default is the one compared.
        #expect(HTTPNodeExecutor.isAllowed(URL(string: "http://localhost/x")!, hosts: hosts, osaurusPort: 80) != nil)
        let redirect = HTTPNodeExecutor.RedirectGuard(allowedHosts: hosts, osaurusPort: 1337)
        #expect(redirect.osaurusPort == 1337)
    }

    // MARK: - Python

    @Test
    func python_writesABundleRunsItThroughShellRunAndReadsTheOutput() async throws {
        let source = "def run(input, ctx):\n    return {\"doubled\": input[\"n\"] * 2, \"who\": ctx.caller.get(\"kind\")}\n"
        let node = WorkflowNode(
            id: "py", name: "Py", kind: .code(CodeSpec(language: .python, source: source, secrets: ["API_KEY"])),
            input: .object(["n": "{{input.n}}"]), outputSchema: WF.object(["doubled": WF.number]))
        let def = WorkflowDefinition(
            inputSchema: WF.object(["n": WF.number]), outputSchema: WF.object(["doubled": WF.number]), nodes: [node],
            output: .object(["doubled": "{{nodes.py.output.doubled}}"]))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        #expect(def.usesSandbox)
        #expect(WorkflowRequirementsDeriver.derive(def).tools.contains("shell_run"))

        let workspace = WF.tempDir()
        let seen = NodeCallLog()
        // A scripted shell: runs the command with the system python3 so the launcher is exercised for real.
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)), outputSchema: nil)
            },
            execute: { _, arguments, _ in
                await seen.enter(arguments)
                let args = JSONValue.parse(arguments)?.objectValue ?? [:]
                let command = args["command"]?.stringValue ?? ""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                try process.run()
                process.waitUntilExit()
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return ToolEnvelope.success(
                    tool: "shell_run",
                    result: ["exit_code": Int(process.terminationStatus), "stdout": stdout, "stderr": stderr])
            })
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Py", node: node, input: .object(["n": .number(21)]),
            bindings: BindingContext(
                input: .object(["n": .number(21)]), outputs: [:], run: .object([:]),
                caller: BindingContext.callerValue(WorkflowCaller(kind: .user))),
            model: nil, secretAccounts: [:], secrets: ["API_KEY": "sk-test"], caller: WorkflowCaller(kind: .user),
            workspace: workspace, attempt: 1, timeout: 30)
        guard case .code(let spec) = node.kind else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            // No interpreter on this Mac: the bundle and command are still checked.
            return
        }
        let outcome = try await PythonCodeNodeExecutor.run(spec: spec, context: context, runtime: runtime)
        #expect(outcome.output.value(atPath: "doubled") == .number(42))
        #expect(outcome.output.value(atPath: "who") == .string("user"))
        let command = await seen.calls.first ?? ""
        #expect(command.contains("python3"))
        #expect(command.contains(".osaurus/python/py-1/main.py"))
        // The bundle is gone once the step ends.
        let bundle = PythonCodeNodeExecutor.bundleDirectory(workspace: workspace, nodeID: "py", attempt: 1)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test
    func python_nonZeroExitFailsWithTheLastLine() async throws {
        let node = WorkflowNode(
            id: "py", name: "Py", kind: .code(CodeSpec(language: .python, source: "def run(input, ctx):\n    raise ValueError('boom')\n")))
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in ToolNodeExecutor.Resolved(spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)), outputSchema: nil) },
            execute: { _, _, _ in
                ToolEnvelope.success(
                    tool: "shell_run",
                    result: ["exit_code": 1, "stdout": "", "stderr": "Traceback\nValueError: boom"])
            })
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Py", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        guard case .code(let spec) = node.kind else { return }
        await #expect(throws: RecordedNodeFailure.self) {
            try await PythonCodeNodeExecutor.run(spec: spec, context: context, runtime: runtime)
        }
    }

    // MARK: - Sub-workflows

    @Test
    func subworkflow_runsTheInstalledWorkflowAndBindsItsOutput() async throws {
        let inner = WF.template(WF.intake(), name: "Client Intake")
        let installed = InstalledWorkflow(template: inner, bindings: InstallBindings())
        let node = WorkflowNode(
            id: "intake", name: "Intake", kind: .workflow(SubworkflowSpec(workflow: "Client Intake")),
            input: .object(["client": "{{input.client}}"]))
        let parentWorkflowID = UUID()
        let parentRunID = UUID()
        let context = WorkflowNodeContext(
            runID: parentRunID, workflowID: parentWorkflowID, workflowName: "Parent", node: node,
            input: .object(["client": .string("Acme")]), bindings: BindingContext(input: .object([:]), outputs: [:]),
            model: nil, secretAccounts: [:], caller: WorkflowCaller(kind: .agent, agentName: "Ops"),
            workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let runtime = SubworkflowNodeExecutor.Runtime(
            resolve: { name in
                name == "Client Intake" ? SubworkflowNodeExecutor.Resolved(workflow: installed, setupProblems: []) : nil
            },
            run: { workflow, input, caller, _ in
                #expect(caller.kind == .workflow)
                #expect(caller.parentRunID == parentRunID)
                #expect(caller.ancestors == [parentWorkflowID])
                #expect(caller.agentName == "Ops")
                var run = WorkflowRun(
                    id: UUID(), workflowID: workflow.id, workflowName: workflow.name, templateID: workflow.template.id,
                    templateVersion: 1, caller: caller, input: input, nodeIDs: [])
                run.status = .completed
                run.output = .object(["category": .string("new")])
                return run
            })
        let outcome = try await SubworkflowNodeExecutor.run(
            spec: SubworkflowSpec(workflow: "Client Intake"), context: context, awaitingUser: { _ in }, runtime: runtime)
        #expect(outcome.output == .object(["category": .string("new")]))
    }

    @Test
    func subworkflow_refusesCyclesAndDepth() async throws {
        let inner = WF.template(WF.intake())
        let installed = InstalledWorkflow(template: inner, bindings: InstallBindings())
        let runtime = SubworkflowNodeExecutor.Runtime(
            resolve: { _ in SubworkflowNodeExecutor.Resolved(workflow: installed, setupProblems: []) },
            run: { _, _, _, _ in Issue.record("should not run"); return nil })
        let node = WorkflowNode(id: "again", name: "Again", kind: .workflow(SubworkflowSpec(workflow: "x")))
        // The target is already up the chain.
        let cyclic = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "P", node: node, input: .object(["client": .string("A")]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .workflow, ancestors: [installed.id]), workspace: WF.tempDir(), attempt: 1,
            timeout: 30)
        await #expect(throws: WorkflowNodeError.self) {
            try await SubworkflowNodeExecutor.run(spec: SubworkflowSpec(workflow: "x"), context: cyclic, awaitingUser: { _ in }, runtime: runtime)
        }
        let deep = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "P", node: node, input: .object(["client": .string("A")]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .workflow, ancestors: (0 ..< SubworkflowSpec.maximumDepth).map { _ in UUID() }),
            workspace: WF.tempDir(), attempt: 1, timeout: 30)
        await #expect(throws: WorkflowNodeError.self) {
            try await SubworkflowNodeExecutor.run(spec: SubworkflowSpec(workflow: "x"), context: deep, awaitingUser: { _ in }, runtime: runtime)
        }
    }

    /// A parent's review and setup show what the workflows its steps run
    /// reach, followed through children and around cycles; the sealed
    /// template (and so its hash) still carries only the parent's own.
    @Test
    func subworkflow_reachFollowsChildrenForHostsAndTools_butNotTheirBindings() throws {
        let childCall = WorkflowNode(
            id: "call", name: "Call",
            kind: .http(HTTPSpec(method: "get", url: "https://api.child.example/v1", auth: .bearer(secret: "CHILD_KEY"))))
        let childModel = WorkflowNode(
            id: "sum", name: "Summarize",
            kind: .inference(InferenceSpec(modelSlot: "child_writer", instructions: "x")))
        let childTool = WorkflowNode(
            id: "tool", name: "Tool", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "list_issues", server: "Linear"))))
        let grandchildCall = WorkflowNode(id: "again", name: "Again", kind: .workflow(SubworkflowSpec(workflow: "Parent")))
        let child = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [childCall, childModel, childTool, grandchildCall])

        let parentOwn = WorkflowNode(
            id: "own", name: "Own", kind: .http(HTTPSpec(method: "get", url: "https://api.parent.example/v1")))
        let step = WorkflowNode(id: "intake", name: "Intake", kind: .workflow(SubworkflowSpec(workflow: "Child")))
        let missing = WorkflowNode(id: "gone", name: "Gone", kind: .workflow(SubworkflowSpec(workflow: "Nowhere")))
        let parent = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [parentOwn, step, missing])

        var resolved: [String] = []
        let reach = WorkflowRequirementsDeriver.reach(parent) { name in
            resolved.append(name)
            switch name {
            case "Child": return child
            case "Parent": return parent  // The cycle back up.
            default: return nil
            }
        }
        #expect(resolved == ["Child", "Nowhere", "Parent"])
        #expect(reach.requirements.network == ["api.parent.example", "api.child.example"])
        #expect(reach.requirements.mcpServers == ["Linear"])
        // The child binds its own model and key; the parent must not ask for them.
        #expect(reach.requirements.secrets.isEmpty)
        #expect(reach.requirements.models.isEmpty)
        #expect(reach.subworkflows.map(\.name) == ["Child", "Nowhere", "Parent"])
        #expect(reach.subworkflows.map(\.calledFrom) == ["Intake", "Gone", "Child"])
        #expect(reach.subworkflows[0].requirements?.secrets.map(\.key) == ["CHILD_KEY"])
        #expect(reach.subworkflows[0].requirements?.models.map(\.slot) == ["child_writer"])
        #expect(reach.subworkflows[1].requirements == nil)
        // The template keeps only what it carries itself.
        #expect(WorkflowRequirementsDeriver.derive(parent).network == ["api.parent.example"])
        #expect(WorkflowRequirementsDeriver.derive(parent).mcpServers.isEmpty)
        #expect(WF.template(parent).sealed().requirements.network == ["api.parent.example"])

        let summary = TemplateImportReviewView.summary(of: reach.subworkflows[0])
        #expect(summary.contains("api.child.example") && summary.contains("Linear") && summary.contains("child_writer"))
        #expect(TemplateImportReviewView.summary(of: reach.subworkflows[1]).contains("Not installed"))
    }

    /// Setup treats a sub-workflow's blocking problems as the parent's: the
    /// step cannot run until the child can.
    @Test
    func subworkflow_setupReportsTheChildsOwnBlockers() {
        let step = WorkflowNode(id: "intake", name: "Intake", kind: .workflow(SubworkflowSpec(workflow: "Child")))
        let def = WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [step])
        let template = WF.template(def).sealed()
        var env = SetupChecker.Environment(
            registeredToolNames: [], modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })

        env.installedWorkflowSetup = { _ in nil }
        let absent = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
        #expect(absent.blocking.map(\.value) == ["workflow:Child"])
        #expect(absent.blocking.first?.detail.contains("not installed") == true)

        env.installedWorkflowSetup = { _ in ["Secret: Missing value for API key"] }
        let blocked = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
        #expect(blocked.blocking.map(\.value) == ["workflow:Child"])
        #expect(blocked.blocking.first?.detail.contains("needs setup first: Secret: Missing value for API key") == true)

        env.installedWorkflowSetup = { _ in [] }
        let ready = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
        #expect(!ready.hasBlockers)
    }

    // MARK: - HTTP

    @Test
    func http_rendersAuthAndBodyChecksHostsAndParsesJSON() async throws {
        let spec = HTTPSpec(
            method: "post", url: "https://api.example.com/v1/items?x={{input.x}}",
            headers: ["X-Trace": "{{run.id}}"], body: .object(["name": "{{input.name}}"]),
            auth: .bearer(secret: "API_KEY"))
        let node = WorkflowNode(id: "call", name: "Call", kind: .http(spec))
        let def = WorkflowDefinition(
            inputSchema: WF.object(["x": WF.string, "name": WF.string]), outputSchema: WF.object([:]), nodes: [node])
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        #expect(WorkflowRequirementsDeriver.derive(def).secrets.map(\.key) == ["API_KEY"])
        #expect(WorkflowRequirementsDeriver.derive(def).network == ["api.example.com"])

        let runID = UUID()
        let context = WorkflowNodeContext(
            runID: runID, workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(
                input: .object(["x": .string("1"), "name": .string("Widget")]), outputs: [:],
                run: BindingContext.runValue(id: runID, workspace: WF.tempDir())),
            model: nil, secretAccounts: [:], secrets: ["API_KEY": "sk-live-123"], caller: WorkflowCaller(kind: .user),
            workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let transport = HTTPNodeExecutor.Transport { request, hosts in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://api.example.com/v1/items?x=1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-live-123")
            #expect(request.value(forHTTPHeaderField: "X-Trace") == runID.uuidString)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(hosts == ["api.example.com"])
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(body.contains("\"name\":\"Widget\""))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data("{\"id\": 7}".utf8), response)
        }
        let outcome = try await HTTPNodeExecutor.run(spec: spec, context: context, transport: transport)
        #expect(outcome.output.value(atPath: "status") == .number(201))
        #expect(outcome.output.value(atPath: "ok") == .bool(true))
        #expect(outcome.output.value(atPath: "body.id") == .number(7))
        #expect(outcome.fetches.first?.hasPrefix("POST api.example.com/v1/items") == true)
    }

    private static func httpContext(_ node: WorkflowNode, input: JSONValue = .object([:])) -> WorkflowNodeContext {
        WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: input, outputs: [:]), model: nil, secretAccounts: [:],
            secrets: ["KEY": "k"], caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
    }

    private static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (
            Data(text.utf8),
            HTTPURLResponse(
                url: URL(string: "https://api.example.com/")!, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }

    /// `query` renders and percent-encodes parameters; a pasted key in
    /// one is refused by the validator the same way a header is.
    @Test
    func http_queryParameters_renderAndEncode() async throws {
        let spec = HTTPSpec(
            url: "https://api.example.com/search", query: ["q": "{{input.q}}", "per_page": "50"],
            auth: .query(name: "key", secret: "KEY"))
        let node = WorkflowNode(id: "s", name: "Search", kind: .http(spec))
        let def = WorkflowDefinition(inputSchema: WF.object(["q": WF.string]), outputSchema: WF.object([:]), nodes: [node])
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        let transport = HTTPNodeExecutor.Transport { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let names = items.map(\.name)
            let q = items.first(where: { $0.name == "q" })?.value
            #expect(names == ["per_page", "q", "key"], "\(items)")
            #expect(q == "a&b c")
            #expect(request.url?.absoluteString.contains("q=a%26b%20c") == true, "\(request.url?.absoluteString ?? "")")
            return Self.json(#"{"ok":true}"#)
        }
        let outcome = try await HTTPNodeExecutor.run(
            spec: spec, context: Self.httpContext(node, input: .object(["q": .string("a&b c")])), transport: transport)
        #expect(outcome.output.value(atPath: "body.ok") == .bool(true))

        var leaky = spec
        leaky.query = ["api_key": "sk_live_0123456789abcdef"]
        let issues = WorkflowValidator.validate(
            WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [WorkflowNode(id: "s", name: "S", kind: .http(leaky))]),
            allowPlaceholders: false)
        #expect(issues.contains { $0.message.contains("query parameter `api_key`") }, "\(issues)")
    }

    /// The four paging shapes merge their items in order, stop when the
    /// API says so, and report `pages`/`complete`.
    @Test
    func http_paginate_followsCursorNextURLLinkAndPageNumbers() async throws {
        // cursor in the body
        let cursor = HTTPSpec(
            url: "https://api.example.com/items", query: ["limit": "2"],
            paginate: HTTPPagination(mode: .cursor, itemsPath: "data", cursorPath: "meta.next", cursorParam: "after"))
        let cursorNode = WorkflowNode(id: "c", name: "C", kind: .http(cursor))
        #expect(
            WorkflowValidator.validate(
                WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [cursorNode]),
                allowPlaceholders: false
            ).isEmpty)
        let cursorPages: [String: String] = [
            "": #"{"data":[1,2],"meta":{"next":"c2"}}"#, "c2": #"{"data":[3],"meta":{"next":""}}"#,
        ]
        let cursorTransport = HTTPNodeExecutor.Transport { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let keepsLimit = items.contains(where: { $0.name == "limit" && $0.value == "2" })
            #expect(keepsLimit, "the first query stays on every page")
            let after: String = items.first(where: { $0.name == "after" })?.value ?? ""
            guard let page = cursorPages[after] else {
                Issue.record("unexpected cursor request: \(request.url?.absoluteString ?? "")")
                return Self.json("{}", status: 500)
            }
            return Self.json(page)
        }
        var outcome = try await HTTPNodeExecutor.run(spec: cursor, context: Self.httpContext(cursorNode), transport: cursorTransport)
        #expect(outcome.output.value(atPath: "body") == .array([.number(1), .number(2), .number(3)]))
        #expect(outcome.output.value(atPath: "pages") == .number(2))
        #expect(outcome.output.value(atPath: "complete") == .bool(true))
        #expect(outcome.fetches.count == 2)

        // next URL in the body, relative to the page
        let nextURL = HTTPSpec(
            url: "https://api.example.com/v1/things",
            paginate: HTTPPagination(mode: .nextURL, itemsPath: "results", nextURLPath: "next"))
        let nextNode = WorkflowNode(id: "n", name: "N", kind: .http(nextURL))
        let nextTransport = HTTPNodeExecutor.Transport { request, _ in
            #expect(request.url?.path == "/v1/things")
            if request.url?.query == nil { return Self.json(#"{"results":["a"],"next":"/v1/things?page=2"}"#) }
            #expect(request.url?.query == "page=2")
            return Self.json(#"{"results":["b"],"next":null}"#)
        }
        outcome = try await HTTPNodeExecutor.run(spec: nextURL, context: Self.httpContext(nextNode), transport: nextTransport)
        #expect(outcome.output.value(atPath: "body") == .array([.string("a"), .string("b")]))
        #expect(outcome.output.value(atPath: "complete") == .bool(true))

        // Link header, body is the array
        let link = HTTPSpec(url: "https://api.example.com/repos", paginate: HTTPPagination(mode: .link))
        let linkNode = WorkflowNode(id: "l", name: "L", kind: .http(link))
        let linkTransport = HTTPNodeExecutor.Transport { request, _ in
            if request.url!.query == nil {
                return Self.json(
                    #"[{"id":1}]"#,
                    headers: ["Link": "<https://api.example.com/repos?page=2>; rel=\"next\", <https://api.example.com/repos?page=9>; rel=\"last\""])
            }
            return Self.json(#"[{"id":2}]"#, headers: ["Link": "<https://api.example.com/repos?page=1>; rel=\"prev\""])
        }
        outcome = try await HTTPNodeExecutor.run(spec: link, context: Self.httpContext(linkNode), transport: linkTransport)
        #expect(outcome.output.value(atPath: "body") == .array([.object(["id": .number(1)]), .object(["id": .number(2)])]))
        #expect(outcome.output.value(atPath: "pages") == .number(2))

        // page numbers until an empty page
        let paged = HTTPSpec(
            url: "https://api.example.com/list?page=1",
            paginate: HTTPPagination(mode: .page, itemsPath: "items", pageParam: "page", startPage: 1))
        let pagedNode = WorkflowNode(id: "p", name: "P", kind: .http(paged))
        let pagedTransport = HTTPNodeExecutor.Transport { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let pageItems = items.filter { $0.name == "page" }
            #expect(pageItems.count == 1, "the page parameter is replaced, not repeated")
            let page = Int(pageItems.first?.value ?? "") ?? 0
            return Self.json(page <= 2 ? #"{"items":["p\#(page)"]}"# : #"{"items":[]}"#)
        }
        outcome = try await HTTPNodeExecutor.run(spec: paged, context: Self.httpContext(pagedNode), transport: pagedTransport)
        #expect(outcome.output.value(atPath: "body") == .array([.string("p1"), .string("p2")]))
        #expect(outcome.output.value(atPath: "pages") == .number(3))
        #expect(outcome.output.value(atPath: "complete") == .bool(true))
    }

    /// Caps and bad shapes: `max_pages` and `max_items` stop the walk
    /// with `complete: false`, a repeated page ends it, and a page
    /// without the items array fails with a pointer to `items_path`.
    @Test
    func http_paginate_capsAndRefusesBadShapes() async throws {
        let endless = HTTPSpec(
            url: "https://api.example.com/items",
            paginate: HTTPPagination(mode: .cursor, itemsPath: "data", cursorPath: "next", maxPages: 3))
        let node = WorkflowNode(id: "e", name: "E", kind: .http(endless))
        let counter = Counter()
        let endlessTransport = HTTPNodeExecutor.Transport { _, _ in
            let n = await counter.next()
            return Self.json(#"{"data":[\#(n)],"next":"c\#(n)"}"#)
        }
        var outcome = try await HTTPNodeExecutor.run(spec: endless, context: Self.httpContext(node), transport: endlessTransport)
        #expect(outcome.output.value(atPath: "pages") == .number(3))
        #expect(outcome.output.value(atPath: "complete") == .bool(false))
        #expect(outcome.logs.last?.contains("max_pages") == true, "\(outcome.logs)")

        var capped = endless
        capped.paginate?.maxItems = 2
        capped.paginate?.maxPages = 10
        await counter.reset()
        outcome = try await HTTPNodeExecutor.run(spec: capped, context: Self.httpContext(node), transport: endlessTransport)
        #expect((outcome.output.value(atPath: "body")?.arrayValue ?? []).count == 2)
        #expect(outcome.output.value(atPath: "complete") == .bool(false))

        // The API keeps handing back the same cursor.
        var stuck = endless
        stuck.paginate?.maxPages = 10
        let stuckTransport = HTTPNodeExecutor.Transport { _, _ in Self.json(#"{"data":[1],"next":"same"}"#) }
        outcome = try await HTTPNodeExecutor.run(spec: stuck, context: Self.httpContext(node), transport: stuckTransport)
        #expect(outcome.output.value(atPath: "pages") == .number(2))
        #expect(outcome.output.value(atPath: "complete") == .bool(true))

        // No array where items_path points.
        let wrongShape = HTTPNodeExecutor.Transport { _, _ in Self.json(#"{"data":{"id":1}}"#) }
        do {
            _ = try await HTTPNodeExecutor.run(spec: endless, context: Self.httpContext(node), transport: wrongShape)
            Issue.record("expected a shape failure")
        } catch let error as WorkflowNodeError {
            guard case .toolFailed(_, let kind, let message, _) = error else { Issue.record("wrong error"); return }
            #expect(kind == "pagination_shape")
            #expect(message.contains("items_path"))
        }

        // The validator catches declarations the runner would refuse.
        var bad = endless
        bad.paginate = HTTPPagination(mode: .cursor, itemsPath: "data", maxPages: 500)
        bad.response = .text
        let issues = WorkflowValidator.validate(
            WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [WorkflowNode(id: "e", name: "E", kind: .http(bad))]),
            allowPlaceholders: false
        ).map(\.message)
        #expect(issues.contains { $0.contains("cursor_path") }, "\(issues)")
        #expect(issues.contains { $0.contains("max_pages") }, "\(issues)")
        #expect(issues.contains { $0.contains("JSON response") }, "\(issues)")

        // Round trip keeps only what differs from the defaults.
        let encoded = String(decoding: try JSONEncoder().encode(endless), as: UTF8.self)
        #expect(encoded.contains(#""max_pages":3"#) && !encoded.contains("cursor_param"), "\(encoded)")
        #expect(try JSONDecoder().decode(HTTPSpec.self, from: Data(encoded.utf8)) == endless)
        #expect(HTTPNodeExecutor.nextLink("<https://x/a?page=2>; rel=\"next\"") == "https://x/a?page=2")
        #expect(HTTPNodeExecutor.nextLink("<https://x/a?page=1>; rel=\"prev\"") == nil)
    }

    private actor Counter {
        var value = 0
        func next() -> Int {
            value += 1
            return value
        }
        func reset() { value = 0 }
    }

    @Test
    func http_refusesDisallowedHostsAndFailsOnStatus() async throws {
        let spec = HTTPSpec(url: "https://{{input.host}}/x", allowedHosts: ["ok.example.com"])
        let node = WorkflowNode(id: "call", name: "Call", kind: .http(spec))
        func context(host: String) -> WorkflowNodeContext {
            WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
                bindings: BindingContext(input: .object(["host": .string(host)]), outputs: [:]), model: nil,
                secretAccounts: [:], caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        }
        let never = HTTPNodeExecutor.Transport { _, _ in Issue.record("must not reach the network"); throw CancellationError() }
        await #expect(throws: WorkflowNodeError.self) {
            try await HTTPNodeExecutor.run(spec: spec, context: context(host: "evil.example.com"), transport: never)
        }
        let serverError = HTTPNodeExecutor.Transport { request, _ in
            (Data("nope".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await HTTPNodeExecutor.run(spec: spec, context: context(host: "ok.example.com"), transport: serverError)
            Issue.record("expected a failure")
        } catch let error as WorkflowNodeError {
            guard case .toolFailed(_, let kind, _, let retryable) = error else { Issue.record("wrong error"); return }
            #expect(kind == "http_503")
            #expect(retryable)
        }
        var lenient = spec
        lenient.failOnError = false
        lenient.response = .text
        let outcome = try await HTTPNodeExecutor.run(spec: lenient, context: context(host: "ok.example.com"), transport: serverError)
        #expect(outcome.output.value(atPath: "ok") == .bool(false))
        #expect(outcome.output.value(atPath: "body") == .string("nope"))
    }

    /// Private, link-local, and metadata addresses are refused even when
    /// the author lists them, on the first request and on a redirect hop;
    /// loopback stays reachable for services on this Mac.
    @Test
    func http_refusesPrivateAddresses_evenWhenListed_butKeepsLoopback() async throws {
        let hosts: Set<String> = [
            "169.254.169.254", "10.0.0.5", "192.168.1.1", "172.16.0.9", "100.64.0.1", "::ffff:10.0.0.1",
            "api.example.com", "localhost", "127.0.0.1", "::1",
        ]
        for blocked in ["https://169.254.169.254/latest/meta-data", "https://10.0.0.5/", "https://192.168.1.1/x", "https://172.16.0.9/", "https://100.64.0.1/", "https://[::ffff:10.0.0.1]/"] {
            let reason = HTTPNodeExecutor.isAllowed(URL(string: blocked)!, hosts: hosts)
            #expect(reason?.contains("private or link-local") == true, "\(blocked) → \(reason ?? "allowed")")
        }
        for allowed in ["https://api.example.com/x", "http://localhost:8080/x", "http://127.0.0.1:1337/v1", "http://[::1]:8080/"] {
            #expect(HTTPNodeExecutor.isAllowed(URL(string: allowed)!, hosts: hosts) == nil, "\(allowed)")
        }

        // The executor refuses before the transport runs.
        let spec = HTTPSpec(url: "https://10.0.0.5/admin", allowedHosts: ["10.0.0.5"])
        let node = WorkflowNode(id: "call", name: "Call", kind: .http(spec))
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil,
            secretAccounts: [:], caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let never = HTTPNodeExecutor.Transport { _, _ in Issue.record("must not reach the network"); throw CancellationError() }
        await #expect(throws: WorkflowNodeError.self) {
            try await HTTPNodeExecutor.run(spec: spec, context: context, transport: never)
        }

        // A redirect from an allowed public host onto a private one is refused by the guard.
        let redirectGuard = HTTPNodeExecutor.RedirectGuard(allowedHosts: ["api.example.com", "10.0.0.5"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.example.com/")!)
        let response = HTTPURLResponse(url: URL(string: "https://api.example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var decided: URLRequest?? = nil
        redirectGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://10.0.0.5/internal")!)
        ) { decided = .some($0) }
        #expect(decided == .some(nil))
        #expect(redirectGuard.refusedHost == "10.0.0.5")
    }

    @Test
    func http_validatorChecksMethodSchemeAndHosts() {
        func def(_ spec: HTTPSpec) -> WorkflowDefinition {
            WorkflowDefinition(
                inputSchema: WF.object(["h": WF.string]), outputSchema: WF.object([:]),
                nodes: [WorkflowNode(id: "c", name: "C", kind: .http(spec))])
        }
        #expect(WorkflowValidator.validate(def(HTTPSpec(method: "BREW", url: "https://a.example.com")), allowPlaceholders: false).contains { $0.message.contains("method") })
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "http://a.example.com")), allowPlaceholders: false).contains { $0.message.contains("https") })
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "http://localhost:8080/x")), allowPlaceholders: false).isEmpty)
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "https://{{input.h}}/x")), allowPlaceholders: false).contains { $0.message.contains("allowed_hosts") })
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "https://{{input.h}}/x", allowedHosts: ["a.example.com"])), allowPlaceholders: false).isEmpty)
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "https://10.0.0.5/x")), allowPlaceholders: false).contains { $0.message.contains("private") })
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "https://{{input.h}}/x", allowedHosts: ["169.254.169.254"])), allowPlaceholders: false).contains { $0.message.contains("private") })
        #expect(WorkflowValidator.validate(def(HTTPSpec(url: "http://127.0.0.1:1337/v1")), allowPlaceholders: false).isEmpty)
    }

    /// Credentials reach an http step only through `auth`, which reads a
    /// declared secret. A credential header or a pasted token in
    /// `headers` would put the value in the template and in run records,
    /// so the validator refuses both; ordinary and bound headers pass.
    @Test
    func http_validatorKeepsCredentialsOutOfHeaders() {
        func issues(_ headers: [String: String]) -> [String] {
            WorkflowValidator.validate(
                WorkflowDefinition(
                    inputSchema: WF.object(["token": WF.string]), outputSchema: WF.object([:]),
                    nodes: [
                        WorkflowNode(
                            id: "c", name: "C", kind: .http(HTTPSpec(url: "https://api.example.com/x", headers: headers)))
                    ]),
                allowPlaceholders: false
            ).map(\.message)
        }
        #expect(issues(["Authorization": "Bearer {{input.token}}"]).contains { $0.contains("use `auth`") })
        #expect(issues(["X-API-Key": "{{input.token}}"]).contains { $0.contains("use `auth`") })
        #expect(issues(["Cookie": "session=abc"]).contains { $0.contains("use `auth`") })
        #expect(issues(["X-Custom": "Bearer abc123def456"]).contains { $0.contains("pasted credential") })
        #expect(issues(["X-Custom": "sk-live-0123456789abcdef0123"]).contains { $0.contains("pasted credential") })
        #expect(issues(["X-Custom": "ghp_0123456789abcdef0123456789abcdef0123"]).contains { $0.contains("pasted credential") })
        #expect(issues(["Accept": "application/json", "X-Request-Id": "{{run.id}}", "User-Agent": "Osaurus/1.0"]).isEmpty)
        #expect(issues(["X-Tenant": "acme"]).isEmpty)
        #expect(!HTTPSpec.looksLikePastedCredential("Bearer {{input.token}}"))
        #expect(!HTTPSpec.looksLikePastedCredential("Bearer"))
    }

    @Test
    func http_dropsSessionCookiesFromTheRecordedResponse() async throws {
        let spec = HTTPSpec(url: "https://api.example.com/login", response: .text)
        let node = WorkflowNode(id: "call", name: "Call", kind: .http(spec))
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil,
            secretAccounts: [:], caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let transport = HTTPNodeExecutor.Transport { request, _ in
            (
                Data("ok".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Set-Cookie": "session=secret123; HttpOnly", "X-Request-Id": "r1", "Content-Type": "text/plain"])!
            )
        }
        let outcome = try await HTTPNodeExecutor.run(spec: spec, context: context, transport: transport)
        let headers = try #require(outcome.output.value(atPath: "headers")?.objectValue)
        #expect(headers["set-cookie"] == nil)
        #expect(headers["x-request-id"] == .string("r1"))
        #expect(!outcome.output.compactJSONString.contains("secret123"))
    }

    // MARK: - Format round trip

    @Test
    func newFields_roundTripThroughJSONAndStayOutWhenDefault() throws {
        var def = Self.mapDefinition()
        def.nodes[0].onError = .continue
        def.nodes[1].join = .all
        def.edges[0].on = .always
        def.nodes.append(WorkflowNode(id: "w", name: "W", kind: .wait(WaitSpec(until: "2026-03-01T09:00:00Z"))))
        def.nodes.append(WorkflowNode(id: "sub", name: "Sub", kind: .workflow(SubworkflowSpec(workflow: "Other"))))
        def.nodes.append(
            WorkflowNode(
                id: "h", name: "H",
                kind: .http(HTTPSpec(url: "https://a.example.com", auth: .basic(userSecret: "U", passwordSecret: "P"), response: .text, failOnError: false))))
        def.nodes.append(WorkflowNode(id: "p", name: "P", kind: .code(CodeSpec(language: .python, source: "def run(input, ctx): return {}"))))
        let data = try JSONEncoder().encode(def)
        let again = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
        #expect(again == def)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"on_error\":\"continue\""))
        #expect(text.contains("\"join\":\"all\""))
        #expect(text.contains("\"on\":\"always\""))
        #expect(text.contains("\"language\":\"python\""))
        // Defaults are omitted so older templates keep their hashes.
        let plain = try JSONEncoder().encode(WF.intake())
        let plainText = String(data: plain, encoding: .utf8) ?? ""
        #expect(!plainText.contains("on_error"))
        #expect(!plainText.contains("\"join\""))
        #expect(!plainText.contains("\"on\":"))
        #expect(!plainText.contains("language"))
    }

    @Test
    func draftOps_acceptNewKindsAndEdgeTriggers() throws {
        var draft = WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]))
        let ops = try [
            .object(["op": .string("plan_placeholder"), "id": .string("a"), "name": .string("A"), "intent": .string("Fetch")]),
            .object(["op": .string("plan_placeholder"), "id": .string("w"), "name": .string("W"), "intent": .string("Wait")]),
            .object(["op": .string("update_node"), "id": .string("a"), "node": .object(["kind": .string("code"), "code": .object(["source": .string("async function run() {}")])])]),
            .object(["op": .string("update_node"), "id": .string("w"), "node": .object(["kind": .string("wait"), "wait": .object(["seconds": .number(5)])])]),
            .object(["op": .string("add_edge"), "from": .string("a"), "to": .string("w"), "on": .string("error")]),
            .object(["op": .string("update_node"), "id": .string("a"), "node": .object(["kind": .string("http"), "http": .object(["url": .string("https://a.example.com")]), "on_error": .string("continue")])]),
        ].map(WorkflowDraftOp.parse)
        draft = try WorkflowDraftPatcher.apply(ops, to: draft).definition
        #expect(draft.nodes.count == 2)
        guard case .http? = draft.nodes[0].kind else { Issue.record("kind did not change to http"); return }
        #expect(draft.nodes[0].onError == .continue)
        guard case .wait(let wait)? = draft.nodes[1].kind else { Issue.record("no wait"); return }
        #expect(wait.seconds == "5")
        #expect(draft.edges.first?.on == .error)
        #expect(WorkflowValidator.validate(draft, allowPlaceholders: false).isEmpty)
        #expect(throws: (any Error).self) {
            try WorkflowDraftOp.parse(.object(["op": .string("add_edge"), "from": .string("a"), "to": .string("w"), "on": .string("sometimes")]))
        }
    }
}
