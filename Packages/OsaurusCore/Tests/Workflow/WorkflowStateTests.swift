//
//  WorkflowStateTests.swift
//  osaurusTests
//
//  Workflow-scoped stored data: the store, the `state` step through the
//  live executor and runner, its validation, and how it shows up.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workflow stored data")
struct WorkflowStateTests {
    private static func store() -> WorkflowStateStore {
        WorkflowStateStore(directory: WF.tempDir().appendingPathComponent("state"))
    }

    private static func request(_ def: WorkflowDefinition, workflowID: UUID, input: JSONValue = .object([:]))
        -> WorkflowRunner.Request
    {
        let template = WF.template(def)
        return WorkflowRunner.Request(
            workflowID: workflowID,
            workflowName: template.name,
            template: template,
            caller: WorkflowCaller(kind: .user),
            input: input,
            workspace: WF.tempDir()
        )
    }

    // MARK: - Store

    @Test
    func store_setGetIncrementDeleteListClear() throws {
        let store = Self.store()
        let wf = UUID()
        #expect(try store.get(workflow: wf, table: "vars", key: "a") == nil)
        try store.set(workflow: wf, table: "vars", key: "a", value: .string("one"))
        #expect(try store.get(workflow: wf, table: "vars", key: "a")?.value == .string("one"))

        #expect(try store.increment(workflow: wf, table: "counts", key: "runs", by: 1) == 1)
        #expect(try store.increment(workflow: wf, table: "counts", key: "runs", by: 2.5) == 3.5)
        #expect(throws: WorkflowStateError.notANumber(key: "a")) {
            try store.increment(workflow: wf, table: "vars", key: "a", by: 1)
        }

        try store.set(
            workflow: wf,
            table: "vars",
            key: "b",
            value: .object(["n": .number(2)]),
            now: Date().addingTimeInterval(10)
        )
        let rows = try store.list(workflow: wf, table: "vars", limit: 10)
        #expect(rows.map(\.key) == ["b", "a"], "newest first")
        #expect(try store.list(workflow: wf, table: "vars", limit: 1).count == 1)
        #expect(store.tables(workflow: wf).map(\.name) == ["counts", "vars"])
        #expect(store.tables(workflow: wf).first { $0.name == "vars" }?.count == 2)

        #expect(try store.delete(workflow: wf, table: "vars", key: "a") == true)
        #expect(try store.delete(workflow: wf, table: "vars", key: "a") == false)
        #expect(try store.clear(workflow: wf, table: "vars") == 1)
        #expect(try store.clear(workflow: wf, table: "vars") == 0)
        #expect(store.tables(workflow: wf).map(\.name) == ["counts"])
    }

    @Test
    func store_persistsPerWorkflowAndForgetsOnDeleteAll() throws {
        let dir = WF.tempDir().appendingPathComponent("state")
        let a = UUID()
        let b = UUID()
        do {
            let store = WorkflowStateStore(directory: dir)
            try store.set(workflow: a, table: "vars", key: "k", value: .number(1))
            try store.set(workflow: b, table: "vars", key: "k", value: .number(2))
        }
        let reopened = WorkflowStateStore(directory: dir)
        #expect(try reopened.get(workflow: a, table: "vars", key: "k")?.value == .number(1))
        #expect(try reopened.get(workflow: b, table: "vars", key: "k")?.value == .number(2))
        reopened.deleteAll(workflow: a)
        #expect(try reopened.get(workflow: a, table: "vars", key: "k") == nil)
        #expect(try reopened.get(workflow: b, table: "vars", key: "k")?.value == .number(2))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(a.uuidString).json").path))
    }

    @Test
    func store_enforcesLimitsAndNames() throws {
        let store = Self.store()
        let wf = UUID()
        let big = String(repeating: "x", count: WorkflowStateStore.maximumValueBytes + 1)
        #expect(throws: WorkflowStateError.self) {
            try store.set(workflow: wf, table: "vars", key: "k", value: .string(big))
        }
        #expect(throws: WorkflowStateError.badName("")) {
            try store.set(workflow: wf, table: "", key: "k", value: .null)
        }
        #expect(throws: WorkflowStateError.badName("a\nb")) {
            try store.get(workflow: wf, table: "vars", key: "a\nb")
        }
    }

    // MARK: - Step

    /// A dedupe workflow: look the item up, store it only when unseen, and
    /// report whether it was new. The second run with the same item on the
    /// same workflow sees it.
    private static func dedupeDefinition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["item": WF.string], required: ["item"]),
            outputSchema: WF.object(["seen_before": WF.bool, "stored": WF.number]),
            nodes: [
                WorkflowNode(
                    id: "lookup",
                    name: "Lookup",
                    kind: .state(StateSpec(action: .get, table: "seen", key: "{{input.item}}"))
                ),
                WorkflowNode(
                    id: "remember",
                    name: "Remember",
                    kind: .state(StateSpec(action: .set, table: "seen", key: "{{input.item}}", value: "{{run.id}}"))
                ),
                WorkflowNode(
                    id: "count",
                    name: "Count",
                    kind: .state(StateSpec(action: .increment, table: "vars", key: "handled"))
                ),
                WorkflowNode(id: "tally", name: "Tally", kind: .state(StateSpec(action: .list, table: "seen"))),
            ],
            edges: [
                WorkflowEdge(from: "lookup", to: "remember", when: WorkflowCondition(path: "exists", op: .isFalse)),
                WorkflowEdge(from: "remember", to: "count"),
                WorkflowEdge(from: "lookup", to: "tally", on: .always),
                WorkflowEdge(from: "count", to: "tally", on: .always),
            ],
            output: .object(["seen_before": "{{nodes.lookup.output.exists}}", "stored": "{{nodes.tally.output.count}}"])
        )
    }

    @Test
    func stateStep_dedupesAcrossRunsOfTheSameWorkflow() async throws {
        let def = Self.dedupeDefinition()
        #expect(
            WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty,
            "\(WorkflowValidator.validate(def, allowPlaceholders: false))"
        )
        let workflowID = UUID()
        defer { WorkflowStateStore.shared.deleteAll(workflow: workflowID) }

        let first = await WorkflowRunner(
            request: Self.request(def, workflowID: workflowID, input: .object(["item": .string("invoice-1")])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(first.status == .completed, "\(String(describing: first.error))")
        #expect(first.output?.value(atPath: "seen_before") == .bool(false))
        #expect(first.output?.value(atPath: "stored") == .number(1))
        #expect(first.node("remember")?.output?.value(atPath: "value") == .string(first.id.uuidString))
        #expect(first.node("count")?.output?.value(atPath: "value") == .number(1))

        let second = await WorkflowRunner(
            request: Self.request(def, workflowID: workflowID, input: .object(["item": .string("invoice-1")])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(second.status == .completed, "\(String(describing: second.error))")
        #expect(second.output?.value(atPath: "seen_before") == .bool(true))
        #expect(second.node("remember")?.status == .skipped)
        #expect(second.node("count")?.status == .skipped)
        #expect(second.output?.value(atPath: "stored") == .number(1))

        let other = await WorkflowRunner(
            request: Self.request(def, workflowID: workflowID, input: .object(["item": .string("invoice-2")])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(other.output?.value(atPath: "seen_before") == .bool(false))
        #expect(other.output?.value(atPath: "stored") == .number(2))
        #expect(
            try WorkflowStateStore.shared.get(workflow: workflowID, table: "vars", key: "handled")?.value == .number(2)
        )

        // A different workflow (a draft, say) has its own store.
        let draft = await WorkflowRunner(
            request: Self.request(def, workflowID: UUID(), input: .object(["item": .string("invoice-1")])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(draft.output?.value(atPath: "seen_before") == .bool(false))
    }

    @Test
    func stateStep_setKeepsBoundTypesAndParsesLiterals() async throws {
        let workflowID = UUID()
        defer { WorkflowStateStore.shared.deleteAll(workflow: workflowID) }
        let def = WorkflowDefinition(
            inputSchema: WF.object(["n": WF.number, "tags": .object(["type": .string("array")])]),
            outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(id: "a", name: "A", kind: .state(StateSpec(action: .set, key: "n", value: "{{input.n}}"))),
                WorkflowNode(
                    id: "b",
                    name: "B",
                    kind: .state(StateSpec(action: .set, key: "tags", value: "{{input.tags}}"))
                ),
                WorkflowNode(
                    id: "c",
                    name: "C",
                    kind: .state(StateSpec(action: .set, key: "text", value: "hello {{input.n}}"))
                ),
                WorkflowNode(
                    id: "d",
                    name: "D",
                    kind: .state(StateSpec(action: .set, key: "obj", value: "{\"x\": 1}"))
                ),
                WorkflowNode(id: "d2", name: "D2", kind: .state(StateSpec(action: .set, key: "num", value: "42"))),
                WorkflowNode(id: "e", name: "E", kind: .state(StateSpec(action: .delete, key: "text"))),
                WorkflowNode(id: "f", name: "F", kind: .state(StateSpec(action: .clear, table: "vars"))),
            ],
            edges: [
                WorkflowEdge(from: "a", to: "b"), WorkflowEdge(from: "b", to: "c"), WorkflowEdge(from: "c", to: "d"),
                WorkflowEdge(from: "d", to: "d2"), WorkflowEdge(from: "d2", to: "e"), WorkflowEdge(from: "e", to: "f"),
            ],
            output: .object([:])
        )
        let run = await WorkflowRunner(
            request: Self.request(
                def,
                workflowID: workflowID,
                input: .object(["n": .number(7), "tags": .array([.string("x")])])
            ),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(run.node("a")?.output?.value(atPath: "value") == .number(7))
        #expect(run.node("b")?.output?.value(atPath: "value") == .array([.string("x")]))
        #expect(run.node("c")?.output?.value(atPath: "value") == .string("hello 7"))
        #expect(run.node("d")?.output?.value(atPath: "value") == .object(["x": .number(1)]))
        #expect(run.node("d2")?.output?.value(atPath: "value") == .number(42))
        #expect(run.node("e")?.output?.value(atPath: "deleted") == .bool(true))
        #expect(run.node("f")?.output?.value(atPath: "count") == .number(4))
        #expect(WorkflowStateStore.shared.tables(workflow: workflowID).isEmpty)
    }

    @Test
    func stateStep_failsClearlyOnMissingKeyOrBadIncrement() async throws {
        let workflowID = UUID()
        defer { WorkflowStateStore.shared.deleteAll(workflow: workflowID) }
        try WorkflowStateStore.shared.set(workflow: workflowID, table: "vars", key: "name", value: .string("Ada"))
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            outputSchema: WF.object([:]),
            nodes: [WorkflowNode(id: "inc", name: "Inc", kind: .state(StateSpec(action: .increment, key: "name")))],
            output: .object([:])
        )
        let run = await WorkflowRunner(
            request: Self.request(def, workflowID: workflowID),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("not a number") == true, "\(String(describing: run.error))")

        let empty = WorkflowDefinition(
            inputSchema: WF.object(["k": WF.string]),
            outputSchema: WF.object([:]),
            nodes: [WorkflowNode(id: "get", name: "Get", kind: .state(StateSpec(action: .get, key: "{{input.k}}")))],
            output: .object([:])
        )
        let missing = await WorkflowRunner(
            request: Self.request(empty, workflowID: workflowID, input: .object(["k": .string("")])),
            executor: LiveWorkflowNodeExecutor()
        ).execute()
        #expect(missing.status == .failed)
        #expect(missing.error?.reason.contains("needs a key") == true, "\(String(describing: missing.error))")
    }

    // MARK: - Model

    @Test
    func stateSpec_validation() {
        func issues(_ spec: StateSpec) -> [String] {
            let def = WorkflowDefinition(
                inputSchema: WF.object([:]),
                outputSchema: WF.object([:]),
                nodes: [WorkflowNode(id: "s", name: "S", kind: .state(spec))]
            )
            return WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
        }
        #expect(issues(StateSpec(action: .get, key: "k")).isEmpty)
        #expect(issues(StateSpec(action: .get)).contains { $0.contains("needs a `key`") })
        #expect(issues(StateSpec(action: .list, key: "k")).contains { $0.contains("drop `key`") })
        #expect(issues(StateSpec(action: .set, key: "k")).contains { $0.contains("needs a `value`") })
        #expect(
            issues(StateSpec(action: .get, key: "k", value: "x")).contains { $0.contains("does not take a `value`") }
        )
        #expect(issues(StateSpec(action: .increment, key: "k", by: "two")).contains { $0.contains("must be a number") })
        #expect(issues(StateSpec(action: .increment, key: "k", by: "{{input.n}}")).isEmpty)
        #expect(issues(StateSpec(action: .get, key: "k", by: "1")).contains { $0.contains("`increment` only") })
        #expect(issues(StateSpec(action: .list, limit: 5000)).contains { $0.contains("between 1 and 1000") })
        #expect(issues(StateSpec(action: .get, key: "k", limit: 5)).contains { $0.contains("`list` only") })
        #expect(issues(StateSpec(action: .get, table: "", key: "k")).contains { $0.contains("`table` must be") })
        #expect(issues(StateSpec(action: .get, key: "{{nodes.nope.output.x}}")).contains { $0.contains("nope") })
    }

    @Test
    func stateSpec_codableRoundTripAndOutputSchema() throws {
        let node = WorkflowNode(
            id: "s",
            name: "S",
            kind: .state(StateSpec(action: .set, table: "t", key: "k", value: "{{input.v}}", by: nil, limit: nil))
        )
        let data = try JSONEncoder().encode(node)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "state")
        #expect((json["state"] as? [String: Any])?["action"] as? String == "set")
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: data)
        #expect(decoded == node)
        #expect(decoded.kindName == "state")
        #expect(WorkflowNode.kindNames.contains("state"))

        // The Architect may write `value` as raw JSON and `by` as a number.
        let loose = """
            {"id": "s", "name": "S", "kind": "state", "state": {"action": "increment", "key": "n", "by": 2, "value": {"a": 1}}}
            """
        let spec = try JSONDecoder().decode(WorkflowNode.self, from: Data(loose.utf8))
        guard case .state(let s)? = spec.kind else { Issue.record("not a state node"); return }
        #expect(s.by == "2")
        #expect(s.value == "{\"a\":1}")

        let get = WorkflowNode(id: "g", name: "G", kind: .state(StateSpec(action: .get, key: "k")))
        #expect(get.effectiveOutputSchema.value(atPath: "properties.exists.type") == .string("boolean"))
        let list = WorkflowNode(id: "l", name: "L", kind: .state(StateSpec(action: .list)))
        #expect(list.effectiveOutputSchema.value(atPath: "properties.rows.type") == .string("array"))
    }

    @Test
    func stateStep_surfaces() {
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(id: "g", name: "G", kind: .state(StateSpec(action: .get, table: "seen", key: "k"))),
                WorkflowNode(id: "s", name: "S", kind: .state(StateSpec(action: .increment, key: "n"))),
            ]
        )
        let get = def.nodes[0]
        let inc = def.nodes[1]
        #expect(WorkflowSummary.kind(get) == "Reads “k” in seen")
        #expect(WorkflowSummary.kind(inc) == "Counts up “n”")
        #expect(WorkflowSummary.icon(get) == "tray.full")
        #expect(WorkflowDiscoverTool.kindName(.state(StateSpec(action: .get))) == "state")
        let badges = WorkflowStepRisk.badges(for: inc, in: def, locality: { _ in .local })
        #expect(badges.contains { $0.kind == .storesData && $0.label == "Stores data" })
        #expect(
            WorkflowStepRisk.badges(for: get, in: def, locality: { _ in .local }).contains {
                $0.label == "Reads stored data"
            }
        )
        #expect(WorkflowRequirementsDeriver.derive(def).tools.isEmpty)
    }
}

@Suite("Workflow tags")
struct WorkflowTagTests {
    @Test
    func tags_normalizeAndParse() {
        #expect(
            InstalledWorkflow.normalizedTags([" Finance", "finance ", "Weekly", "", "   "]) == ["finance", "weekly"]
        )
        #expect(InstalledWorkflow.parseTags("finance, Weekly; reports\nfinance") == ["finance", "weekly", "reports"])
        let many = (0 ..< 20).map { "t\($0)" }
        #expect(InstalledWorkflow.normalizedTags(many).count == InstalledWorkflow.maximumTags)
        let long = String(repeating: "a", count: 100)
        #expect(InstalledWorkflow.normalizedTags([long]).first?.count == InstalledWorkflow.maximumTagLength)
    }

    @Test
    func tags_filterByQueryAndTag() {
        let a = InstalledWorkflow(
            template: WF.template(WF.intake(), name: "Invoice Sweep"),
            bindings: InstallBindings(),
            tags: ["finance", "weekly"]
        )
        let b = InstalledWorkflow(
            template: WF.template(WF.intake(), name: "Release Notes"),
            bindings: InstallBindings(),
            tags: ["eng"]
        )
        let c = InstalledWorkflow(
            template: WF.template(WF.intake(), name: "Expense Report"),
            bindings: InstallBindings(),
            tags: ["finance"]
        )
        let all = [a, b, c]
        #expect(
            InstalledWorkflow.filter(all, query: "", tag: nil).map(\.name) == [
                "Invoice Sweep", "Release Notes", "Expense Report",
            ]
        )
        #expect(
            InstalledWorkflow.filter(all, query: "", tag: "finance").map(\.name) == ["Invoice Sweep", "Expense Report"]
        )
        #expect(
            InstalledWorkflow.filter(all, query: "weekly", tag: nil).map(\.name) == ["Invoice Sweep"],
            "a tag is searchable"
        )
        #expect(InstalledWorkflow.filter(all, query: "release", tag: nil).map(\.name) == ["Release Notes"])
        #expect(InstalledWorkflow.filter(all, query: "release", tag: "finance").isEmpty)
        #expect(a.searchText == "Invoice Sweep finance weekly")
    }

    @MainActor
    @Test
    func tags_persistOnTheInstalledWorkflowAndStayOutOfTheTemplate() throws {
        let template = try TemplateStore.shared.save(
            WF.template(WF.intake(), name: "Tagged \(UUID().uuidString.prefix(6))")
        )
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        #expect(installed.tags.isEmpty)

        try InstalledWorkflowStore.shared.setTags(["Finance", "weekly", "finance"], id: installed.id)
        let saved = try #require(InstalledWorkflowStore.shared.workflow(id: installed.id))
        #expect(saved.tags == ["finance", "weekly"])
        #expect(InstalledWorkflowStore.shared.allTags.contains { $0.tag == "finance" && $0.count >= 1 })

        let data = try JSONEncoder().encode(saved)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["tags"] as? [String] == ["finance", "weekly"])
        #expect((json["template"] as? [String: Any])?["tags"] == nil, "tags are not part of the template")
        let decoded = try JSONDecoder().decode(InstalledWorkflow.self, from: data)
        #expect(decoded.tags == ["finance", "weekly"])

        // An older file without `tags` decodes to none.
        var legacy = json
        legacy["tags"] = nil
        let old = try JSONDecoder().decode(InstalledWorkflow.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.tags.isEmpty)

        // Tags stay through a template update and clear with uninstall.
        var v2 = template
        v2.version += 1
        let updated = try InstalledWorkflowStore.shared.install(v2, bindings: InstallBindings())
        #expect(updated.tags == ["finance", "weekly"])
        #expect(InstalledWorkflowStore.shared.workflow(id: installed.id)?.templateVersion == v2.version)

        let rows = WorkflowDiscoverTool.templates(query: "weekly", limit: 10)
        #expect(
            rows.contains {
                ($0["name"] as? String) == template.name && ($0["tags"] as? [String]) == ["finance", "weekly"]
            }
        )
    }
}
