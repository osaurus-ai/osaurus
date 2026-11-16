//
//  OrchestratorSessionTools.swift
//  osaurus
//
//  The Orchestrator's session tool, `status`: read-only. The resident
//  model, running and parked runs, and what is waiting on the user. The
//  session state object is the harness's (`SessionStateExtraction`).
//

import Foundation

// MARK: - status

final class StatusTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "status"
    let name = StatusTool.toolName
    let description =
        "What Osaurus is doing now: loaded model, workflow runs running or waiting on the user, "
        + "pending approvals, workflows `run_workflow` can run, shadowed workers, config version. "
        + "Changes nothing."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let resident = await ModelRuntime.shared.residentModelNames()
        let chatModel = ChatExecutionContext.currentModelName
        let sessionBox = ChatExecutionContext.currentChatSessionBox
        let snapshot = await MainActor.run { () -> (running: [[String: String]], parked: [[String: String]], approvals: [String: Int], runnable: [RoutableWorkflowDoc], shadowed: [AgentWrapperCatalog.Shadowed]) in
            let live = WorkflowRunStore.shared.live.values.sorted { $0.startedAt < $1.startedAt }
            let parked = sessionBox?.session?.parkedWorkflowCalls ?? []
            let parkedIDs = Set(parked.map(\.runID))
            func row(_ run: WorkflowRun) -> [String: String] {
                ["run_id": run.id.uuidString, "workflow": run.workflowName, "status": run.status.rawValue]
            }
            let parkedRows = parked.map { call -> [String: String] in
                if let run = WorkflowRunStore.shared.run(id: call.runID) { return row(run) }
                return ["run_id": call.runID.uuidString, "workflow": call.toolName, "status": "awaiting_user"]
            }
            let routable = RoutableWorkflowCatalog.listing()
            return (
                live.filter { !parkedIDs.contains($0.id) }.map(row),
                parkedRows,
                [
                    "settings_changes": ConfigApprovalQueue.shared.pending.count,
                    "tool_permissions": ToolPermissionPromptService.openPromptCount,
                    "browser_and_computer": ComputerUsePromptQueue.shared.pending.count,
                    "workflow_questions": live.filter { $0.status == .awaitingUser }.count,
                ],
                routable.docs,
                routable.shadowed
            )
        }
        var result: [String: Any] = [
            "running_runs": snapshot.running,
            "parked_runs": snapshot.parked,
            "pending_approvals": snapshot.approvals,
            "runnable_workflows": snapshot.runnable.map(Self.runnableRow),
        ]
        if !snapshot.shadowed.isEmpty { result["shadowed_workers"] = snapshot.shadowed.map(\.row) }
        if let version = await ConfigHistoryRecorder.latestSequence { result["configuration_version"] = version }
        result["loaded_models"] = resident
        if let chatModel { result["chat_model"] = chatModel }
        return ToolEnvelope.success(tool: name, result: result)
    }

    /// One `run_workflow` target: its name, what it does, and its inputs.
    static func runnableRow(_ doc: RoutableWorkflowDoc) -> [String: Any] {
        var row: [String: Any] = ["name": doc.name]
        if !doc.summary.isEmpty { row["summary"] = doc.summary }
        row["inputs"] = doc.inputs.map { input -> [String: Any] in
            ["name": input.name, "type": input.type, "required": input.required]
        }
        return row
    }
}
