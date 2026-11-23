//
//  WorkflowLocalAPI.swift
//  osaurus
//
//  Bodies of the owner's workflow routes that `osaurus workflow` and
//  `osaurus mcp --workflows` use: `GET /workflows`, `GET /workflows/runs`
//  and `POST /workflows/runs/{id}/cancel`. Starting a run is
//  `WorkflowLocalStart`; one run's state and answering its form are in
//  `DialogCoordinator`.
//

import Foundation

@MainActor
enum WorkflowLocalAPI {
    static let defaultRunsLimit = 20
    static let maximumRunsLimit = 200

    /// `GET /workflows`: every installed workflow with what a caller needs
    /// to start it.
    static func listJSON(
        workflows: [InstalledWorkflow] = InstalledWorkflowStore.shared.workflows,
        report: (InstalledWorkflow) -> SetupReport = { SetupChecker.check($0, secrets: .caller(nil), attended: false) }
    ) -> String {
        let items: [JSONValue] = workflows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { workflow in
                let setup = report(workflow)
                var object: [String: JSONValue] = [
                    "id": .string(workflow.id.uuidString),
                    "name": .string(workflow.name),
                    "tool_name": .string(workflow.toolName),
                    "input_schema": workflow.definition.inputSchema,
                    "needs_setup": .bool(setup.hasBlockers),
                ]
                if let summary = workflow.summary, !summary.isEmpty { object["summary"] = .string(summary) }
                if setup.hasBlockers { object["setup_summary"] = .string(setup.summary) }
                return .object(object)
            }
        return JSONValue.object(["workflows": .array(items)]).compactJSONString
    }

    enum RunsFailure: Error, Equatable {
        case workflowNotFound
    }

    /// `GET /workflows/runs?workflow=&limit=`: newest first, test runs left
    /// out. `workflow` is an id, display name or tool name.
    static func runsJSON(workflow: String?, limit: Int?) async -> Result<String, RunsFailure> {
        let limit = min(max(limit ?? defaultRunsLimit, 1), maximumRunsLimit)
        let runs: [WorkflowRun]
        if let workflow = workflow?.trimmingCharacters(in: .whitespacesAndNewlines), !workflow.isEmpty {
            guard let installed = InstalledWorkflowStore.shared.workflow(named: workflow) else {
                return .failure(.workflowNotFound)
            }
            runs = WorkflowRunStore.shared.runs(workflowID: installed.id, limit: limit, includeTests: false)
        } else {
            await WorkflowRunStore.shared.loadRecentRunsIfNeeded()
            runs = WorkflowRunStore.shared.recentRuns(limit: limit)
        }
        return .success(JSONValue.object(["runs": .array(runs.map(summary))]).compactJSONString)
    }

    static func summary(_ run: WorkflowRun) -> JSONValue {
        var object: [String: JSONValue] = [
            "run_id": .string(run.id.uuidString),
            "workflow_id": .string(run.workflowID.uuidString),
            "workflow_name": .string(run.workflowName),
            "status": .string(run.status.rawValue),
            "started_by": .string(run.caller.kind.rawValue),
            "started_at": .string(Template.iso8601.string(from: run.startedAt)),
        ]
        if let finishedAt = run.finishedAt { object["finished_at"] = .string(Template.iso8601.string(from: finishedAt)) }
        if let error = run.error { object["error"] = .string(error.reason) }
        return .object(object)
    }

    enum CancelOutcome: Equatable {
        case cancelled
        case notFound
        case alreadyFinished(WorkflowRunStatus)
    }

    /// `POST /workflows/runs/{id}/cancel`.
    static func cancel(
        runID: UUID,
        run: (UUID) -> WorkflowRun? = { WorkflowRunStore.shared.run(id: $0) },
        isActive: (UUID) -> Bool = { WorkflowRunService.shared.isActive($0) },
        cancel: (UUID) -> Void = { WorkflowRunService.shared.cancel($0) }
    ) -> CancelOutcome {
        guard let record = run(runID) else { return .notFound }
        guard isActive(runID), !record.status.isTerminal else { return .alreadyFinished(record.status) }
        cancel(runID)
        return .cancelled
    }
}
