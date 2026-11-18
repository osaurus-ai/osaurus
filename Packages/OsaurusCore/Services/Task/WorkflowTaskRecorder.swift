//
//  WorkflowTaskRecorder.swift
//  osaurus
//
//  Every workflow run is a task. A run an automation started is already
//  its automation's task (`caller.taskId`): the recorder only links the run
//  to it. Any other run (a tab, an agent's tool, the Orchestrator, a
//  `workflow` step, a retry) is recorded as its own task on the Default
//  queue, with the run id as the task id. Architect test runs are not
//  recorded: they are not what the workflow did for anyone.
//

import Foundation

@MainActor
enum WorkflowTaskRecorder {
    static var store: TaskStore = .shared

    static func began(_ request: WorkflowRunner.Request, resuming: Bool) {
        let caller = request.caller
        guard caller.kind != .test else { return }
        if let owner = caller.taskId {
            store.update(owner) { $0.workflowRunId = request.runID }
            store.journal(owner, .leased, actor: .system("workflows"), data: ["workflow_run_id": request.runID.uuidString])
            return
        }
        if resuming, let existing = store.task(id: request.runID) {
            store.transition(existing.id, to: .running, kind: .resumed, actor: .system("launch"))
            return
        }
        let parent = caller.parentRunID ?? ChatExecutionContext.currentTaskId
        let parentTask = parent.flatMap { store.task(id: $0) }
        var task = OsaurusTask(
            id: request.runID,
            title: request.workflowName,
            rootId: parentTask?.rootId,
            parentId: parent,
            depth: (parentTask?.depth ?? -1) + 1,
            origin: origin(for: caller),
            createdBy: actor(for: caller),
            work: .workflowRun(WorkflowRunWork(workflowID: request.workflowID, callerKind: caller.kind.rawValue)),
            state: .running)
        task.workflowRunId = request.runID
        if let session = caller.sessionID, let id = UUID(uuidString: session) { task.sessionId = id }
        task.originSessionId = OsaurusTask.originSessionId(
            parent: parentTask, interactive: ChatExecutionContext.interactiveSessionId)
        task.transition(to: .running)
        task.lease = TaskLease(owner: "workflow")
        store.record(task, event: TaskEvent(taskId: task.id, kind: .started, actor: task.createdBy))
        if let parent, parentTask != nil {
            store.journal(parent, .childSpawned, actor: task.createdBy, data: ["task_id": task.id.uuidString])
        }
    }

    static func observed(_ run: WorkflowRun) {
        guard !run.isTest, run.caller.taskId == nil, let task = store.task(id: run.id) else { return }
        let next = TaskState(run.status)
        if next == .waitingUser, task.state != .waitingUser {
            store.transition(run.id, to: .waitingUser, kind: .waitingUser, actor: .system("workflows"))
        } else if next == .running, task.state == .waitingUser {
            store.transition(run.id, to: .running, kind: .resumed, actor: .system("workflows"))
        } else if next == .running {
            store.heartbeat(run.id, owner: "workflow", note: progressNote(run))
        }
    }

    /// The runner bounds every node with its timeout, so a run whose task is
    /// still executing is working even through a silent step (a cold model
    /// load, a long script). Keeps its task's lease current; an automation's
    /// run renews the automation's task.
    static func alive(runID: UUID, ownerTaskId: UUID?) {
        let id = ownerTaskId ?? runID
        guard store.task(id: id)?.state == .running else { return }
        store.heartbeat(id, owner: "workflow")
    }

    static func finished(_ run: WorkflowRun) {
        guard !run.isTest, run.caller.taskId == nil, store.task(id: run.id) != nil else { return }
        let state = TaskState(run.status)
        let error = run.error.map { e in e.nodeID.map { "[\($0)] \(e.reason)" } ?? e.reason }
        store.transition(
            run.id, to: state.isTerminal ? state : .interrupted,
            kind: state == .cancelled ? .cancelled : .finished, actor: .system("workflows"), reason: error
        ) { task in
            task.lastError = state == .failed ? error : nil
            task.result = TaskResult(
                summary: state == .succeeded ? L("Finished") : error,
                producedIds: [run.id.uuidString] + run.artifacts.map(\.id))
        }
    }

    private static func progressNote(_ run: WorkflowRun) -> String? {
        let done = run.nodes.filter { $0.status == .done || $0.status == .skipped || $0.status == .pinned }.count
        guard !run.nodes.isEmpty else { return nil }
        return L("Step \(min(done + 1, run.nodes.count)) of \(run.nodes.count)")
    }

    private static func origin(for caller: WorkflowCaller) -> TaskOrigin {
        switch caller.kind {
        case .agent, .orchestrator: .workflowStep
        case .workflow: .workflowStep
        case .event: .automation
        case .user, .test: .manual
        }
    }

    private static func actor(for caller: WorkflowCaller) -> TaskActor {
        if let agent = caller.agentID { return .agent(agent) }
        switch caller.kind {
        case .event: return .system("automations")
        case .workflow: return caller.parentRunID.map { .workflow($0) } ?? .user
        default: return .user
        }
    }
}
