//
//  AttentionOpener.swift
//  osaurus
//
//  Opens the place an attention item lives: its chat, task window,
//  workflow run or agent view. A request with nowhere else to go opens
//  Approvals; a message or notice opens its Insights row.
//

import Foundation

@MainActor
enum AttentionOpener {
    static func open(_ item: AttentionItem) {
        guard let link = item.effectiveLink else {
            showFallback(item)
            return
        }
        switch link {
        case .task(let taskId):
            if BackgroundTaskManager.shared.taskState(for: taskId) != nil {
                BackgroundTaskManager.shared.openTaskWindowIfPresent(taskId)
            } else {
                openSession(taskId, item: item)
            }
        case .session(let sessionId):
            if BackgroundTaskManager.shared.taskState(for: sessionId) != nil {
                BackgroundTaskManager.shared.openTaskWindowIfPresent(sessionId)
            } else {
                openSession(sessionId, item: item)
            }
        case .workflowRun(let runID):
            WorkflowRunLauncher.open(runID: runID)
        case .agentDetail(let agentId, let viewRef):
            AppDelegate.shared?.showAgentDetail(agentId: agentId, tab: "views", viewRef: viewRef)
        }
    }

    private static func openSession(_ sessionId: UUID, item: AttentionItem) {
        if let window = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            ChatWindowManager.shared.showWindow(id: window.id)
        } else if let data = ChatSessionStore.load(id: sessionId) {
            ChatWindowManager.shared.createWindow(agentId: item.agentId ?? data.agentId, sessionData: data)
        } else {
            showFallback(item)
        }
    }

    private static func showFallback(_ item: AttentionItem) {
        if item.kind.isBlocking {
            AppDelegate.shared?.showManagementWindow(initialTab: .approvals)
        } else {
            InsightsService.shared.showInteraction(attentionId: item.id)
            AppDelegate.shared?.showManagementWindow(initialTab: .insights)
        }
    }
}
