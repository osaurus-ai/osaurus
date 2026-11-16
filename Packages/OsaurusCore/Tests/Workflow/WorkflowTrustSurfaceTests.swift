//
//  WorkflowTrustSurfaceTests.swift
//  OsaurusCoreTests
//
//  The trust surface that stands in for an editable canvas: per-step risk
//  and cost badges, plain-language change summaries on each Architect
//  patch, test evidence that gates a save, and grounded run explanations.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowTrustSurfaceTests {

    // MARK: - Fixtures

    private static func chain() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["q": WF.string]),
            outputSchema: WF.object([:]),
            nodes: [
                WF.code("a", input: .object(["q": "{{input.q}}"]), output: WF.object(["x": WF.string])),
                WF.code("b", input: .object(["x": "{{nodes.a.output.x}}"]), output: WF.object(["y": WF.string])),
            ],
            edges: [WorkflowEdge(from: "a", to: "b")],
            output: .object([:]))
    }

    private static func run(
        workflowID: UUID, status: WorkflowRunStatus, caller: WorkflowCaller.Kind = .test,
        input: JSONValue = .object(["q": .string("hello")]), startedAt: Date = Date(),
        output: JSONValue? = nil
    ) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: workflowID, workflowName: "Chain", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: caller, agentName: caller == .agent ? "Helper" : nil), input: input,
            nodeIDs: ["a", "b"], startedAt: startedAt)
        run.update("a") {
            $0.status = .done
            $0.input = input
            $0.output = .object(["x": .string("from a")])
            $0.attempts = 1
            $0.startedAt = startedAt
            $0.finishedAt = startedAt.addingTimeInterval(1)
            $0.inputTokens = 300
            $0.outputTokens = 100
            $0.toolCalls = ["web_fetch"]
        }
        switch status {
        case .completed:
            run.update("b") {
                $0.status = .done
                $0.output = .object(["y": .string("done")])
                $0.attempts = 1
                $0.startedAt = startedAt.addingTimeInterval(1)
                $0.finishedAt = startedAt.addingTimeInterval(2)
            }
            run.output = output ?? .object(["answer": .string("42")])
        case .failed:
            run.update("b") {
                $0.status = .failed
                $0.error = "boom"
                $0.attempts = 2
                $0.startedAt = startedAt.addingTimeInterval(1)
                $0.finishedAt = startedAt.addingTimeInterval(3)
                $0.toolCallRecords = [
                    WorkflowToolCallRecord(
                        name: "shell_run", arguments: #"{"command":"x"}"#, result: #"{"ok":false,"message":"nope"}"#,
                        durationMs: 12, isError: true)
                ]
            }
            run.error = WorkflowRunError(nodeID: "b", reason: "boom", attempts: 2)
        default:
            break
        }
        run.status = status
        if status.isTerminal { run.finishedAt = startedAt.addingTimeInterval(3) }
        return run
    }

    private func asArchitect<T>(session: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) { try await body() }
        }
    }

    private func envelope(_ text: String) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(text)?.objectValue, "\(text.prefix(300))")
    }

    private static let localOnly: (String) -> WorkflowModelLocality = { _ in .local }

    // MARK: - Badges

    @Test
    func badges_httpStep_namesHostsAndSecrets() {
        let node = WorkflowNode(
            id: "fetch", name: "Fetch",
            kind: .http(
                HTTPSpec(
                    url: "https://api.example.com/v1/things", auth: .bearer(secret: "EXAMPLE_TOKEN"),
                    allowedHosts: ["cdn.example.com"])))
        let badges = WorkflowStepRisk.badges(for: node, in: WorkflowDefinition(), locality: Self.localOnly)
        let network = badges.first { $0.kind == .network }
        #expect(network?.label == "Reaches api.example.com +1")
        #expect(network?.detail == "api.example.com, cdn.example.com")
        #expect(network?.tone == .caution)
        #expect(badges.first { $0.kind == .secrets }?.label == "Uses secret EXAMPLE_TOKEN")
        #expect(!badges.contains { $0.kind == .cost })
    }

    @Test
    func badges_pythonCode_flagsSandboxAndNetwork() {
        let node = WorkflowNode(
            id: "crunch", name: "Crunch",
            kind: .code(CodeSpec(language: .python, source: "print(1)", network: ["Pypi.org"], secrets: ["A", "B"])))
        let badges = WorkflowStepRisk.badges(for: node, in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(badges.contains { $0.kind == .shell && $0.label == "Runs Python in the sandbox" && $0.tone == .caution })
        #expect(badges.contains { $0.kind == .network && $0.label == "Reaches pypi.org" })
        #expect(badges.contains { $0.kind == .secrets && $0.label == "Uses 2 secrets" && $0.detail == "A, B" })
    }

    @Test
    func badges_toolSteps_shellBrowserFilesAndMCP() {
        func tool(_ name: String, server: String? = nil) -> WorkflowNode {
            WorkflowNode(id: name, name: name, kind: .tool(ToolNodeSpec(tool: ToolRef(name: name, server: server))))
        }
        let shell = WorkflowStepRisk.badges(for: tool("shell_run"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(shell.map(\.kind) == [.shell])
        #expect(shell.first?.label == "Sandbox · Runs commands")
        #expect(shell.first?.tone == .caution)
        let script = WorkflowStepRisk.badges(for: tool("applescript"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(script.map(\.kind) == [.yourMac, .shell])
        #expect(script.last?.label == "Runs commands on your Mac" && script.last?.tone == .risky)
        let browser = WorkflowStepRisk.badges(for: tool("browser_use"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(browser.first?.kind == .browser && browser.first?.tone == .risky)
        let files = WorkflowStepRisk.badges(for: tool("file_write"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(files.first?.kind == .files && files.first?.label == "Writes files" && files.first?.tone == .caution)
        let mcp = WorkflowStepRisk.badges(for: tool("list_issues", server: "github"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(mcp.first?.kind == .network && mcp.first?.label == "Uses github (MCP)")
        let read = WorkflowStepRisk.badges(for: tool("file_read"), in: WorkflowDefinition(), locality: Self.localOnly)
        #expect(read.isEmpty)
        for name in ["web_search", "search_and_extract", "http_request"] {
            let web = WorkflowStepRisk.badges(for: tool(name), in: WorkflowDefinition(), locality: Self.localOnly)
            #expect(web.map(\.kind) == [.network], "\(name) reaches the web")
            #expect(web.first?.label == "Reaches the web" && web.first?.tone == .caution)
        }
    }

    @Test
    func badges_inference_cloudLocalUnbound_andAgentic() {
        let plain = WorkflowNode(
            id: "sum", name: "Summarize",
            kind: .inference(InferenceSpec(modelSlot: "writer", instructions: "Summarize {{input.q}}")))
        let cloud = WorkflowStepRisk.badges(for: plain, in: WorkflowDefinition(), locality: { _ in .cloud })
        #expect(cloud.map(\.kind) == [.cloudModel])
        #expect(cloud.first?.tone == .caution)
        #expect(cloud.first?.detail?.contains("leaves this Mac") == true)
        let local = WorkflowStepRisk.badges(for: plain, in: WorkflowDefinition(), locality: { _ in .local })
        #expect(local.map(\.kind) == [.localModel])
        #expect(local.first?.tone == .neutral)
        let unbound = WorkflowStepRisk.badges(for: plain, in: WorkflowDefinition(), locality: { _ in .unbound })
        #expect(unbound.first?.label == "Model not chosen")

        let agentic = WorkflowNode(
            id: "research", name: "Research",
            kind: .inference(
                InferenceSpec(
                    modelSlot: "worker", instructions: "Find out",
                    mode: .agentic(tools: [ToolRef(name: "web_fetch"), ToolRef(name: "file_write")], maxSteps: 6))))
        let kinds = WorkflowStepRisk.badges(for: agentic, in: WorkflowDefinition(), locality: { _ in .local }).map(\.kind)
        #expect(kinds.contains(.agentic))
        #expect(kinds.contains(.browser))
        #expect(kinds.contains(.files))
    }

    @Test
    func badges_mapStep_includesItsBodyWithoutCost() {
        let body: JSONValue = .object([
            "name": .string("Fetch one"), "kind": .string("http"),
            "http": .object(["url": .string("https://api.example.com/{{item}}")]),
            "input": .object([:]), "output_schema": WF.object([:]),
        ])
        let node = WorkflowNode(
            id: "each", name: "Each", kind: .map(MapSpec(items: "{{input.items}}", step: body, concurrency: 3)))
        let history = WorkflowStepRisk.History(runs: 2, averageMs: 1500, averageTokens: 0, failures: 0)
        let badges = WorkflowStepRisk.badges(for: node, in: WorkflowDefinition(), locality: Self.localOnly, history: history)
        #expect(badges.first?.label == "Repeats per item, 3 at a time")
        #expect(badges.contains { $0.kind == .network && $0.label == "Reaches api.example.com" })
        // The parent's cost badge is kept; the body's own would double count.
        #expect(badges.filter { $0.kind == .cost }.count == 1)
        #expect(badges.first { $0.kind == .cost }?.label == "~2 s")
    }

    @Test
    func badges_dialogWaitAndSubworkflow() {
        let dialog = WorkflowNode(
            id: "ask", name: "Ask", kind: .dialog(DialogSpec(title: "Which?", fields: [])))
        #expect(WorkflowStepRisk.badges(for: dialog, in: WorkflowDefinition(), locality: Self.localOnly).first?.kind == .asksUser)
        let wait = WorkflowNode(id: "wait", name: "Wait", kind: .wait(WaitSpec(seconds: "5")))
        #expect(WorkflowStepRisk.badges(for: wait, in: WorkflowDefinition(), locality: Self.localOnly).first?.kind == .waits)
        let sub = WorkflowNode(id: "sub", name: "Sub", kind: .workflow(SubworkflowSpec(workflow: "Send digest")))
        let badge = WorkflowStepRisk.badges(for: sub, in: WorkflowDefinition(), locality: Self.localOnly).first
        #expect(badge?.kind == .subworkflow)
        #expect(badge?.label == "Runs “Send digest”")
        #expect(badge?.tone == .caution)
    }

    @Test
    func history_averagesPerStep_andCostBadgeReadsIt() {
        let id = UUID()
        let runs = [
            Self.run(workflowID: id, status: .completed, startedAt: Date(timeIntervalSinceNow: -100)),
            Self.run(workflowID: id, status: .failed, startedAt: Date(timeIntervalSinceNow: -50)),
        ]
        let history = WorkflowStepRisk.history(from: runs)
        let a = try? #require(history["a"])
        #expect(a?.runs == 2)
        #expect(a?.averageMs == 1000)
        #expect(a?.averageTokens == 400)
        #expect(a?.failures == 0)
        let b = history["b"]
        #expect(b?.runs == 2)
        #expect(b?.failures == 1)
        #expect(b?.averageMs == 1500)
        #expect(b?.averageTokens == nil)

        let node = WF.code("a")
        let badges = WorkflowStepRisk.badges(for: node, in: WorkflowDefinition(), locality: Self.localOnly, history: history["a"])
        let cost = badges.first { $0.kind == .cost }
        #expect(cost?.label == "~1 s · ~400 tokens")
        #expect(cost?.detail == "Across 2 past runs.")
        let failing = WorkflowStepRisk.badges(for: WF.code("b"), in: WorkflowDefinition(), locality: Self.localOnly, history: history["b"])
            .first { $0.kind == .cost }
        #expect(failing?.tone == .caution)
        #expect(failing?.detail == "Across 2 past runs; failed 1 time(s).")
    }

    @Test
    func report_listsOnlyStepsWithBadges_asPlainDictionaries() {
        var def = Self.chain()
        def.nodes.append(
            WorkflowNode(
                id: "post", name: "Post",
                kind: .http(HTTPSpec(method: "POST", url: "https://hooks.example.com/x"))))
        let report = WorkflowStepRisk.report(def, locality: Self.localOnly)
        #expect(report.count == 1)
        #expect(report.first?["node_id"] as? String == "post")
        let badges = report.first?["badges"] as? [[String: Any]]
        #expect(badges?.first?["kind"] as? String == "network")
        #expect(badges?.first?["label"] as? String == "Reaches hooks.example.com")
        #expect(badges?.first?["tone"] as? String == "caution")
    }

    @Test
    func draftGet_reportsIssuesSetupAndRisks() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        var def = Self.chain()
        def.nodes[1] = WorkflowNode(
            id: "b", name: "Shell", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "shell_run"))),
            input: .object(["command": "echo {{nodes.a.output.x}}"]))
        WorkflowDraftStore.shared.applyUserEdit(draft.id) {
            $0.name = "Shelly"
            $0.definition = def
        }
        let text = try await asArchitect(session: session) {
            try await WorkflowDraftTool().execute(argumentsJSON: #"{"action": "get"}"#)
        }
        let parsed = try envelope(text)
        #expect(parsed["result"]?.objectValue?["issues"]?.arrayValue != nil)
        #expect(parsed["result"]?.objectValue?["setup"]?.arrayValue != nil)
        let risks = try #require(parsed["result"]?.objectValue?["risks"]?.arrayValue, Comment(rawValue: text))
        let shell = try #require(risks.first { $0.objectValue?["node_id"]?.stringValue == "b" }?.objectValue)
        let labels = shell["badges"]?.arrayValue?.compactMap { $0.objectValue?["label"]?.stringValue } ?? []
        #expect(labels.contains("Sandbox · Runs commands"))
    }

    @Test
    func badges_yourMac_marksStepsThatReachPickedFolders_notTheWorkspace() {
        let folder: JSONValue = .object(["type": .string("string"), "format": .string("folder")])
        let def = WorkflowDefinition(inputSchema: WF.object(["folder": folder]))
        func copy(_ source: String, _ destination: String) -> WorkflowNode {
            WorkflowNode(
                id: "copy", name: "Copy", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                input: .object(["source": source, "destination": destination]))
        }
        let deliver = WorkflowStepRisk.badges(
            for: copy("out/a.png", "{{input.folder}}/png/a.png"), in: def, locality: Self.localOnly)
        #expect(deliver.first?.kind == .yourMac && deliver.first?.label == "Your Mac")
        let internalCopy = WorkflowStepRisk.badges(for: copy("a.svg", "out/a.svg"), in: def, locality: Self.localOnly)
        #expect(!internalCopy.contains { $0.kind == .yourMac })
    }

    // MARK: - Change summaries

    @Test
    func architectPatch_recordsWhyAndPlainLines() throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        _ = try WorkflowDraftStore.shared.applyArchitectPatch(
            draft.id,
            ops: [
                .setInfo(name: "Digest", summary: "Summarizes the day"),
                .planPlaceholder(id: "a", name: "Collect", intent: "Collect items"),
            ], why: "Set up the first step so the digest has something to read.")
        let history = try #require(WorkflowDraftStore.shared.draft(id: draft.id)?.history)
        let edit = try #require(history.last)
        #expect(edit.source == .architect)
        #expect(edit.why == "Set up the first step so the digest has something to read.")
        #expect(!edit.lines.isEmpty, "\(edit.lines)")
        #expect(edit.lines.contains("Added step “Collect”"), "\(edit.lines)")
        #expect(edit.lines.contains("Renamed the workflow to \"Digest\""), "\(edit.lines)")
        #expect(edit.lines.contains("Changed the summary"), "\(edit.lines)")
    }

    @Test
    func draftTool_passesWhyThrough_andUserEditsHaveNoWhy() async throws {
        let session = "architect-\(UUID().uuidString)"
        _ = try await asArchitect(session: session) {
            try await WorkflowDraftTool().execute(
                argumentsJSON: #"""
                {"action": "patch", "why": "Name it so the person can find it.",
                 "ops": [{"op": "set_info", "name": "Named", "summary": "A named draft"}]}
                """#)
        }
        let draft = try #require(WorkflowDraftStore.shared.draft(forSession: session))
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        #expect(draft.history.last?.why == "Name it so the person can find it.")
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.chain() }
        let user = try #require(WorkflowDraftStore.shared.draft(id: draft.id)?.history.last)
        #expect(user.source == .user)
        #expect(user.why == nil)
        #expect(user.lines.contains("Added step “A”"), "\(user.lines)")
        #expect(user.lines.contains("Connected “A” → “B”"), "\(user.lines)")
    }

    @Test
    func plainLines_nameStepsAndFields() {
        let old = Self.chain()
        var new = old
        new.nodes[0] = WorkflowNode(
            id: "a", name: "Gather",
            kind: .inference(InferenceSpec(modelSlot: "writer", instructions: "Gather {{input.q}}")),
            input: .object(["q": "{{input.q}}"]), outputSchema: WF.object(["x": WF.string]))
        new.nodes.removeLast()
        new.edges = []
        new.outputSchema = WF.object(["x": WF.string])
        let lines = WorkflowDiff.plainLines(from: old, to: new)
        #expect(lines.contains("Removed step “B”"), "\(lines)")
        #expect(lines.contains("Disconnected “Gather” → “B”"), "\(lines)")
        #expect(lines.contains("Changed the shape of what you get"), "\(lines)")
        let changed = lines.first { $0.hasPrefix("Changed step “Gather”") }
        #expect(changed?.contains("name") == true, "\(lines)")
        #expect(changed?.contains("type") == true, "\(lines)")
        #expect(changed?.contains("model settings") == true, "\(lines)")
        #expect(changed?.contains("code") == true, "\(lines)")
    }

    @Test
    func draftEdit_codesWhyAndLines_andReadsOldRecordsWithout() throws {
        var edit = WorkflowDraftEdit(source: .architect, summary: "x", name: "N", definition: WorkflowDefinition())
        edit.why = "because"
        edit.lines = ["Added step A"]
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(WorkflowDraftEdit.self, from: data)
        #expect(back.why == "because")
        #expect(back.lines == ["Added step A"])
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "why")
        json.removeValue(forKey: "lines")
        let old = try JSONDecoder().decode(
            WorkflowDraftEdit.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.why == nil)
        #expect(old.lines.isEmpty)
    }

    // MARK: - Test evidence

    @Test
    func evidence_trivialChange_needsNoTest() {
        let session = "architect-\(UUID().uuidString)"
        let base = Self.chain()
        var draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        draft.definition = base
        draft.name = "Renamed"
        let evidence = WorkflowTestEvidence.evidence(for: draft, runs: [], base: base)
        #expect(!evidence.nonTrivial)
        #expect(evidence.satisfied)
        #expect(evidence.blocker == nil)
        #expect(evidence.changeLines.isEmpty)
    }

    @Test
    func evidence_newDraft_isNonTrivial_andNeedsAPassingRun() {
        let session = "architect-\(UUID().uuidString)"
        let created = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(created.id) }
        WorkflowDraftStore.shared.applyUserEdit(created.id) { $0.definition = Self.chain() }
        let draft = WorkflowDraftStore.shared.draft(id: created.id)!

        let none = WorkflowTestEvidence.evidence(for: draft, runs: [], base: nil)
        #expect(none.nonTrivial)
        #expect(!none.satisfied)
        #expect(none.blocker == "It hasn't passed a test since the steps changed. Run a test first.")
        #expect(!none.changeLines.isEmpty)

        let failed = WorkflowTestEvidence.evidence(
            for: draft, runs: [Self.run(workflowID: draft.id, status: .failed, startedAt: Date(timeIntervalSinceNow: 5))], base: nil)
        #expect(failed.failed == 1 && failed.passed == 0)
        #expect(failed.blocker == "The latest test failed. Fix the step and test again before saving.")
        #expect(failed.rows.first?.failedStep == "b")
        #expect(failed.rows.first?.error == "boom")

        let passed = WorkflowTestEvidence.evidence(
            for: draft, runs: [Self.run(workflowID: draft.id, status: .completed, startedAt: Date(timeIntervalSinceNow: 5))], base: nil)
        #expect(passed.satisfied)
        #expect(passed.passed == 1)
        #expect(passed.rows.first?.label == "Test run")
        #expect(passed.rows.first?.outputPreview == "answer: \"42\"")
        #expect(passed.rows.first?.durationMs == 3000)
    }

    @Test
    func evidence_ignoresRunsBeforeTheStepsChanged_andNamesExamples() throws {
        let session = "architect-\(UUID().uuidString)"
        let created = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(created.id) }
        var def = Self.chain()
        def.examples = [WorkflowExample(name: "Hello", input: .object(["q": .string("hello")]))]
        WorkflowDraftStore.shared.applyUserEdit(created.id) { $0.definition = def }
        let before = Self.run(workflowID: created.id, status: .completed, startedAt: Date(timeIntervalSinceNow: -30))
        // Change the steps after that run.
        var changed = def
        changed.nodes.append(WF.code("c", input: .object(["y": "{{nodes.b.output.y}}"])))
        changed.edges.append(WorkflowEdge(from: "b", to: "c"))
        WorkflowDraftStore.shared.applyUserEdit(created.id) { $0.definition = changed }
        let draft = try #require(WorkflowDraftStore.shared.draft(id: created.id))
        #expect(WorkflowTestEvidence.stepsChangedAt(draft) != nil)

        let stale = WorkflowTestEvidence.evidence(for: draft, runs: [before], base: nil)
        #expect(stale.rows.isEmpty)
        #expect(!stale.satisfied)

        // Renaming afterwards keeps the steps' change time.
        WorkflowDraftStore.shared.applyUserEdit(created.id) { $0.name = "Renamed" }
        let renamed = try #require(WorkflowDraftStore.shared.draft(id: created.id))
        #expect(WorkflowTestEvidence.stepsChangedAt(renamed) == WorkflowTestEvidence.stepsChangedAt(draft))

        let after = Self.run(workflowID: created.id, status: .completed, startedAt: Date(timeIntervalSinceNow: 5))
        let fresh = WorkflowTestEvidence.evidence(for: renamed, runs: [before, after], base: nil)
        #expect(fresh.rows.count == 1)
        #expect(fresh.rows.first?.label == "Example “Hello”")
        #expect(fresh.satisfied)
        // Non-test runs never count as evidence.
        let userRun = Self.run(workflowID: created.id, status: .completed, caller: .user, startedAt: Date(timeIntervalSinceNow: 6))
        #expect(WorkflowTestEvidence.evidence(for: renamed, runs: [userRun], base: nil).rows.isEmpty)
    }

    @Test
    func evidence_summary_isFoundationFriendly() {
        let session = "architect-\(UUID().uuidString)"
        let created = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(created.id) }
        WorkflowDraftStore.shared.applyUserEdit(created.id) { $0.definition = Self.chain() }
        let draft = WorkflowDraftStore.shared.draft(id: created.id)!
        let evidence = WorkflowTestEvidence.evidence(
            for: draft, runs: [Self.run(workflowID: draft.id, status: .failed, startedAt: Date(timeIntervalSinceNow: 5))], base: nil)
        let summary = evidence.summary
        #expect(summary["passed"] as? Int == 0)
        #expect(summary["failed"] as? Int == 1)
        #expect(summary["satisfied"] as? Bool == false)
        #expect((summary["blocker"] as? String)?.isEmpty == false)
        let runs = summary["runs"] as? [[String: Any]]
        #expect(runs?.first?["failed_step"] as? String == "b")
        #expect(JSONSerialization.isValidJSONObject(summary))
    }

    @Test
    func proposeSave_refusesWithoutAPassingTest_andSucceedsWithOne() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer {
            WorkflowDraftStore.shared.delete(draft.id)
            WorkflowRunStore.shared.resetForTesting()
        }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) {
            $0.name = "Gated"
            $0.definition = Self.chain()
        }
        let refused = try envelope(
            await asArchitect(session: session) {
                try await WorkflowProposeSaveTool().execute(argumentsJSON: #"{"changelog": "First version"}"#)
            })
        #expect(refused["ok"]?.boolValue == false)
        #expect(refused["kind"]?.stringValue == "rejected")
        #expect(refused["message"]?.stringValue?.contains("hasn't passed a test") == true, "\(refused)")
        #expect(refused["evidence"]?.objectValue?["satisfied"]?.boolValue == false)
        #expect(refused["hint"]?.stringValue?.contains("workflow_test") == true)

        // A failed test is still a refusal, with the failure named.
        let failed = Self.run(workflowID: draft.id, status: .failed, startedAt: Date(timeIntervalSinceNow: 5))
        WorkflowRunStore.shared.record(failed)
        WorkflowDraftStore.shared.recordTestRun(draft.id, runID: failed.id)
        let stillRefused = try envelope(
            await asArchitect(session: session) {
                try await WorkflowProposeSaveTool().execute(argumentsJSON: #"{"changelog": "First version"}"#)
            })
        #expect(stillRefused["message"]?.stringValue?.contains("latest test failed") == true, "\(stillRefused)")

        let passed = Self.run(workflowID: draft.id, status: .completed, startedAt: Date(timeIntervalSinceNow: 6))
        WorkflowRunStore.shared.record(passed)
        WorkflowDraftStore.shared.recordTestRun(draft.id, runID: passed.id)
        let accepted = try envelope(
            await asArchitect(session: session) {
                try await WorkflowProposeSaveTool().execute(argumentsJSON: #"{"changelog": "First version"}"#)
            })
        #expect(accepted["ok"]?.boolValue == true, "\(accepted)")
        let result = accepted["result"]?.objectValue
        #expect(result?["evidence"]?.objectValue?["passed"]?.numberValue == 1)
        #expect(result?["evidence"]?.objectValue?["satisfied"]?.boolValue == true)
        // Nothing is written until the person confirms.
        #expect(TemplateStore.shared.latest(id: draft.id) == nil)
    }

    /// The saver holds the same gate as the save card and the tool, so no
    /// caller can install an untested change; the person's explicit
    /// bypass is the only way past it.
    @Test
    func draftSaver_refusesAnUntestedChange_unlessThePersonBypasses() throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        var installedID: UUID?
        defer {
            WorkflowDraftStore.shared.delete(draft.id)
            WorkflowRunStore.shared.resetForTesting()
            if let installedID { InstalledWorkflowStore.shared.delete(id: installedID) }
        }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) {
            $0.name = "Saver Gate \(UUID().uuidString.prefix(4))"
            $0.definition = Self.chain()
        }
        #expect(throws: WorkflowDraftSaver.SaveError.untested("It hasn't passed a test since the steps changed. Run a test first.")) {
            try WorkflowDraftSaver.save(draftID: draft.id, changelog: "First")
        }
        #expect(TemplateStore.shared.latest(id: draft.id) == nil)

        let passed = Self.run(workflowID: draft.id, status: .completed, startedAt: Date(timeIntervalSinceNow: 5))
        WorkflowRunStore.shared.record(passed)
        WorkflowDraftStore.shared.recordTestRun(draft.id, runID: passed.id)
        let installed = try WorkflowDraftSaver.save(draftID: draft.id, changelog: "First")
        installedID = installed.id
        #expect(TemplateStore.shared.latest(id: draft.id)?.version == 1)
    }

    /// Packages and folders are part of what a workflow does on this Mac,
    /// so changing them is a reviewable change that needs a test like any
    /// step edit.
    @Test
    func diff_namesDependencyAndFolderChanges_andTheyCountAsNonTrivial() {
        let base = Self.chain()
        var deps = base
        deps.dependencies = [WorkflowDependency(manager: .pip, packages: ["requests"])]
        let depLines = WorkflowDiff.plainLines(from: base, to: deps)
        #expect(depLines == ["Changed the packages it installs"])
        var folders = base
        folders.folders = [FolderRequirement(key: "inbox", label: "Inbox")]
        #expect(WorkflowDiff.plainLines(from: base, to: folders) == ["Changed the folders it uses"])

        let session = "architect-\(UUID().uuidString)"
        var draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        draft.definition = deps
        let evidence = WorkflowTestEvidence.evidence(for: draft, runs: [], base: base)
        #expect(evidence.nonTrivial)
        #expect(evidence.blocker != nil)
    }

    /// An installed workflow's Recent Runs and cost badges describe what
    /// it did for people and agents; Architect tests and eval runs stay
    /// out of both, persisted and live.
    @Test
    func runStore_leavesTestRunsOut_whenAsked() {
        let store = WorkflowRunStore.shared
        defer { store.resetForTesting() }
        let workflowID = UUID()
        let real = Self.run(workflowID: workflowID, status: .completed, caller: .agent, startedAt: Date(timeIntervalSinceNow: -30))
        let eval = Self.run(workflowID: workflowID, status: .completed, caller: .test, startedAt: Date(timeIntervalSinceNow: -20))
        // Terminal, so nothing is left open in the shared store for the
        // relaunch tests; `record` keeps a live copy either way.
        let liveTest = Self.run(workflowID: workflowID, status: .failed, caller: .test, startedAt: Date(timeIntervalSinceNow: -10))
        store.record(real)
        store.record(eval)
        store.record(liveTest)
        #expect(eval.isTest && liveTest.isTest && !real.isTest)

        let all = store.runs(workflowID: workflowID)
        #expect(Set(all.map(\.id)) == [real.id, eval.id, liveTest.id])
        let realOnly = store.runs(workflowID: workflowID, includeTests: false)
        #expect(realOnly.map(\.id) == [real.id])
        // The history behind cost badges follows the same rule.
        #expect(WorkflowStepRisk.history(from: realOnly)["a"]?.runs == 1)
    }

    @Test
    func savePromptState_carriesEvidence_andDefaultsFromTheStore() {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.chain() }
        let state = WorkflowSavePromptState(draftID: draft.id, name: "X", version: 1, changelog: "First")
        #expect(state.evidence.nonTrivial)
        #expect(!state.evidence.satisfied)
        let given = WorkflowSavePromptState(
            draftID: draft.id, name: "X", version: 1, changelog: "First", evidence: .empty)
        #expect(given.evidence.satisfied)
    }

    // MARK: - Older records

    @Test
    func run_readsRecordsThatStillCarryAnExplanation() throws {
        let run = Self.run(workflowID: UUID(), status: .completed, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json["explanation"] = ["text": "It completed.", "author": "facts", "at": 0]
        let old = try JSONDecoder().decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.id == run.id)
        #expect(old.status == .completed)
    }
}
