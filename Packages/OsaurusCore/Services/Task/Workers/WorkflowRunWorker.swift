//
//  WorkflowRunWorker.swift
//  osaurus
//
//  Runs an automation's workflow: maps the occurrence to the workflow's
//  input, starts the run through `WorkflowRunService`, and waits until it
//  settles or parks on a form.
//

import Foundation

@MainActor
enum WorkflowRunWorker: TaskWorker {
    /// The input a workflow event hands its workflow, or the reason it
    /// cannot run.
    /// `agentId` is the automation's Run as agent, whose keys override the
    /// shared ones; nil checks the shared keys only.
    static func workflowInput(
        _ action: WorkflowEventAction, payload: JSONValue, agentId: UUID? = nil
    ) -> Result<(InstalledWorkflow, JSONValue), TaskOutcome> {
        guard let workflow = InstalledWorkflowStore.shared.workflow(id: action.workflowID) else {
            return .failure(TaskOutcome(status: .suppressed, reason: "workflow_unavailable"))
        }
        let report = SetupChecker.check(workflow, secrets: .caller(agentId))
        guard report.blocking.isEmpty else {
            let keysOnly = SetupChecker.onlyKeysMissing(report)
            if !keysOnly { InstalledWorkflowStore.shared.setNeedsSetup(true, id: workflow.id) }
            return .failure(
                TaskOutcome(
                    status: .failed,
                    error: (keysOnly ? L("The workflow is missing keys: ") : L("The workflow needs setup: "))
                        + report.blocking.map { "\($0.title): \($0.detail)" }.joined(separator: "; "),
                    reason: keysOnly ? "workflow_missing_keys" : "workflow_needs_setup"))
        }
        let schema = workflow.definition.inputSchema
        let input = WorkflowInputMapper.input(mapping: action.inputMapping, payload: payload, schema: schema)
        let issues = JSONSchemaValidator.validate(input, against: schema)
        guard issues.isEmpty else {
            return .failure(
                TaskOutcome(
                    status: .failed,
                    error: L("The automation's input does not fit the workflow: ")
                        + issues.map(\.description).joined(separator: "; "),
                    reason: "invalid_input"))
        }
        return .success((workflow, input))
    }

    static func workflowCaller(event: OsaurusEvent, occurrence: EventOccurrence, taskId: UUID? = nil)
        -> WorkflowCaller
    {
        var caller = WorkflowCaller(
            kind: .event,
            background: true,
            isExternalSurface: occurrence.isExternal,
            // Unattended unlocks narrow auto-approvals; never for a caller
            // outside the app, and not for a hand-pressed Fire now.
            isUnattendedDispatch: !occurrence.isExternal && occurrence.trigger == .source,
            folderPath: occurrence.folderPath,
            eventID: event.id,
            eventName: event.name,
            channelReply: occurrence.channelReplyTarget
        )
        caller.taskId = taskId
        // The Run as agent when the automation has one; otherwise the run
        // uses the keys shared by all agents.
        if let agentId = event.action.workflow?.runAsAgentId {
            caller.agentID = agentId
            caller.agentName = AgentManager.shared.agent(for: agentId)?.name
        }
        return caller
    }

    static func run(taskId: UUID, input: AutomationWorkInput, onStarted: TaskStartedHandler) async -> TaskOutcome {
        let event = input.event
        let occurrence = input.occurrence
        guard case .workflow(let action) = event.action else {
            return TaskOutcome(status: .suppressed, reason: "not_a_workflow_action")
        }
        let workflow: InstalledWorkflow
        let workflowInput: JSONValue
        switch self.workflowInput(action, payload: occurrence.payload, agentId: action.runAsAgentId) {
        case .failure(let outcome): return outcome
        case .success(let value): (workflow, workflowInput) = value
        }
        let runID = UUID()
        if let sink = occurrence.replySink, let target = occurrence.channelReplyTarget {
            ChannelReplyRegistry.shared.register(runID: runID, target: target, sink: sink)
        }
        WorkflowRunService.shared.start(
            workflow, input: workflowInput,
            caller: workflowCaller(event: event, occurrence: occurrence, taskId: taskId), runID: runID)
        onStarted(nil, runID)
        let run = await WorkflowRunService.shared.settledOrParked(runID)
        return outcome(of: run, runID: runID)
    }

    static func outcome(of run: WorkflowRun?, runID: UUID) -> TaskOutcome {
        guard let run else {
            return TaskOutcome(status: .failed, workflowRunId: runID, error: L("The workflow run was lost."))
        }
        switch run.status {
        case .completed:
            return TaskOutcome(status: .succeeded, workflowRunId: runID)
        case .awaitingUser:
            return TaskOutcome(status: .waitingUser, workflowRunId: runID)
        case .running:
            return TaskOutcome(status: .running, workflowRunId: runID)
        case .cancelled:
            return TaskOutcome(status: .cancelled, workflowRunId: runID)
        case .failed, .needsSetup:
            let reason = run.error.map { e in e.nodeID.map { "[\($0)] \(e.reason)" } ?? e.reason }
            return TaskOutcome(
                status: .failed, workflowRunId: runID, error: reason ?? L("The workflow run failed."))
        }
    }

    /// The text a workflow's output replies with: a string output as is; an
    /// object's `reply` / `message` / `text` / `answer` / `summary` string,
    /// or its only string field; otherwise the output as JSON.
    static func replyText(from output: JSONValue?) -> String? {
        guard let output else { return nil }
        switch output {
        case .null: return nil
        case .string(let text): return text.isEmpty ? nil : text
        case .object(let fields):
            for key in ["reply", "message", "text", "answer", "summary", "response", "result"] {
                if let text = fields[key]?.stringValue, !text.isEmpty { return text }
            }
            let strings = fields.values.compactMap(\.stringValue).filter { !$0.isEmpty }
            if strings.count == 1 { return strings[0] }
            return output.prettyJSONString
        default:
            return EventTemplate.text(of: output)
        }
    }
}
