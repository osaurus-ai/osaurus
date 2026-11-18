//
//  SubagentTaskRecorder.swift
//  osaurus
//
//  Shadow record of subagent runs (spawn, image, computer use): each run
//  is a `subagent` task under the task that launched it, journaled from
//  start to finish. Admission stays with `SubagentAdmission`; nothing here
//  changes how a subagent runs.
//

import Foundation

@MainActor
enum SubagentTaskRecorder {
    static var store: TaskStore = .shared
    /// Subagent tasks the user stopped from the Tasks tab, so their error
    /// envelope settles as Stopped rather than Failed.
    static var stopRequested: Set<UUID> = []

    /// Off the main actor: records on it without making the run wait, so
    /// recording never reorders subagent admission.
    nonisolated static func record(title: String, scope: SubagentScope, model: String?) -> UUID {
        let id = UUID()
        let parentId = ChatExecutionContext.currentTaskId
        let chat = ChatExecutionContext.interactiveSessionId
        Task { @MainActor in
            began(id: id, parentId: parentId, chat: chat, title: title, scope: scope, model: model)
        }
        return id
    }

    nonisolated static func recordFinished(_ id: UUID, envelope: String, interrupted: Bool) {
        Task { @MainActor in finished(id, envelope: envelope, interrupted: interrupted) }
    }

    @discardableResult
    static func began(
        id: UUID = UUID(), parentId: UUID? = ChatExecutionContext.currentTaskId,
        chat: UUID? = ChatExecutionContext.interactiveSessionId, title: String, scope: SubagentScope, model: String?
    ) -> UUID {
        let parent = parentId.flatMap { store.task(id: $0) }
        var task = OsaurusTask(
            id: id,
            title: title,
            rootId: parent?.rootId,
            parentId: parent?.id,
            depth: (parent?.depth ?? -1) + 1,
            queueId: parent?.queueId ?? TaskQueue.defaultID,
            origin: .spawn,
            createdBy: .agent(scope.agentId),
            work: .subagent(
                SubagentWork(
                    agentId: scope.agentId, parentSessionId: scope.sessionId, toolCallId: scope.toolCallId,
                    model: model)))
        task.sessionId = UUID(uuidString: scope.sessionId)
        task.originSessionId = OsaurusTask.originSessionId(parent: parent, interactive: chat)
        task.transition(to: .running)
        store.record(task, event: TaskEvent(taskId: task.id, kind: .started, actor: task.createdBy))
        if let parent {
            store.journal(parent.id, .childSpawned, actor: task.createdBy, data: ["task_id": task.id.uuidString])
        }
        return task.id
    }

    static func finished(_ id: UUID, envelope: String, interrupted: Bool) {
        let stopped = stopRequested.remove(id) != nil || interrupted
        let succeeded = !ToolEnvelope.isError(envelope)
        let state: TaskState = succeeded ? .succeeded : stopped ? .cancelled : .failed
        let error = succeeded ? nil : ToolEnvelope.failureMessage(envelope)
        store.transition(
            id, to: state, kind: state == .cancelled ? .cancelled : .finished, actor: .system("subagents"),
            reason: error
        ) { task in
            task.lastError = state == .failed ? error : nil
            task.result = TaskResult(summary: succeeded ? L("Finished") : error)
        }
    }
}
