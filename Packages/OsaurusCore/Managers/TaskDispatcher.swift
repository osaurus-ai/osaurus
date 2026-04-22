//
//  TaskDispatcher.swift
//  osaurus
//
//  Thin dispatch orchestrator. Every trigger source (schedules,
//  shortcuts, plugins, HTTP, watchers) creates a DispatchRequest and
//  hands it here; we route to BackgroundTaskManager which runs it as
//  a headless chat session.
//

import Foundation

/// Routes dispatch requests to BackgroundTaskManager
@MainActor
public final class TaskDispatcher {
    public static let shared = TaskDispatcher()
    private init() {}

    /// Dispatch a request for background execution as a headless chat task.
    public func dispatch(_ request: DispatchRequest) async -> DispatchHandle? {
        await BackgroundTaskManager.shared.dispatchChat(request)
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
