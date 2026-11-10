//
//  TaskControl.swift
//  osaurus
//
//  The Tasks tab's actions: Stop routes to whichever owner runs the task
//  (an automation, background dispatch, a workflow run or a helper), and
//  Open goes to what the task produced. Stop is the only control a running
//  task has; it is journaled with who asked.
//

import Foundation

@MainActor
enum TaskControl {
    static var store: TaskStore { .shared }

    /// Whether Stop applies: the task has not finished and something live
    /// still owns it.
    static func canStop(_ task: OsaurusTask) -> Bool {
        guard !task.state.isTerminal else { return false }
        if EventManager.shared.hasLiveRun(task.id) { return true }
        switch task.work {
        case .agentTurn: return BackgroundTaskManager.shared.taskState(for: task.sessionId ?? task.id) != nil
        case .workflowRun: return task.workflowRunId != nil
        case .subagent(let work): return work.toolCallId != nil
        }
    }

    @discardableResult
    static func stop(_ task: OsaurusTask, actor: TaskActor = .user) -> Bool {
        guard !task.state.isTerminal else { return false }
        if EventManager.shared.stopTask(task.id, actor: actor) { return true }
        switch task.work {
        case .agentTurn:
            let backgroundId = task.sessionId ?? task.id
            guard BackgroundTaskManager.shared.taskState(for: backgroundId) != nil else { return false }
            store.journal(task.id, .cancelled, actor: actor, reason: "stopped")
            BackgroundTaskManager.shared.cancelTask(backgroundId)
            return true
        case .workflowRun:
            guard let runId = task.workflowRunId else { return false }
            store.journal(task.id, .cancelled, actor: actor, reason: "stopped")
            WorkflowRunService.shared.cancel(runId)
            return true
        case .subagent(let work):
            guard let toolCallId = work.toolCallId else { return false }
            store.journal(task.id, .cancelled, actor: actor, reason: "stopped")
            SubagentTaskRecorder.stopRequested.insert(task.id)
            return SubagentInterruptCenter.shared.interrupt(toolCallId)
        }
    }

    /// Opens the chat the task ran in.
    static func openSession(_ task: OsaurusTask) {
        guard let sessionId = task.sessionId else { return }
        openChat(sessionId, agentId: task.agentId)
    }

    /// Opens the chat whose turn started the task.
    static func openOriginChat(_ task: OsaurusTask) {
        guard let sessionId = task.originSessionId else { return }
        openChat(sessionId, agentId: nil)
    }

    /// Brings a chat session's window forward, or reopens it from history.
    static func openChat(_ sessionId: UUID, agentId: UUID?) {
        if let existing = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            ChatWindowManager.shared.showWindow(id: existing.id)
        } else if let data = ChatSessionStore.load(id: sessionId) {
            ChatWindowManager.shared.createWindow(agentId: agentId ?? data.agentId, sessionData: data)
        }
    }

    /// Opens Tasks → History narrowed by `filter`.
    static func showHistory(_ filter: TaskHistoryFilter) {
        ManagementStateManager.shared.pendingTaskHistory = filter
        showTasksTab()
    }

    /// Opens one task's detail on the Tasks tab.
    static func showDetail(_ taskId: UUID) {
        ManagementStateManager.shared.pendingTaskDetailId = taskId
        showTasksTab()
    }

    private static func showTasksTab() {
        if let app = AppDelegate.shared {
            app.showManagementWindow(initialTab: .tasks)
        } else {
            ManagementStateManager.shared.selectedTab = .tasks
        }
    }

    /// Opens the automation that started the task.
    static func openAutomation(_ task: OsaurusTask) {
        guard let eventId = task.subscriptionId else { return }
        let state = ManagementStateManager.shared
        state.pendingEventDetailId = eventId
        state.selectedTab = .automations
    }
}
