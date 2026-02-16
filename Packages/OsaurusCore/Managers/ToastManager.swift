//
//  ToastManager.swift
//  osaurus
//
//  Centralized toast notification management with intelligent stacking,
//  independent timeouts, and agent support.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Manages toast notifications throughout the application
@MainActor
public final class ToastManager: ObservableObject {
    public static let shared = ToastManager()

    // MARK: - Published State

    /// Currently visible toasts (ordered by creation time, newest last)
    @Published public private(set) var toasts: [Toast] = []

    /// User configuration for toast behavior
    @Published public private(set) var configuration: ToastConfiguration

    // MARK: - Private State

    /// Timer tasks for auto-dismissing toasts
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    /// Action handlers registered for specific action IDs
    private var actionHandlers: [String: (ToastActionResult) -> Void] = [:]

    // MARK: - Initialization

    private init() {
        self.configuration = ToastConfigurationStore.load()
        print("[Osaurus] ToastManager initialized with position: \(configuration.position.displayName)")
    }

    // MARK: - Configuration

    /// Update toast configuration
    public func updateConfiguration(_ configuration: ToastConfiguration) {
        self.configuration = configuration
        ToastConfigurationStore.save(configuration)
        print("[Osaurus] Toast configuration updated: position=\(configuration.position.displayName)")
    }

    /// Update a single configuration property
    public func updatePosition(_ position: ToastPosition) {
        var newConfig = configuration
        newConfig.position = position
        updateConfiguration(newConfig)
    }

    // MARK: - Core API

    /// Show a toast notification
    /// - Parameter toast: The toast to display
    @discardableResult
    public func show(_ toast: Toast) -> UUID {
        guard configuration.enabled else {
            print("[Osaurus] Toast suppressed (disabled): \(toast.title)")
            return toast.id
        }

        // Add toast to the list
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toasts.append(toast)
        }

        // Enforce max visible limit (remove oldest non-loading toasts)
        enforceMaxVisible()

        // Schedule auto-dismiss if applicable
        scheduleAutoDismiss(for: toast)

        print("[Osaurus] Toast shown: \(toast.type.rawValue) - \(toast.title)")

        return toast.id
    }

    /// Dismiss a toast by ID
    /// - Parameter id: The toast ID to dismiss
    public func dismiss(id: UUID) {
        // Cancel any pending dismiss task
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)

        // Remove from list with animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toasts.removeAll { $0.id == id }
        }

        print("[Osaurus] Toast dismissed: \(id)")
    }

    /// Dismiss all toasts
    public func dismissAll() {
        // Cancel all dismiss tasks
        for (_, task) in dismissTasks {
            task.cancel()
        }
        dismissTasks.removeAll()

        // Remove all toasts with animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toasts.removeAll()
        }

        print("[Osaurus] All toasts dismissed")
    }

    /// Update an existing toast (useful for transitioning loading to success/error)
    /// - Parameters:
    ///   - id: The toast ID to update
    ///   - type: New toast type (optional)
    ///   - title: New title (optional)
    ///   - message: New message (optional)
    ///   - progress: New progress value (optional)
    public func update(
        id: UUID,
        type: ToastType? = nil,
        title: String? = nil,
        message: String? = nil,
        progress: Double? = nil
    ) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else {
            print("[Osaurus] Toast not found for update: \(id)")
            return
        }

        var toast = toasts[index]
        let oldType = toast.type

        if let type = type {
            toast.type = type
        }
        if let title = title {
            toast.title = title
        }
        if let message = message {
            toast.message = message
        }
        if let progress = progress {
            toast.progress = progress
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toasts[index] = toast
        }

        // If type changed from loading to something else, schedule auto-dismiss
        if oldType == .loading && toast.type != .loading {
            // Cancel existing task if any
            dismissTasks[id]?.cancel()
            dismissTasks.removeValue(forKey: id)

            // Schedule new dismiss
            scheduleAutoDismiss(for: toast)
        }

        print("[Osaurus] Toast updated: \(id) - \(toast.type.rawValue) - \(toast.title)")
    }

    // MARK: - Convenience Methods

    /// Show a success toast
    @discardableResult
    public func success(_ title: String, message: String? = nil, timeout: TimeInterval? = nil) -> UUID {
        show(Toast(type: .success, title: title, message: message, timeout: timeout))
    }

    /// Show an info toast
    @discardableResult
    public func info(_ title: String, message: String? = nil, timeout: TimeInterval? = nil) -> UUID {
        show(Toast(type: .info, title: title, message: message, timeout: timeout))
    }

    /// Show a warning toast
    @discardableResult
    public func warning(_ title: String, message: String? = nil, timeout: TimeInterval? = nil) -> UUID {
        show(Toast(type: .warning, title: title, message: message, timeout: timeout))
    }

    /// Show an error toast
    @discardableResult
    public func error(_ title: String, message: String? = nil, timeout: TimeInterval? = nil) -> UUID {
        show(Toast(type: .error, title: title, message: message, timeout: timeout))
    }

    /// Show a loading toast (does not auto-dismiss)
    @discardableResult
    public func loading(_ title: String, message: String? = nil, progress: Double? = nil) -> UUID {
        show(Toast(type: .loading, title: title, message: message, progress: progress))
    }

    /// Show an action toast with a button (legacy string-based actionId)
    @discardableResult
    public func action(
        _ title: String,
        message: String? = nil,
        actionTitle: String,
        actionId: String,
        timeout: TimeInterval? = nil
    ) -> UUID {
        show(
            Toast(
                type: .action,
                title: title,
                message: message,
                timeout: timeout,
                actionTitle: actionTitle,
                actionId: actionId
            )
        )
    }

    /// Show an action toast with a structured action
    @discardableResult
    public func action(
        _ title: String,
        message: String? = nil,
        action: ToastAction,
        buttonTitle: String? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        show(
            Toast(
                type: .action,
                title: title,
                message: message,
                timeout: timeout,
                actionTitle: buttonTitle ?? action.defaultButtonTitle,
                action: action
            )
        )
    }

    /// Show a toast with "Open Chat" action
    @discardableResult
    public func withOpenChatAction(
        _ type: ToastType = .info,
        title: String,
        message: String? = nil,
        agentId: UUID? = nil,
        avatarImageData: Data? = nil,
        buttonTitle: String = "Open Chat",
        timeout: TimeInterval? = nil
    ) -> UUID {
        show(
            Toast(
                type: .action,
                title: title,
                message: message,
                timeout: timeout,
                agentId: agentId,
                avatarImageData: avatarImageData,
                actionTitle: buttonTitle,
                action: .openChat(agentId: agentId)
            )
        )
    }

    // MARK: - Agent Support

    /// Show a toast with agent avatar
    @discardableResult
    public func showForAgent(
        _ type: ToastType,
        title: String,
        message: String? = nil,
        agentId: UUID,
        avatarImageData: Data? = nil,
        customThemeId: UUID? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        show(
            Toast(
                type: type,
                title: title,
                message: message,
                timeout: timeout,
                agentId: agentId,
                avatarImageData: avatarImageData,
                customThemeId: customThemeId
            )
        )
    }

    /// Show a loading toast for an agent task
    @discardableResult
    public func loadingForAgent(
        _ title: String,
        message: String? = nil,
        agentId: UUID,
        avatarImageData: Data? = nil,
        customThemeId: UUID? = nil,
        progress: Double? = nil
    ) -> UUID {
        show(
            Toast(
                type: .loading,
                title: title,
                message: message,
                agentId: agentId,
                avatarImageData: avatarImageData,
                customThemeId: customThemeId,
                progress: progress
            )
        )
    }

    // MARK: - Action Handlers

    /// Register an action handler for a specific action ID
    public func registerActionHandler(for actionId: String, handler: @escaping (ToastActionResult) -> Void) {
        actionHandlers[actionId] = handler
    }

    /// Unregister an action handler
    public func unregisterActionHandler(for actionId: String) {
        actionHandlers.removeValue(forKey: actionId)
    }

    /// Trigger an action (called by ToastView when action button is tapped)
    public func triggerAction(for toast: Toast) {
        // Get effective action ID
        guard let actionId = toast.effectiveActionId else { return }

        let result = ToastActionResult(toastId: toast.id, actionId: actionId)

        // Try to handle built-in actions first
        if let action = toast.action ?? ToastAction.from(actionId: actionId) {
            handleBuiltInAction(action)
        }

        // Call registered handler if any
        if let handler = actionHandlers[actionId] {
            handler(result)
        }

        // Also post notification for decoupled handling
        NotificationCenter.default.post(name: .toastActionTriggered, object: result)

        // Dismiss the toast after action
        dismiss(id: toast.id)
    }

    /// Handle built-in actions automatically
    private func handleBuiltInAction(_ action: ToastAction) {
        switch action {
        case .openChat(let agentId):
            // Open chat window with optional agent
            if let agentId = agentId {
                // Check if there's already a window for this agent
                if let existingWindow = ChatWindowManager.shared.findWindows(byAgentId: agentId).first {
                    ChatWindowManager.shared.showWindow(id: existingWindow.id)
                } else {
                    ChatWindowManager.shared.createWindow(agentId: agentId)
                }
            } else {
                ChatWindowManager.shared.createWindow()
            }

        case .openChatSession(let sessionId, let agentId):
            // Check if there's already a window with this session open
            if let existingWindow = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
                ChatWindowManager.shared.showWindow(id: existingWindow.id)
                return
            }

            // Open chat window with specific session
            if let sessionData = ChatSessionStore.load(id: sessionId) {
                let effectiveAgentId = agentId ?? sessionData.agentId
                ChatWindowManager.shared.createWindow(
                    agentId: effectiveAgentId,
                    sessionData: sessionData
                )
            } else {
                // Session not found, just open a new chat
                if let agentId = agentId {
                    ChatWindowManager.shared.createWindow(agentId: agentId)
                } else {
                    ChatWindowManager.shared.createWindow()
                }
                print("[ToastManager] Session \(sessionId) not found, opening new chat")
            }

        case .showChatWindow(let windowId):
            // Show an existing chat window
            ChatWindowManager.shared.showWindow(id: windowId)

        case .showExecutionContext(let contextId):
            // Lazily create a window from a dispatched execution context
            TaskDispatcher.shared.openWindow(for: contextId)

        case .openSettings(let tab):
            // Open settings window to specific tab
            if let tabName = tab, let managementTab = ManagementTab(rawValue: tabName) {
                AppDelegate.shared?.showManagementWindow(initialTab: managementTab)
            } else {
                AppDelegate.shared?.showManagementWindow()
            }

        case .openURL(let url):
            // Open URL in default browser
            NSWorkspace.shared.open(url)

        case .showMainWindow:
            // Show the main app window/popover
            AppDelegate.shared?.showPopover()

        case .custom:
            // Custom actions are handled by registered handlers
            break
        }
    }

    // MARK: - Private Helpers

    /// Schedule auto-dismiss for a toast
    private func scheduleAutoDismiss(for toast: Toast) {
        guard let timeout = toast.effectiveTimeout(defaultTimeout: configuration.defaultTimeout),
            timeout > 0
        else {
            return
        }

        let id = toast.id
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Dismiss the toast
            dismiss(id: id)
        }

        dismissTasks[id] = task
    }

    /// Enforce the maximum visible toasts limit
    private func enforceMaxVisible() {
        let maxVisible = configuration.maxVisibleToasts

        // Only enforce if we exceed the limit
        guard toasts.count > maxVisible else { return }

        // Find toasts that can be dismissed (non-loading, oldest first)
        let dismissableToasts = toasts.filter { $0.type != .loading }
        let excessCount = toasts.count - maxVisible

        // Dismiss the oldest dismissable toasts
        for toast in dismissableToasts.prefix(excessCount) {
            dismiss(id: toast.id)
        }
    }
}
