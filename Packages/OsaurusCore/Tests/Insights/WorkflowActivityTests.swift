//
//  WorkflowActivityTests.swift
//  osaurusTests
//
//  Workflow runs in the activity log: one row per finished step and one
//  per run, written once each; the run id on every row; the v2 store
//  column, lookup, and filter; content withheld under the metadata-only
//  policy; and the scope and token Insights shows for them.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Workflow activity")
struct WorkflowActivityTests {

    private static func definition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["topic": WF.string]),
            outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "draft", name: "Draft Notes",
                    kind: .code(CodeSpec(source: "async function run(i){ return {} }"))),
                WorkflowNode(
                    id: "save", name: "Save Notes", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write")))),
            ],
            edges: [WorkflowEdge(from: "draft", to: "save")])
    }

    private static func run(caller: WorkflowCaller = WorkflowCaller(kind: .agent, agentID: UUID(), agentName: "Scout"))
        -> WorkflowRun
    {
        WorkflowRun(
            workflowID: UUID(), workflowName: "Meeting Notes", templateID: UUID(), templateVersion: 1,
            caller: caller, input: .object(["topic": .string("Q3")]), nodeIDs: ["draft", "save"],
            startedAt: Date(timeIntervalSince1970: 1_000))
    }

    private static func finish(_ run: inout WorkflowRun, _ id: String, status: NodeRunStatus = .done) {
        run.update(id) { node in
            node.status = status
            node.input = .object(["topic": .string("Q3")])
            node.output = status == .done ? .object(["ok": .bool(true)]) : nil
            node.error = status == .failed ? "disk full" : nil
            node.attempts = 1
            node.startedAt = Date(timeIntervalSince1970: 1_000)
            node.finishedAt = Date(timeIntervalSince1970: 1_002)
        }
    }

    private final class Sink {
        var rows: [RequestLog] = []
    }

    private static func logger() -> (WorkflowActivityLogger, Sink) {
        let sink = Sink()
        let logger = WorkflowActivityLogger()
        logger.sink = { sink.rows.append($0) }
        return (logger, sink)
    }

    @Test
    func eachFinishedStepIsLoggedOnce_thenTheRun() {
        let (logger, sink) = Self.logger()
        var run = Self.run()
        logger.begin(runID: run.id, definition: Self.definition())

        logger.observe(run)
        #expect(sink.rows.isEmpty)
        Self.finish(&run, "draft")
        logger.observe(run)
        logger.observe(run)
        #expect(sink.rows.map(\.category) == [.workflowNode])

        Self.finish(&run, "save")
        run.status = .completed
        run.output = .object(["path": .string("notes.md")])
        run.finishedAt = Date(timeIntervalSince1970: 1_005)
        logger.finished(run)
        #expect(sink.rows.map(\.category) == [.workflowNode, .workflowNode, .workflowRun])
        #expect(sink.rows.allSatisfy { $0.workflowRunId == run.id })
        #expect(sink.rows.map(\.workflowNodeId) == ["draft", "save", nil])

        // State is cleared: a late update writes nothing more.
        logger.observe(run)
        #expect(sink.rows.count == 3)
    }

    @Test
    func runRow_carriesTheCallerStatusAndBodies() throws {
        var run = Self.run()
        Self.finish(&run, "draft")
        Self.finish(&run, "save", status: .failed)
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "save", reason: "disk full", attempts: 1)
        run.finishedAt = Date(timeIntervalSince1970: 1_004)
        let row = WorkflowActivityLogger.runRow(run, definition: Self.definition())

        #expect(row.category == .workflowRun)
        #expect(row.method == "RUN")
        #expect(row.path == "/workflow/meeting-notes")
        #expect(row.statusCode == 500)
        #expect(row.isError)
        #expect(row.durationMs == 4_000)
        #expect(row.source == .agent)
        #expect(row.agentName == "Scout")
        #expect(row.requestId == run.id.uuidString)
        #expect(row.errorMessage == "disk full")
        #expect(row.requestBody.flatMap(JSONValue.parse) == run.input)
        let details = try #require(row.egress?.details)
        #expect(details["workflow"] == "Meeting Notes")
        #expect(details["status"] == "failed")
        #expect(details["failed_step"] == "Save Notes")
        #expect(details["steps"] == "2")
        #expect(details["caller"] == "\(L("Agent")) · Scout")
        #expect(row.title.contains("Meeting Notes"))
    }

    @Test
    func nodeRow_carriesTheStepToolCallsAndRequests() throws {
        var run = Self.run()
        Self.finish(&run, "save")
        run.update("save") { node in
            node.toolCallRecords = [
                WorkflowToolCallRecord(
                    name: "file_write", arguments: #"{"path":"notes.md"}"#, result: #"{"ok":true}"#, durationMs: 15,
                    isError: false)
            ]
            node.fetches = ["GET api.example.com/v1/items"]
            node.logs = ["wrote 12 bytes"]
        }
        let row = WorkflowActivityLogger.nodeRow(try #require(run.node("save")), of: run, definition: Self.definition())

        #expect(row.category == .workflowNode)
        #expect(row.method == "STEP")
        #expect(row.path == "/workflow/meeting-notes/save")
        #expect(row.durationMs == 2_000)
        #expect(row.toolCalls?.map(\.name) == ["file_write"])
        #expect(row.toolCalls?.first?.durationMs == 15)
        #expect(row.locality == .remote)
        #expect(row.egress?.destinationHost == "api.example.com")
        let details = try #require(row.egress?.details)
        #expect(details["node_name"] == "Save Notes")
        #expect(details["kind"] == "tool")
        #expect(details["logs"] == "wrote 12 bytes")
        #expect(row.title.contains("Save Notes"))

        // Metadata-only policy withholds the bodies, tool payloads, and logs.
        let withheld = row.withoutContent()
        #expect(withheld.workflowRunId == run.id)
        #expect(withheld.workflowNodeId == "save")
        #expect(withheld.egress?.details["logs"] != "wrote 12 bytes")
        #expect(withheld.egress?.details["urls"] != "GET api.example.com/v1/items")
        #expect(withheld.toolCalls?.first?.arguments == RequestLog.contentWithheldMarker)
    }

    @Test
    func callerSurfaces_mapToSources() {
        func source(_ caller: WorkflowCaller) -> RequestSource { WorkflowActivityLogger.source(for: caller) }
        #expect(source(WorkflowCaller(kind: .user)) == .chatUI)
        #expect(source(WorkflowCaller(kind: .test)) == .chatUI)
        #expect(source(WorkflowCaller(kind: .orchestrator)) == .agent)
        #expect(source(WorkflowCaller(kind: .agent, isUnattendedDispatch: true)) == .scheduled)
        #expect(source(WorkflowCaller(kind: .agent, isExternalSurface: true)) == .httpAPI)
        #expect(WorkflowActivityLogger.statusCode(.cancelled) == 499)
        #expect(WorkflowActivityLogger.statusCode(.completed) == 200)
        #expect(WorkflowActivityLogger.slug("Q3 — Board Prep!") == "q3-board-prep")
    }

    // MARK: - Store

    @Test
    func store_findsAndFiltersByRun() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        var run = Self.run()
        Self.finish(&run, "draft")
        run.status = .completed
        run.finishedAt = Date(timeIntervalSince1970: 1_003)
        let other = Self.run()
        try store.append(WorkflowActivityLogger.nodeRow(try #require(run.node("draft")), of: run, definition: nil))
        try store.append(WorkflowActivityLogger.runRow(run, definition: nil))
        try store.append(WorkflowActivityLogger.runRow(other, definition: nil))
        try store.append(
            RequestLog(
                source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1,
                workflowRunId: run.id, workflowNodeId: "draft"))

        let found = try #require(try store.find(workflowRunId: run.id))
        #expect(found.category == .workflowRun)
        #expect(found.workflowRunId == run.id)

        let rows = try store.fetch(filter: ActivityFilter(workflowRunId: run.id))
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.workflowRunId == run.id })
        #expect(InsightsService.filterInMemory(rows + [WorkflowActivityLogger.runRow(other, definition: nil)],
            ActivityFilter(workflowRunId: run.id)).count == 3)
        #expect(try store.verify().isIntact)
    }

    @Test
    func store_v1DatabaseMigrates_andOldRowsStillVerify() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        try store.append(
            RequestLog(source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1))
        try store.executeForTesting("DROP INDEX idx_activity_workflow_run")
        try store.executeForTesting("ALTER TABLE activity DROP COLUMN workflow_run_id")
        try store.executeForTesting("PRAGMA user_version = 1")

        #expect(try store.migrateForTesting() == 1)
        #expect(try store.migrateForTesting() == 1)
        let run = Self.run()
        try store.append(WorkflowActivityLogger.runRow(run, definition: nil))
        #expect(try store.find(workflowRunId: run.id) != nil)
        #expect(try store.verify().isIntact)
    }

    /// Stable Osaurus refuses an activity log stamped above 1, so a store an
    /// earlier beta stamped 2 goes back to 1 and keeps its workflow rows.
    @Test
    func store_earlierBetaStampIsRestampedToStableVersion() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        let run = Self.run()
        try store.append(WorkflowActivityLogger.runRow(run, definition: nil))
        try store.executeForTesting("PRAGMA user_version = 2")

        #expect(try store.migrateForTesting() == 1)
        #expect(try store.find(workflowRunId: run.id) != nil)
        #expect(try store.verify().isIntact)
    }

    @Test
    func store_unknownNewerSchemaIsStillRefused() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        try store.executeForTesting("DROP INDEX idx_activity_workflow_run")
        try store.executeForTesting("ALTER TABLE activity DROP COLUMN workflow_run_id")
        try store.executeForTesting("PRAGMA user_version = 2")
        #expect(throws: ActivityLogStoreError.self) { try store.migrateForTesting() }

        try store.executeForTesting("PRAGMA user_version = 3")
        #expect(throws: ActivityLogStoreError.self) { try store.migrateForTesting() }
    }

    // MARK: - Scope and token

    @Test
    func workflowsScope_andRunToken() {
        #expect(InsightsScope.scope(containing: .workflowRun) == .workflows)
        #expect(InsightsScope.scope(containing: .workflowNode) == .workflows)

        var filter = ActivityFilter(workflowRunId: UUID())
        let tokens = ActivityFilterToken.tokens(for: filter)
        #expect(tokens.map(\.kind) == [.workflowRun])
        tokens.first?.remove(from: &filter)
        #expect(filter.workflowRunId == nil)
        #expect(filter.activeCount == 0)
    }
}
