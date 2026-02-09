//
//  TaskDispatcher.swift
//  osaurus
//
//  UI-aware dispatch orchestrator that creates ExecutionContexts and manages
//  toast notifications. Trigger sources (schedules, shortcuts, etc.) create
//  a DispatchRequest and hand it here. Headless callers (webhooks) can use
//  ExecutionContext directly.
//

import Foundation

/// Dispatches tasks using ExecutionContext and manages toast lifecycle
@MainActor
public final class TaskDispatcher {
    public static let shared = TaskDispatcher()

    // MARK: - State

    /// Active execution contexts keyed by dispatch ID
    private var contexts: [UUID: ExecutionContext] = [:]

    /// Chat-mode loading toast IDs (dispatch ID -> toast ID)
    private var chatToasts: [UUID: UUID] = [:]

    private init() {}

    // MARK: - Dispatch

    /// Dispatch a request: creates an ExecutionContext, starts execution, returns a handle.
    public func dispatch(_ request: DispatchRequest) async -> DispatchHandle? {
        let personaId = request.personaId ?? Persona.defaultId

        let context = ExecutionContext(
            id: request.id,
            mode: request.mode,
            personaId: personaId,
            title: request.title
        )
        contexts[request.id] = context

        await context.prepare()
        await context.start(prompt: request.prompt)

        if request.showToast {
            showLoadingToast(for: request, context: context)
        }

        print("[TaskDispatcher] Dispatched \(request.mode.displayName) task: \(request.title ?? "untitled")")
        return DispatchHandle(id: request.id, windowId: nil, request: request)
    }

    /// Await completion of a dispatched task.
    public func awaitCompletion(_ handle: DispatchHandle) async -> DispatchResult {
        guard let context = contexts[handle.id] else {
            return .failed("Execution context not found")
        }

        let result = await context.awaitCompletion()

        // Dismiss the chat loading toast before the result toast appears
        if let toastId = chatToasts.removeValue(forKey: handle.id) {
            ToastManager.shared.dismiss(id: toastId)
        }

        // Context stays alive for the result toast "View" action.
        // Cleaned up when the user opens the window or after timeout.
        scheduleContextCleanup(handle.id)

        return result
    }

    /// Cancel a running dispatch.
    public func cancel(_ id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }

        context.cancel()

        if let toastId = chatToasts.removeValue(forKey: id) {
            ToastManager.shared.dismiss(id: toastId)
        }
        if context.mode == .agent {
            BackgroundTaskManager.shared.cancelTask(context.id)
        }

        print("[TaskDispatcher] Cancelled dispatch: \(id.uuidString)")
    }

    // MARK: - Window Creation

    /// Lazily create a window from a dispatched execution context.
    /// Called when the user taps "View" on a toast.
    public func openWindow(for contextId: UUID) {
        if let context = contexts.removeValue(forKey: contextId) {
            ChatWindowManager.shared.createWindowForContext(context, showImmediately: true)
            return
        }
        if BackgroundTaskManager.shared.isBackgroundTask(contextId) {
            BackgroundTaskManager.shared.openTaskWindow(contextId)
            return
        }
        print("[TaskDispatcher] No context found for id: \(contextId)")
    }

    // MARK: - Toast

    /// Show a loading toast while execution is in progress.
    private func showLoadingToast(for request: DispatchRequest, context: ExecutionContext) {
        switch request.mode {
        case .agent:
            BackgroundTaskManager.shared.registerContext(context)

        case .chat:
            let toast = Toast(
                type: .loading,
                title: "Running \"\(request.title ?? "Task")\"",
                message: "Tap to view progress...",
                personaId: request.personaId,
                actionTitle: "View",
                action: .showExecutionContext(contextId: request.id)
            )
            chatToasts[request.id] = ToastManager.shared.show(toast)
        }
    }

    /// Show a result toast after execution completes.
    /// Prefers persisted session for the action so it works even after context cleanup.
    func showResultToast(for request: DispatchRequest, result: DispatchResult) {
        let action = resolveResultAction(for: request)

        switch result {
        case .completed:
            let buttonTitle = request.mode == .agent ? "View Agent" : "View Chat"
            ToastManager.shared.action(
                "Completed \"\(request.title ?? "Task")\"",
                message: "Task finished successfully",
                action: action,
                buttonTitle: buttonTitle,
                timeout: 0
            )
        case .failed(let error):
            ToastManager.shared.action(
                "Failed \"\(request.title ?? "Task")\"",
                message: error,
                action: action,
                buttonTitle: "View",
                timeout: 0
            )
        case .cancelled:
            break
        }
    }

    // MARK: - Private

    /// Resolve the best toast action for a completed task.
    /// Uses persisted session when available, falls back to in-memory context.
    private func resolveResultAction(for request: DispatchRequest) -> ToastAction {
        if let sessionId = contexts[request.id]?.chatSession.sessionId {
            return .openChatSession(sessionId: sessionId, personaId: request.personaId)
        }
        return .showExecutionContext(contextId: request.id)
    }

    /// Schedule deferred cleanup of a completed context.
    /// Keeps it alive for 5 minutes so the result toast "View" action still works.
    private func scheduleContextCleanup(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 min
            self.contexts.removeValue(forKey: id)
        }
    }
}
