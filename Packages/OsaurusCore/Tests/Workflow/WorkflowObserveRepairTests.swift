//
//  WorkflowObserveRepairTests.swift
//  OsaurusCoreTests
//
//  The Architect's observe and repair loop: `workflow_runs` (scope, rows,
//  one run in full, failures grouped across runs), the re-test plan
//  `workflow_test` derives from a failed run, the repair brief, and the
//  self-heal decision and monitor.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowObserveRepairTests {

    // MARK: - Fixtures

    /// a -> b -> c, all code steps.
    private static func chain() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["q": WF.string]),
            outputSchema: WF.object([:]),
            nodes: [
                WF.code("a", input: .object(["q": "{{input.q}}"]), output: WF.object(["x": WF.string])),
                WF.code("b", input: .object(["x": "{{nodes.a.output.x}}"]), output: WF.object(["y": WF.string])),
                WF.code("c", input: .object(["y": "{{nodes.b.output.y}}"])),
            ],
            edges: [WorkflowEdge(from: "a", to: "b"), WorkflowEdge(from: "b", to: "c")],
            output: .object([:]))
    }

    /// A run of `chain()` that finished `a`, failed at `b`, and never ran `c`.
    private static func failedRun(
        workflowID: UUID, caller: WorkflowCaller = WorkflowCaller(kind: .user), reason: String = "boom",
        startedAt: Date = Date(timeIntervalSinceNow: -60), templateVersion: Int = 1
    ) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: workflowID, workflowName: "Chain", templateID: UUID(), templateVersion: templateVersion,
            caller: caller, input: .object(["q": .string("hello")]), nodeIDs: ["a", "b", "c"], startedAt: startedAt)
        run.update("a") {
            $0.status = .done
            $0.input = .object(["q": .string("hello")])
            $0.output = .object(["x": .string("from a")])
            $0.attempts = 1
            $0.startedAt = startedAt
            $0.finishedAt = startedAt.addingTimeInterval(1)
            $0.logs = ["a ran"]
        }
        run.update("b") {
            $0.status = .failed
            $0.input = .object(["x": .string("from a")])
            $0.error = reason
            $0.attempts = 2
            $0.startedAt = startedAt.addingTimeInterval(1)
            $0.finishedAt = startedAt.addingTimeInterval(3)
            $0.toolCallRecords = [
                WorkflowToolCallRecord(
                    name: "shell_run", arguments: #"{"command":"x"}"#, result: #"{"ok":false,"message":"nope"}"#,
                    durationMs: 12, isError: true)
            ]
        }
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "b", reason: reason, attempts: 2)
        run.finishedAt = startedAt.addingTimeInterval(3)
        return run
    }

    private static func completedRun(workflowID: UUID, startedAt: Date) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: workflowID, workflowName: "Chain", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: ["a", "b", "c"], startedAt: startedAt)
        for id in ["a", "b", "c"] { run.update(id) { $0.status = .done } }
        run.status = .completed
        run.finishedAt = startedAt.addingTimeInterval(2)
        return run
    }

    private func asArchitect<T>(session: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) { try await body() }
        }
    }

    private func result(_ envelope: String) throws -> [String: JSONValue] {
        let parsed = try #require(JSONValue.parse(envelope)?.objectValue, "\(envelope.prefix(300))")
        #expect(parsed["ok"]?.boolValue == true, "\(envelope.prefix(400))")
        return try #require(parsed["result"]?.objectValue)
    }

    // MARK: - workflow_runs

    @Test
    func runsTool_refusesOtherAgents() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "list"}"#)
        }
        #expect(result.contains("only available to the Architect"))
        #expect(ToolRegistry.architectToolNames.contains(WorkflowRunsTool.toolName))
    }

    @Test
    func runsTool_listsAndReadsTheDraftsOwnTests_butNotStrangers() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.chain() }
        let mine = Self.failedRun(workflowID: draft.id, caller: WorkflowCaller(kind: .test))
        let stranger = Self.failedRun(workflowID: UUID())
        WorkflowRunStore.shared.record(mine)
        WorkflowRunStore.shared.record(stranger)
        defer { WorkflowRunStore.shared.resetForTesting() }

        let listed = try result(
            await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "list", "workflow": "draft"}"#)
            })
        #expect(listed["workflow"]?.stringValue == "draft")
        let rows = try #require(listed["runs"]?.arrayValue)
        #expect(rows.count == 1)
        let row = try #require(rows.first?.objectValue)
        #expect(row["run_id"]?.stringValue == mine.id.uuidString)
        #expect(row["status"]?.stringValue == "failed")
        #expect(row["failed_step"]?.stringValue == "b")
        #expect(row["failed_step_name"]?.stringValue == "B")
        #expect(row["started_by"]?.stringValue == "test")
        #expect(row["error"]?.stringValue == "boom")

        let got = try result(
            await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(
                    argumentsJSON: #"{"action": "get", "run_id": "\#(mine.id.uuidString)"}"#)
            })
        let nodeValues = try #require(got["nodes"]?.arrayValue)
        let nodes = nodeValues.compactMap(\.objectValue)
        #expect(nodes.map { $0["id"]?.stringValue } == ["a", "b", "c"])
        let b = try #require(nodes.first { $0["id"]?.stringValue == "b" })
        #expect(b["kind"]?.stringValue == "code")
        #expect(b["attempts"]?.numberValue == 2)
        #expect(b["input"]?.objectValue?["x"]?.stringValue == "from a")
        let calls = try #require(b["tool_calls"]?.arrayValue?.first?.objectValue)
        #expect(calls["name"]?.stringValue == "shell_run")
        #expect(calls["is_error"]?.boolValue == true)
        #expect(calls["result"]?.stringValue?.contains("nope") == true)
        #expect(got["error"]?.objectValue?["node_id"]?.stringValue == "b")

        let one = try result(
            await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(
                    argumentsJSON: #"{"action": "get", "run_id": "\#(mine.id.uuidString)", "node": "a"}"#)
            })
        let a = try #require(one["node"]?.objectValue)
        #expect(a["logs"]?.arrayValue?.first?.stringValue == "a ran")
        #expect(a["output"]?.objectValue?["x"]?.stringValue == "from a")

        let denied = try await asArchitect(session: session) {
            try await WorkflowRunsTool().execute(
                argumentsJSON: #"{"action": "get", "run_id": "\#(stranger.id.uuidString)"}"#)
        }
        #expect(denied.contains("not_found"), "a run of nothing installed and not this draft's: \(denied.prefix(200))")

        let noDefault = try await asArchitect(session: session) {
            try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "get"}"#)
        }
        #expect(noDefault.contains("no run to fix"), "\(noDefault.prefix(200))")
    }

    @Test
    func runsTool_defaultsToTheRepairRun_andTheInstalledWorkflowItBelongsTo() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(Self.chain(), name: "Chain Repair"), bindings: InstallBindings())
            defer { store.delete(id: installed.id) }
            let run = Self.failedRun(workflowID: installed.id)
            WorkflowRunStore.shared.record(run)
            defer { WorkflowRunStore.shared.resetForTesting() }

            let session = "architect-\(UUID().uuidString)"
            let draft = WorkflowDraftStore.shared.create(sessionID: session, from: installed.template)
            defer { WorkflowDraftStore.shared.delete(draft.id) }
            WorkflowDraftStore.shared.setRepairRun(draft.id, runID: run.id)

            let got = try result(
                await asArchitect(session: session) {
                    try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "get"}"#)
                })
            #expect(got["run_id"]?.stringValue == run.id.uuidString)
            #expect(got["workflow"]?.stringValue == "Chain")

            let listed = try result(
                await asArchitect(session: session) {
                    try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "list"}"#)
                })
            #expect(listed["workflow"]?.stringValue == "Chain Repair", "the draft's saved workflow is the default scope")
            #expect(listed["runs"]?.arrayValue?.count == 1)

            let workflows = try result(
                await asArchitect(session: session) {
                    try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "workflows"}"#)
                })
            let rows = try #require(workflows["workflows"]?.arrayValue).compactMap(\.objectValue)
            let mine = try #require(rows.first { $0["name"]?.stringValue == "Chain Repair" })
            #expect(mine["last_7_days"]?.objectValue?["failed"]?.numberValue == 1)
            #expect(mine["last_run"]?.objectValue?["status"]?.stringValue == "failed")
            #expect(mine["self_heal"]?.boolValue == false)

            let unknown = try await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "list", "workflow": "Nope"}"#)
            }
            #expect(unknown.contains("No installed workflow named") && unknown.contains("Chain Repair"))
        }
    }

    @Test
    func failures_groupTheSameStepAndReasonAcrossRuns_ignoringVolatileParts() throws {
        let id = UUID()
        let monday = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
        let runs = [
            Self.failedRun(workflowID: id, reason: "Timed out after 120s fetching /tmp/\(UUID().uuidString)/x.pdf", startedAt: monday),
            Self.failedRun(workflowID: id, reason: "Timed out after 121s fetching /tmp/\(UUID().uuidString)/y.pdf", startedAt: monday.addingTimeInterval(86_400)),
            Self.failedRun(workflowID: id, reason: "Timed out after 119s fetching /tmp/\(UUID().uuidString)/z.pdf", startedAt: monday.addingTimeInterval(7 * 86_400)),
            Self.failedRun(workflowID: id, reason: "Permission denied", startedAt: monday.addingTimeInterval(2 * 86_400)),
            Self.completedRun(workflowID: id, startedAt: monday.addingTimeInterval(3 * 86_400)),
        ]
        let report = WorkflowRunsTool.failureReport(runs, definition: Self.chain())
        #expect(report["scanned"] as? Int == 5)
        #expect((report["totals"] as? [String: Int])?["failed"] == 4)
        let groups = try #require(report["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        let top = try #require(groups.first)
        #expect(top["step"] as? String == "b")
        #expect(top["step_name"] as? String == "B")
        #expect(top["count"] as? Int == 3)
        let weekdays = try #require(top["weekdays"] as? [String: Int])
        #expect(weekdays["Monday"] == 2, "\(weekdays)")
        #expect(weekdays["Tuesday"] == 1)
        #expect((groups.last?["count"] as? Int) == 1)
    }

    @Test
    func since_readsRelativeWindowsAndInstants() throws {
        let now = Date()
        let week = try #require(WorkflowRunsTool.since("7d", now: now))
        #expect(abs(week.timeIntervalSince(now.addingTimeInterval(-7 * 86_400))) < 1)
        let hours = try #require(WorkflowRunsTool.since("12h", now: now))
        #expect(abs(hours.timeIntervalSince(now.addingTimeInterval(-12 * 3_600))) < 1)
        #expect(WorkflowRunsTool.since("2026-10-01T00:00:00Z") != nil)
        #expect(WorkflowRunsTool.since("2026-10-01") != nil)
        #expect(WorkflowRunsTool.since("yesterday-ish") == nil)
        #expect(WorkflowRunsTool.since("") == nil)
    }

    // MARK: - Re-test from a run

    @Test
    func retestPlan_startsAtTheFailedStepWithFinishedOutputsPinned() {
        let def = Self.chain()
        let run = Self.failedRun(workflowID: UUID())
        let plan = WorkflowTestTool.retestPlan(from: run, definition: def)
        #expect(plan.startAt == "b")
        #expect(plan.input == .object(["q": .string("hello")]))
        #expect(plan.pinned == ["a": .object(["x": .string("from a")])])

        // The failed step is gone from the draft: start over with the input.
        var trimmed = def
        trimmed.nodes.removeAll { $0.id == "b" }
        trimmed.edges = [WorkflowEdge(from: "a", to: "c")]
        let fresh = WorkflowTestTool.retestPlan(from: run, definition: trimmed)
        #expect(fresh.startAt == nil && fresh.pinned.isEmpty && fresh.input == run.input)

        // An ancestor without an output to pin: start over too.
        var noOutput = run
        noOutput.update("a") { $0.output = nil }
        let unpinnable = WorkflowTestTool.retestPlan(from: noOutput, definition: def)
        #expect(unpinnable.startAt == nil && unpinnable.pinned.isEmpty)
    }

    @Test
    func repairBrief_namesTheStepAndTheRun() throws {
        let def = Self.chain()
        let run = Self.failedRun(workflowID: UUID(), reason: "boom\nsecond line")
        let message = WorkflowRepairBrief.message(run, definition: def)
        #expect(message.contains("“B”") && message.contains("boom") && !message.contains("second line"))
        let workflow = InstalledWorkflow(template: WF.template(def, name: "Chain"), bindings: InstallBindings())
        let note = WorkflowRepairBrief.note(run, workflow: workflow)
        #expect(note.contains(run.id.uuidString) && note.contains("`b`") && note.contains("from_run"))
        let unattended = WorkflowRepairBrief.unattendedPrompt(run, workflow: workflow, repeats: 3)
        #expect(unattended.contains("3 runs in a row") && unattended.contains("do not ask"))
    }

    @Test
    func failureFields_reachTheArchitect() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.chain() }
        let failure = NodeRunFailure(
            kind: "unavailable", retryable: false, errorType: "SubagentError.unavailable", fixIn: .settings,
            hint: "Turn on the swap.")
        var run = Self.failedRun(workflowID: draft.id, caller: WorkflowCaller(kind: .test))
        run.update("b") {
            $0.failure = failure
            $0.logs = (1 ... 30).map { "line \($0)" }
        }
        run.error?.failure = failure
        WorkflowRunStore.shared.record(run)
        defer { WorkflowRunStore.shared.resetForTesting() }

        let listed = try result(
            await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(argumentsJSON: #"{"action": "list", "workflow": "draft"}"#)
            })
        let row = try #require(listed["runs"]?.arrayValue?.first?.objectValue)
        #expect(row["error_kind"]?.stringValue == "unavailable")
        #expect(row["fix_in"]?.stringValue == "settings")

        let got = try result(
            await asArchitect(session: session) {
                try await WorkflowRunsTool().execute(
                    argumentsJSON: #"{"action": "get", "run_id": "\#(run.id.uuidString)", "node": "b"}"#)
            })
        let b = try #require(got["node"]?.objectValue)
        #expect(b["failure"]?.objectValue?["fix_in"]?.stringValue == "settings")
        #expect(b["failure"]?.objectValue?["hint"]?.stringValue == "Turn on the swap.")
        #expect(b["failure"]?.objectValue?["error_type"]?.stringValue == "SubagentError.unavailable")
        #expect(b["logs"]?.arrayValue?.count == 30, "a failed step keeps every log line")
        #expect(b["step"]?.objectValue?["id"]?.stringValue == "b", "the failed step's definition rides along")

        let report = WorkflowRunsTool.failureReport([run], definition: Self.chain())
        let group = try #require((report["groups"] as? [[String: Any]])?.first)
        #expect((group["failure"] as? [String: Any])?["fix_in"] as? String == "settings")

        let workflow = InstalledWorkflow(template: WF.template(Self.chain(), name: "Chain"), bindings: InstallBindings())
        let note = WorkflowRepairBrief.note(run, workflow: workflow)
        #expect(note.contains("`unavailable`") && note.contains("an app setting") && note.contains("Turn on the swap."))
        #expect(note.contains("Do not change the workflow to hide it"))
        let unattended = WorkflowRepairBrief.unattendedPrompt(run, workflow: workflow, repeats: 3)
        #expect(unattended.contains("rather than editing the workflow"))
        let line = WorkflowDraftTester.outcomeLine(run)
        #expect(line.contains("not retryable") && line.contains("an app setting"))
    }

    @Test
    func draft_keepsItsRepairRunAcrossEncoding() throws {
        var draft = WorkflowDraft(sessionID: "s")
        let runID = UUID()
        draft.repairRunID = runID
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(WorkflowDraft.self, from: data)
        #expect(decoded.repairRunID == runID)
        let legacy = try JSONDecoder().decode(WorkflowDraft.self, from: #"{"id": "\#(UUID().uuidString)"}"#.data(using: .utf8)!)
        #expect(legacy.repairRunID == nil)
    }

    // MARK: - Self-heal

    @Test
    func installedWorkflow_decodesWithoutSelfHealAsOff() throws {
        let installed = InstalledWorkflow(template: WF.template(Self.chain()), bindings: InstallBindings())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(installed)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["self_heal"] as? Bool == false)
        object["self_heal"] = nil
        object["self_healed_signature"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InstalledWorkflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.selfHeal == false && decoded.selfHealedSignature == nil)
        #expect(decoded.id == installed.id && decoded.orchestratorVisible)
    }

    @Test
    func selfHealDecision_firesOnTheThresholdIdenticalFailure_once() {
        let id = UUID()
        let base = Date(timeIntervalSinceNow: -3_600)
        func failed(_ offset: TimeInterval, reason: String = "boom 12345", caller: WorkflowCaller = WorkflowCaller(kind: .user)) -> WorkflowRun {
            Self.failedRun(workflowID: id, caller: caller, reason: reason, startedAt: base.addingTimeInterval(offset))
        }
        let third = failed(30)
        let streak = [third, failed(20), failed(10)]
        let decision = WorkflowSelfHealMonitor.decide(latest: third, history: streak, alreadyDrafted: nil)
        #expect(decision?.repeats == 3)
        #expect(decision?.signature == "b: boom …", "\(decision?.signature ?? "")")

        // Two is not enough; a success in between breaks the streak; a different reason too.
        #expect(WorkflowSelfHealMonitor.decide(latest: third, history: [third, failed(20)], alreadyDrafted: nil) == nil)
        #expect(
            WorkflowSelfHealMonitor.decide(
                latest: third, history: [third, Self.completedRun(workflowID: id, startedAt: base.addingTimeInterval(25)), failed(20), failed(10)],
                alreadyDrafted: nil) == nil)
        #expect(
            WorkflowSelfHealMonitor.decide(
                latest: third, history: [third, failed(20, reason: "other"), failed(10)], alreadyDrafted: nil) == nil)
        // Volatile numbers do not split the streak.
        #expect(
            WorkflowSelfHealMonitor.decide(
                latest: third, history: [third, failed(20, reason: "boom 45678"), failed(10, reason: "boom 7890")], alreadyDrafted: nil)?.repeats == 3)
        // Test runs do not count; runs after `latest` do not count.
        #expect(
            WorkflowSelfHealMonitor.decide(
                latest: third, history: [failed(40), third, failed(20, caller: WorkflowCaller(kind: .test)), failed(15), failed(10)],
                alreadyDrafted: nil)?.repeats == 3)
        // Already drafted for this failure: stay quiet.
        #expect(WorkflowSelfHealMonitor.decide(latest: third, history: streak, alreadyDrafted: "b: boom …") == nil)
    }

    @Test
    func selfHealMonitor_dispatchesTheArchitectOnceForAnOptedInWorkflow() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(Self.chain(), name: "Heal Me"), bindings: InstallBindings())
            defer { store.delete(id: installed.id) }
            defer { WorkflowRunStore.shared.resetForTesting() }

            let monitor = WorkflowSelfHealMonitor()
            actor Recorder {
                var calls: [(String, UUID, Int)] = []
                func add(_ name: String, _ run: UUID, _ repeats: Int) { calls.append((name, run, repeats)) }
            }
            let recorder = Recorder()
            monitor.dispatch = { workflow, run, repeats in
                await recorder.add(workflow.name, run.id, repeats)
                return true
            }
            let base = Date(timeIntervalSinceNow: -600)
            @MainActor func fail(_ offset: TimeInterval) -> WorkflowRun {
                let run = Self.failedRun(workflowID: installed.id, startedAt: base.addingTimeInterval(offset))
                WorkflowRunStore.shared.record(run)
                return run
            }

            // Off by default: three failures change nothing.
            for offset in [10.0, 20, 30] { monitor.inspect([fail(offset)]) }
            await Task.yield()
            #expect(await recorder.calls.isEmpty)

            try store.setSelfHeal(true, id: installed.id)
            #expect(store.workflow(id: installed.id)?.selfHeal == true)
            let fourth = fail(40)
            monitor.inspect([fourth])
            for _ in 0..<50 {
                if await !recorder.calls.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let calls = await recorder.calls
            #expect(calls.count == 1)
            #expect(calls.first?.0 == "Heal Me")
            #expect(calls.first?.1 == fourth.id)
            #expect(calls.first?.2 == 4)
            #expect(store.workflow(id: installed.id)?.selfHealedSignature == "b: boom")

            // The same failure again: already drafted, no second chat.
            monitor.inspect([fail(50)])
            try await Task.sleep(for: .milliseconds(30))
            #expect(await recorder.calls.count == 1)

            // Turning it off and on forgets the drafted signature.
            try store.setSelfHeal(false, id: installed.id)
            try store.setSelfHeal(true, id: installed.id)
            #expect(store.workflow(id: installed.id)?.selfHealedSignature == nil)
        }
    }

    @Test
    func selfHealSeed_becomesTheBackgroundChatsDraft() {
        let drafts = WorkflowDraftStore.shared
        let template = WF.template(Self.chain(), name: "Seeded")
        let runID = UUID()
        let key = WorkflowSelfHealMonitor.sessionKeyPrefix + runID.uuidString
        drafts.registerSeed(.init(template: template, repairRunID: runID), key: key)
        let session = UUID().uuidString
        let draft = drafts.claimSeed(key: key, sessionID: session)
        defer { draft.map { drafts.delete($0.id) } }
        #expect(draft?.name == "Seeded")
        #expect(draft?.repairRunID == runID)
        #expect(draft?.templateID == template.id)
        #expect(drafts.draft(forSession: session)?.id == draft?.id)
        #expect(drafts.claimSeed(key: key, sessionID: session) == nil, "a seed is claimed once")
    }
}
