//
//  ArchitectInlineHandoffTests.swift
//  OsaurusCoreTests
//
//  `architect_handoff`: the Architect drafts into
//  an inline draft, the draft runs at once as an ephemeral run, a completed
//  run carries a keep offer, and a yes raises the Save card through
//  `workflow_propose_save`. When the first step is not running in time the
//  request goes back to the Orchestrator.
//

import Foundation
import Testing

@testable import OsaurusCore

/// The Architect's model: step one patches the draft with `ops`, step two
/// replies. `delay` holds the first step (the deadline tests).
private actor ScriptedArchitect {
    private(set) var requests = 0
    private let ops: String?
    private let delay: Duration?

    init(ops: String?, delay: Duration? = nil) {
        self.ops = ops
        self.delay = delay
    }

    func stream(for request: ResponsesInferenceRequest) async throws
        -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
    {
        requests += 1
        let step = requests
        if step == 1, let delay { try await Task.sleep(for: delay) }
        let arguments = ops.map { #"{"action":"patch","why":"Builds it.","ops":\#($0)}"# }
        return ResponsesGenerationStream.compatibility(
            AsyncThrowingStream { continuation in
                if step == 1, let arguments {
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: WorkflowDraftTool.toolName, jsonArguments: arguments, toolCallId: "call_patch"))
                } else {
                    continuation.yield("Looks up the weather and answers.")
                    continuation.finish()
                }
            })
    }
}

@Suite(.serialized)
@MainActor
struct ArchitectInlineHandoffTests {

    /// One inference step that answers the request.
    static let oneStepOps = #"""
        [
          {"op": "set_info", "name": "Weather Answer", "summary": "Answers a weather question."},
          {"op": "set_schemas",
           "input_schema": {"type": "object", "properties": {"request": {"type": "string", "title": "Request",
             "description": "What to do"}}, "required": ["request"], "additionalProperties": false},
           "output_schema": {"type": "object", "properties": {"answer": {"type": "string", "title": "Answer"}},
             "required": ["answer"]}},
          {"op": "plan_placeholder", "id": "answer", "name": "Answer"},
          {"op": "update_node", "id": "answer", "node": {"kind": "inference",
            "inference": {"instructions": "Answer the request.", "mode": "generate"},
            "input": "{{input.request}}",
            "output_schema": {"type": "object", "properties": {"answer": {"type": "string"}},
              "required": ["answer"]}}},
          {"op": "set_output", "output": {"answer": "{{nodes.answer.output.answer}}"}}
        ]
        """#

    static let message = "check the weather in Lisbon and tell me if I need a coat"

    /// Runs `architect_handoff` as the Orchestrator would.
    static func handoff(
        _ arguments: String = #"{"user_message":"x","brief":"weather then answer"}"#,
        seams: ArchitectInlineHandoff.Seams,
        toolCallID: String = "call-architect-\(UUID().uuidString)"
    ) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$currentSessionId.withValue("chat-\(UUID().uuidString)") {
                try await ChatExecutionContext.$currentUserRequest.withValue(message) {
                    try await ChatExecutionContext.$currentToolCallId.withValue(toolCallID) {
                        try await ArchitectHandoffTool(seams: seams).execute(argumentsJSON: arguments)
                    }
                }
            }
        }
    }

    fileprivate static func seams(
        _ architect: ScriptedArchitect, draftDeadline: TimeInterval = 30,
        firstStepRunning: (@Sendable (UUID, Date) async -> Bool)? = nil,
        report: (@Sendable (ArchitectInlineHandoff.DraftReport) -> Void)? = nil
    ) -> ArchitectInlineHandoff.Seams {
        ArchitectInlineHandoff.Seams(
            evalModel: "scripted-architect",
            dispatchOverride: { invocation in
                (try? await WorkflowDraftTool().execute(argumentsJSON: invocation.jsonArguments))
                    ?? ToolEnvelope.failure(kind: .executionError, message: "patch threw", tool: invocation.toolName)
            },
            streamProvider: { request in try await architect.stream(for: request) },
            draftDeadline: draftDeadline,
            firstStepRunning: firstStepRunning,
            report: report)
    }

    /// The envelope is a non-retryable failure that names the next step.
    static func expectHandedBack(_ result: String, kind: ToolEnvelope.Kind) throws {
        #expect(ToolEnvelope.isError(result), "\(result)")
        let failure = try #require(
            (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any], "\(result)")
        #expect(failure["kind"] as? String == kind.rawValue)
        #expect(failure["retryable"] as? Bool == false)
        #expect((failure["message"] as? String)?.hasSuffix(ArchitectInlineHandoff.handBackNextStep) == true)
        #expect(failure["tool"] as? String == ArchitectHandoffTool.toolName)
    }

    struct StepFailed: Error {}

    static func withExecutor<T>(
        _ outcome: @escaping @Sendable () throws -> WorkflowNodeOutcome, _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        try await WorkflowExecutorOverride.with({ ClosureExecutor { _, _ in try outcome() } }, body)
    }

    nonisolated static let answered = WorkflowNodeOutcome(output: .object(["answer": .string("Yes, 14°C and rain.")]))

    // MARK: - Draft, run, keep, promote

    @Test
    func aDraftRunsAtOnceAndAYesRaisesTheSaveCardThatInstallsIt() async throws {
        let lease = await acquireSubagentStoreSandbox("architect-inline-success")
        defer { lease.release() }
        let architect = ScriptedArchitect(ops: Self.oneStepOps)
        let started = Date()
        let result = try await Self.withExecutor({ Self.answered }) {
            try await Self.handoff(seams: Self.seams(architect))
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        #expect(payload["status"] as? String == "completed")
        let offer = try #require(payload["keep_offer"] as? [String: Any], "a completed run offers to keep it")
        let draftID = try #require((offer["keep_draft"] as? String).flatMap(UUID.init(uuidString:)))
        #expect(offer["name"] as? String == "Weather Answer")
        #expect((payload["present"] as? String)?.contains("keep_draft") == true)
        #expect(elapsed < ArchitectInlineHandoff.firstStepDeadline, "drafted and ran in \(elapsed)s")

        let runID = try #require(WorkflowToolCall.runID(inResult: result))
        let run = try #require(WorkflowRunStore.shared.run(id: runID))
        #expect(run.ephemeral)
        #expect(!run.isTest)
        #expect(run.caller.kind == .orchestrator)
        #expect(!WorkflowRunStore.shared.recentRuns().contains { $0.id == runID }, "kept out of run history")

        let draft = try #require(WorkflowDraftStore.shared.draft(id: draftID))
        defer { WorkflowDraftStore.shared.delete(draftID) }
        #expect(WorkflowDraftStore.isInline(draft))
        #expect(draft.testRunIDs.contains(runID))
        #expect(WorkflowDraftStore.shared.testEvidence(draftID).blocker == nil, "the chat run is the evidence")
        #expect(!WorkflowDraftStore.shared.libraryDrafts.contains { $0.id == draftID })

        let kept = try await Self.handoff(
            #"{"user_message":"yes keep it","brief":"keep","keep_draft":"\#(draftID.uuidString)"}"#,
            seams: Self.seams(ScriptedArchitect(ops: nil)))
        #expect(ToolEnvelope.isSuccess(kept), "\(kept)")
        let proposal = try #require(ToolEnvelope.successPayload(kept) as? [String: Any])
        #expect(proposal[ArchitectInlineHandoff.savePromptKey] as? Bool == true)
        #expect(proposal["draft_id"] as? String == draftID.uuidString)
        #expect(proposal["status"] as? String == "waiting_for_user")
        #expect(InstalledWorkflowStore.shared.workflows.allSatisfy { $0.name != "Weather Answer" }, "nothing saved yet")

        let installed = try WorkflowDraftSaver.save(draftID: draftID, changelog: ArchitectInlineHandoff.keepChangelog)
        defer { InstalledWorkflowStore.shared.delete(id: installed.id) }
        #expect(installed.name == "Weather Answer")
        #expect(WorkflowValidator.validate(installed.definition, allowPlaceholders: false).isEmpty)
        #expect(InstalledWorkflowStore.shared.workflow(id: installed.id) != nil)
        #expect(WorkflowDraftStore.shared.drafts(templateID: installed.templateID).isEmpty, "Edit opens a new chat")
    }

    @Test
    func aFailedRunHasNoKeepOffer() async throws {
        let lease = await acquireSubagentStoreSandbox("architect-inline-failed")
        defer { lease.release() }
        let result = try await Self.withExecutor({ throw StepFailed() }) {
            try await Self.handoff(seams: Self.seams(ScriptedArchitect(ops: Self.oneStepOps)))
        }
        let payload = ToolEnvelope.successPayload(result) as? [String: Any]
        #expect(payload?["keep_offer"] == nil, "\(result)")
        #expect(!result.contains("keep_draft"))
    }

    // MARK: - Deadline hand back

    @Test
    func pastTheDeadlineTheRequestGoesBackToTheOrchestrator() async throws {
        let lease = await acquireSubagentStoreSandbox("architect-inline-hand-back")
        defer { lease.release() }
        let inlineBefore = Self.inlineDraftIDs()
        // Other suites start test runs in parallel; a hand-off run is the Orchestrator's.
        func handoffRuns() -> Set<UUID> {
            Set(WorkflowRunStore.shared.recentRuns().filter { $0.caller.kind == .orchestrator }.map(\.id))
        }
        let runsBefore = handoffRuns()
        let architect = ScriptedArchitect(ops: Self.oneStepOps, delay: .seconds(3))
        let reports = DraftReports()
        let seams = Self.seams(architect, draftDeadline: 0.3, report: { reports.append($0) })
        let result = try await Self.withExecutor({ Self.answered }) {
            try await Self.handoff(seams: seams)
        }
        try Self.expectHandedBack(result, kind: .timeout)
        #expect(WorkflowToolCall.runID(inResult: result) == nil, "nothing ran in the Architect's place")
        #expect(handoffRuns() == runsBefore)
        #expect(!result.contains("keep_offer"))
        var late = Self.inlineDraftIDs().subtracting(inlineBefore)
        for _ in 0..<100 where !late.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            late = Self.inlineDraftIDs().subtracting(inlineBefore)
        }
        #expect(late.isEmpty, "the late draft is dropped, not run")
        #expect(reports.all.first?.abandoned == .deadline(.draft), "the draft's budget ran out, not the step's")
    }

    @Test
    func aRunWhoseFirstStepDoesNotStartHandsBackAttributedToTheStep() async throws {
        let lease = await acquireSubagentStoreSandbox("architect-inline-hand-back-step")
        defer { lease.release() }
        let reports = DraftReports()
        let seams = Self.seams(
            ScriptedArchitect(ops: Self.oneStepOps), firstStepRunning: { _, _ in false },
            report: { reports.append($0) })
        let result = try await Self.withExecutor({ Self.answered }) {
            try await Self.handoff(seams: seams)
        }
        try Self.expectHandedBack(result, kind: .timeout)
        let report = try #require(reports.all.first)
        #expect(report.abandoned == .deadline(.step))
        #expect(report.nodeCount == 1, "the draft was ready; only its first step missed")
        #expect(report.draftBudgetSeconds == 30)
    }

    // MARK: - Draft budget

    @Test
    func theDraftBudgetScalesWithTheModelsSpeedAboveAFloor() {
        #expect(DraftBudget.wallClock(measuredTokensPerSecond: nil) == 80, "1,200 tokens at the default 15 tok/s")
        #expect(DraftBudget.wallClock(measuredTokensPerSecond: 25) == 48)
        #expect(DraftBudget.wallClock(measuredTokensPerSecond: 120) == DraftBudget.floorSeconds)
        #expect(DraftBudget.wallClock(measuredTokensPerSecond: 0) == 80, "no rate is the default, not forever")
    }

    @Test
    func theLedgerKeepsTheLastRatePerModelAndForTheResidentOne() {
        let model = "eval-ledger/Ledger-Model-\(UUID().uuidString)"
        ModelThroughputLedger.record(model: model, tokensPerSecond: 31, tokens: 200)
        #expect(ModelThroughputLedger.tokensPerSecond(for: model) == 31)
        #expect(
            ModelThroughputLedger.tokensPerSecond(for: model.split(separator: "/").last.map(String.init)?.lowercased())
                == 31, "the picker's name and the bundle id are one model")
        ModelThroughputLedger.record(model: model, tokensPerSecond: 90, tokens: 4)
        #expect(ModelThroughputLedger.tokensPerSecond(for: model) == 31, "a four-token step is not a rate")
        ModelThroughputLedger.record(model: model, tokensPerSecond: 24, tokens: 400)
        #expect(ModelThroughputLedger.tokensPerSecond(for: model) == 24, "the last rate, not the best")
        #expect(DraftBudget.wallClock(model: model) == 50)
        #expect(ModelThroughputLedger.tokensPerSecond(for: "never-seen-\(UUID().uuidString)") == nil)
    }

    @Test
    func theCardKeepsPlanningAsACollapsedFirstStep() throws {
        let draft = WorkflowDraftStore.shared.createInline()
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        _ = try WorkflowDraftStore.shared.applyArchitectPatch(
            draft.id, ops: [.setInfo(name: "Weather Answer", summary: nil)])
        let template = try #require(WorkflowDraftStore.shared.draft(id: draft.id)).template()
        let workflow = InstalledWorkflow(
            id: draft.id, template: template, bindings: WorkflowDraftStore.shared.testBindings(draft.id),
            orchestratorVisible: false)
        let patch = HandoffToolCall(
            name: WorkflowDraftTool.toolName, argumentsJSON: #"{"action":"patch","why":"Look it up, then answer."}"#,
            result: ToolEnvelope.success(tool: WorkflowDraftTool.toolName, result: ["ok": true]))
        let planning = ArchitectInlineHandoff.planning(seconds: 23.44, calls: [patch])
        #expect(planning.reason == "Look it up, then answer.")
        let event = WorkflowCallFeed.planningEvent(planning, workflow: workflow)
        #expect(event.title == ArchitectInlineHandoff.planningPhase)
        #expect(event.detail == "23.4 s")
        #expect(event.success == true)
        #expect(event.expandableText?.contains("Look it up, then answer.") == true)
        #expect(ArchitectInlineHandoff.draftTarget.workingPhase == ArchitectInlineHandoff.planningPhase)
    }

    static func inlineDraftIDs() -> Set<UUID> {
        Set(WorkflowDraftStore.shared.drafts.values.filter(WorkflowDraftStore.isInline).map(\.id))
    }

    @Test
    func aReplyWithNoDraftHandsBackToo() async throws {
        let lease = await acquireSubagentStoreSandbox("architect-inline-hand-back-invalid")
        defer { lease.release() }
        let result = try await Self.handoff(seams: Self.seams(ScriptedArchitect(ops: nil)))
        try Self.expectHandedBack(result, kind: .executionError)
    }

    // MARK: - Pieces

    @Test
    func theDraftOutcomeComesFromThePatchNotTheReply() {
        let patch = HandoffToolCall(
            name: WorkflowDraftTool.toolName, argumentsJSON: #"{"action":"patch","ops":[]}"#,
            result: ToolEnvelope.success(tool: WorkflowDraftTool.toolName, result: ["ok": true]))
        let get = HandoffToolCall(
            name: WorkflowDraftTool.toolName, argumentsJSON: #"{"action":"get"}"#,
            result: ToolEnvelope.success(tool: WorkflowDraftTool.toolName, result: ["ok": true]))
        #expect(ArchitectInlineHandoff.classifyDraft([patch], digest: "") == .applied("Drafted the workflow."))
        #expect(ArchitectInlineHandoff.classifyDraft([get], digest: "Built it!") == .answer("Built it!"))
    }

    @Test
    func onlyACompleteCleanPatchEndsTheDraftRun() {
        func patch(_ result: [String: Any], ok: Bool = true) -> HandoffToolCall {
            HandoffToolCall(
                name: WorkflowDraftTool.toolName, argumentsJSON: #"{"action":"patch","ops":[]}"#,
                result: ok
                    ? ToolEnvelope.success(tool: WorkflowDraftTool.toolName, result: result)
                    : ToolEnvelope.failure(kind: .invalidArgs, message: "ops[3]: bad", tool: WorkflowDraftTool.toolName))
        }
        let clean: [String: Any] = ["node_count": 2, "placeholders": [String](), "issues": [[String: Any]]()]
        #expect(ArchitectInlineHandoff.draftIsReady(patch(clean)))
        #expect(!ArchitectInlineHandoff.draftIsReady(patch(clean, ok: false)))
        #expect(!ArchitectInlineHandoff.draftIsReady(patch(clean.merging(["issues": [["message": "x"]]]) { $1 })))
        #expect(!ArchitectInlineHandoff.draftIsReady(patch(clean.merging(["placeholders": ["b"]]) { $1 })))
        #expect(!ArchitectInlineHandoff.draftIsReady(patch(clean.merging(["node_count": 0]) { $1 })))
        let get = HandoffToolCall(
            name: WorkflowDraftTool.toolName, argumentsJSON: #"{"action":"get"}"#,
            result: ToolEnvelope.success(tool: WorkflowDraftTool.toolName, result: clean))
        #expect(!ArchitectInlineHandoff.draftIsReady(get))
        #expect(ArchitectInlineHandoff.draftTarget.endsRun != nil)
    }

    @Test
    func inlineDraftsStayOffWorkflowsHomeAndExpire() {
        let store = WorkflowDraftStore.shared
        let stale = store.createInline()
        let fresh = store.createInline(now: Date().addingTimeInterval(WorkflowDraftStore.inlineDraftLifetime + 60))
        defer { store.delete(fresh.id) }
        #expect(WorkflowDraftStore.isInline(fresh))
        #expect(!store.libraryDrafts.contains { $0.id == fresh.id })
        #expect(store.draft(id: stale.id) == nil, "an inline draft nobody kept expires")
    }

    @Test
    func theFastPersonaIsShortAndNamesOnlyTheDraftTool() {
        let persona = ArchitectSystemPromptBuilder.fastDraft
        #expect(persona.count < ArchitectSystemPromptBuilder.render().count / 4)
        #expect(persona.contains("at most \(ArchitectSystemPromptBuilder.fastDraftMaxNodes) steps"))
        #expect(!persona.contains("workflow_test"))
        #expect(!persona.contains("clarify"))
        #expect(ArchitectInlineHandoff.draftTarget.toolNames() == [WorkflowDraftTool.toolName])
    }

    @Test
    func theHandoffIsAWorkflowCallWithAKeepDraft() {
        let schema = ArchitectHandoffTool().parameters?.objectValue?["properties"]?.objectValue
        #expect(schema?["keep_draft"] != nil)
        #expect(WorkflowToolCall.isWorkflowCall(ArchitectHandoffTool.toolName))
    }
}

private final class DraftReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [ArchitectInlineHandoff.DraftReport] = []

    func append(_ report: ArchitectInlineHandoff.DraftReport) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    var all: [ArchitectInlineHandoff.DraftReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
