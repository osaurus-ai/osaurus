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

    /// Brings a chat session forward: its tab, focused, where it's open; the run still working in it; or the
    /// chat reopened from history in a tab, as the sidebar's history does. Only bringing a window forward left
    /// a chat open in a background tab out of sight, and a chat still running with no window couldn't be opened.
    static func openChat(_ sessionId: UUID, agentId: UUID?) {
        let windows = ChatWindowManager.shared
        if windows.revealOpenSession(sessionId) != nil { return }
        if let task = BackgroundTaskManager.shared.liveTask(forSessionId: sessionId) {
            windows.revealTask(task.id)
            return
        }
        if var data = ChatSessionStore.load(id: sessionId) {
            if data.agentId == nil, let agentId { data.agentId = agentId }
            windows.openHistorySession(data)
            return
        }
        // Gone: deleted, or left with Delete Data. Said, rather than a button that does nothing.
        print("[TaskControl] openChat: chat \(sessionId) is neither open, running nor saved")
        _ = ToastManager.shared.info(
            L("This chat isn't on this Mac anymore"),
            message: L("It was deleted, or its data was removed.")
        )
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
