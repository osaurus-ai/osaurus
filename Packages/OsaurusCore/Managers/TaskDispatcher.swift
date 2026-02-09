//
//  TaskDispatcher.swift
//  osaurus
//
//  UI-aware dispatch orchestrator. For agent mode, delegates entirely to
//  BackgroundTaskManager (single owner of all backgrounded agent work).
//  For chat mode, manages ExecutionContext and simple toasts directly.
//  Trigger sources (schedules, shortcuts, etc.) create a DispatchRequest
//  and hand it here.
//

import Foundation

/// Dispatches tasks using ExecutionContext (chat) or BackgroundTaskManager (agent)
@MainActor
public final class TaskDispatcher {
    public static let shared = TaskDispatcher()

    // MARK: - State (chat-only)

    /// Active chat-mode execution contexts keyed by dispatch ID
    private var contexts: [UUID: ExecutionContext] = [:]

    /// Chat-mode loading toast IDs (dispatch ID -> toast ID)
    private var chatToasts: [UUID: UUID] = [:]

    private init() {}

    // MARK: - Dispatch

    /// Dispatch a request. Agent mode delegates to BackgroundTaskManager;
    /// chat mode creates an ExecutionContext and manages it locally.
    public func dispatch(_ request: DispatchRequest) async -> DispatchHandle? {
        switch request.mode {
        case .agent:
            return await BackgroundTaskManager.shared.dispatchAgent(request)

        case .chat:
            let personaId = request.personaId ?? Persona.defaultId

            let context = ExecutionContext(
                id: request.id,
                mode: .chat,
                personaId: personaId,
                title: request.title,
                folderBookmark: request.folderBookmark
            )
            contexts[request.id] = context

            await context.prepare()
            await context.start(prompt: request.prompt)

            if request.showToast {
                showChatLoadingToast(for: request)
            }

            print("[TaskDispatcher] Dispatched chat task: \(request.title ?? "untitled")")
            return DispatchHandle(id: request.id, request: request)
        }
    }

    /// Await completion of a dispatched task.
    public func awaitCompletion(_ handle: DispatchHandle) async -> DispatchResult {
        switch handle.request.mode {
        case .agent:
            return await BackgroundTaskManager.shared.awaitCompletion(handle.id)

        case .chat:
            guard let context = contexts[handle.id] else {
                return .failed("Execution context not found")
            }

            let result = await context.awaitCompletion()

            // Dismiss loading toast before showing result
            if let toastId = chatToasts.removeValue(forKey: handle.id) {
                ToastManager.shared.dismiss(id: toastId)
            }

            // Keep context alive so the result toast "View" action works
            scheduleContextCleanup(handle.id)

            return result
        }
    }

    /// Cancel a running dispatch.
    public func cancel(_ id: UUID) {
        // Try chat-mode first
        if let context = contexts.removeValue(forKey: id) {
            context.cancel()
            if let toastId = chatToasts.removeValue(forKey: id) {
                ToastManager.shared.dismiss(id: toastId)
            }
            print("[TaskDispatcher] Cancelled chat dispatch: \(id.uuidString)")
            return
        }

        // Otherwise delegate to BTM (agent mode)
        if BackgroundTaskManager.shared.isBackgroundTask(id) {
            BackgroundTaskManager.shared.cancelTask(id)
            print("[TaskDispatcher] Cancelled agent dispatch via BTM: \(id.uuidString)")
        }
    }

    // MARK: - Window Creation

    /// Lazily create a window from a dispatched execution context.
    /// Called when the user taps "View" on a toast.
    public func openWindow(for contextId: UUID) {
        // Chat-mode: context is stored locally
        if let context = contexts.removeValue(forKey: contextId) {
            ChatWindowManager.shared.createWindowForContext(context, showImmediately: true)
            return
        }

        // Agent-mode: BTM owns the context
        if BackgroundTaskManager.shared.isBackgroundTask(contextId) {
            BackgroundTaskManager.shared.openTaskWindow(contextId)
            return
        }

        print("[TaskDispatcher] No context found for id: \(contextId)")
    }

    // MARK: - Toast (chat-only)

    /// Show a loading toast for a chat-mode dispatch.
    private func showChatLoadingToast(for request: DispatchRequest) {
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

    /// Show a result toast for a chat-mode dispatch.
    /// Agent mode result toasts are handled by BackgroundTaskToastView.
    func showChatResultToast(for request: DispatchRequest, result: DispatchResult) {
        switch result {
        case .completed(let sessionId):
            // Use the sessionId from the result directly — the context may already
            // be cleaned up by the time the user taps "View".
            let action: ToastAction =
                if let sessionId {
                    .openChatSession(sessionId: sessionId, personaId: request.personaId)
                } else {
                    .showExecutionContext(contextId: request.id)
                }
            ToastManager.shared.action(
                "Completed \"\(request.title ?? "Task")\"",
                message: "Task finished successfully",
                action: action,
                buttonTitle: "View Chat",
                timeout: 0
            )
        case .failed(let error):
            ToastManager.shared.action(
                "Failed \"\(request.title ?? "Task")\"",
                message: error,
                action: .showExecutionContext(contextId: request.id),
                buttonTitle: "View",
                timeout: 0
            )
        case .cancelled:
            break
        }
    }

    // MARK: - Private

    /// Schedule deferred cleanup of a completed chat context.
    /// Keeps it alive for 5 minutes so the result toast "View" action still works.
    private func scheduleContextCleanup(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 min
            self.contexts.removeValue(forKey: id)
        }
    }
}
