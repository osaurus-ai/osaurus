//
//  TaskDispatcher.swift
//  osaurus
//
//  Thin dispatch orchestrator. Delegates to BackgroundTaskManager
//  (single owner of all backgrounded work) for both chat and agent modes.
//  Trigger sources (schedules, shortcuts, etc.) create a DispatchRequest
//  and hand it here.
//

import Foundation

/// Routes dispatch requests to BackgroundTaskManager
@MainActor
public final class TaskDispatcher {
    public static let shared = TaskDispatcher()
    private init() {}

    /// Dispatch a request for background execution.
    public func dispatch(_ request: DispatchRequest) async -> DispatchHandle? {
        let btm = BackgroundTaskManager.shared
        switch request.mode {
        case .agent: return await btm.dispatchAgent(request)
        case .chat: return await btm.dispatchChat(request)
        }
    }

    /// Await completion of a dispatched task.
    public func awaitCompletion(_ handle: DispatchHandle) async -> DispatchResult {
        await BackgroundTaskManager.shared.awaitCompletion(handle.id)
    }

    /// Cancel a running dispatch.
    public func cancel(_ id: UUID) {
        guard BackgroundTaskManager.shared.isBackgroundTask(id) else { return }
        BackgroundTaskManager.shared.cancelTask(id)
    }

    /// Lazily create a window from a dispatched execution context.
    /// Called from ToastManager when the user taps a toast action.
    public func openWindow(for contextId: UUID) {
        guard BackgroundTaskManager.shared.isBackgroundTask(contextId) else { return }
        BackgroundTaskManager.shared.openTaskWindow(contextId)
    }
}
