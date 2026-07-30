//
//  ToolPermissionPromptService.swift
//  osaurus
//
//  Presents a modern confirmation dialog when a tool requires user approval.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
enum ToolPermissionPromptService {
    private static var permissionWindow: NSPanel?
    private static var localKeyMonitor: Any?
    private static var closeObserver: NSObjectProtocol?
    /// Identity + cancellation hook for the currently presented policy prompt.
    /// The id prevents a delayed task-cancellation callback from dismissing a
    /// newer prompt that happened to open after the cancelled one completed.
    private static var pendingPolicyPrompt: (id: UUID, cancel: () -> Void)?

    enum PolicyApprovalOutcome: Sendable, Equatable {
        case denied
        case allowOnce
        case alwaysAllow
    }

    static func requestApproval(
        toolName: String,
        description: String,
        argumentsJSON: String
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            var hasResumed = false

            let onAllow = {
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: true)
            }

            let onDeny = {
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: false)
            }

            let onAlwaysAllow = {
                guard !hasResumed else { return }
                hasResumed = true
                // Set the policy to auto so it won't prompt again
                ToolRegistry.shared.setPolicy(.auto, for: toolName)
                dismissWindow()
                continuation.resume(returning: true)
            }

            let themeManager = ThemeManager.shared
            let permissionView = ToolPermissionView(
                toolName: toolName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "This action requires your approval."
                    : description,
                argumentsJSON: argumentsJSON,
                onAllow: onAllow,
                onDeny: onDeny,
                onAlwaysAllow: onAlwaysAllow
            )
            .environment(\.theme, themeManager.currentTheme)
            presentPanel(view: permissionView, onAllow: onAllow, onDeny: onDeny)
        }
    }

    /// Approval prompt for a caller-owned policy. Unlike `requestApproval`,
    /// choosing "Always Allow" does NOT mutate `ToolRegistry`: the caller owns
    /// the policy namespace and persists that outcome in its own store.
    ///
    /// Cancellation is terminal and denial-shaped. This is required by spawn
    /// preparation, where the feed's Stop control can fire while the panel is
    /// open; the continuation must be resumed and the modal dismissed rather
    /// than stranding the tool call.
    static func requestPolicyApproval(
        toolName: String,
        description: String,
        argumentsJSON: String
    ) async -> PolicyApprovalOutcome {
        if Task.isCancelled { return .denied }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var hasResumed = false

                let finish: (PolicyApprovalOutcome) -> Void = { outcome in
                    guard !hasResumed else { return }
                    hasResumed = true
                    if pendingPolicyPrompt?.id == requestID {
                        pendingPolicyPrompt = nil
                    }
                    dismissWindow()
                    continuation.resume(returning: outcome)
                }
                let onAllow = { finish(.allowOnce) }
                let onDeny = { finish(.denied) }
                let onAlwaysAllow = { finish(.alwaysAllow) }

                pendingPolicyPrompt = (id: requestID, cancel: onDeny)

                let themeManager = ThemeManager.shared
                let permissionView = ToolPermissionView(
                    toolName: toolName,
                    description:
                        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "This action requires your approval."
                        : description,
                    argumentsJSON: argumentsJSON,
                    onAllow: onAllow,
                    onDeny: onDeny,
                    onAlwaysAllow: onAlwaysAllow
                )
                .environment(\.theme, themeManager.currentTheme)

                presentPanel(
                    view: permissionView,
                    onAllow: onAllow,
                    onDeny: onDeny
                )

                // Cancellation can race the MainActor hop into this
                // continuation. Re-check after the cancellation hook exists.
                if Task.isCancelled {
                    onDeny()
                }
            }
        } onCancel: {
            Task { @MainActor in
                cancelPolicyPrompt(id: requestID)
            }
        }
    }

    /// Outcome of the first-use spawn permission prompt: the decision plus the
    /// spawn model the user picked (nil when no picker was shown).
    enum SpawnApprovalOutcome: Sendable {
        case denied
        case allowed(model: String?, always: Bool)
    }

    /// First-use permission prompt for a spawn job that ALSO lets the user pick
    /// the spawn model (image or text) in the same dialog. Returns the decision
    /// and the chosen model so the caller can persist both. Presented with the
    /// same panel chrome as `requestApproval`.
    static func requestSpawnApproval(
        toolName: String,
        description: String,
        argumentsJSON: String,
        modelPickerTitle: String,
        modelOptions: [SpawnModelChoice],
        currentModel: String?
    ) async -> SpawnApprovalOutcome {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            var chosenModel: String? = currentModel ?? modelOptions.first?.id

            let finish: (SpawnApprovalOutcome) -> Void = { outcome in
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: outcome)
            }
            let onAllow = { finish(.allowed(model: chosenModel, always: false)) }
            let onDeny = { finish(.denied) }
            let onAlwaysAllow = {
                ToolRegistry.shared.setPolicy(.auto, for: toolName)
                finish(.allowed(model: chosenModel, always: true))
            }
            let onModelSelected: (String) -> Void = { chosenModel = $0 }

            let themeManager = ThemeManager.shared
            let view = ToolPermissionView(
                toolName: toolName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "This action requires your approval." : description,
                argumentsJSON: argumentsJSON,
                onAllow: onAllow,
                onDeny: onDeny,
                onAlwaysAllow: onAlwaysAllow,
                spawnModelTitle: modelPickerTitle,
                spawnModelOptions: modelOptions,
                initialSpawnModel: chosenModel,
                onModelSelected: onModelSelected
            )
            .environment(\.theme, themeManager.currentTheme)

            presentPanel(view: view, onAllow: onAllow, onDeny: onDeny)
        }
    }

    /// Shared panel presentation used by `requestSpawnApproval` (and reusable by
    /// future prompts). Centers a borderless modal panel hosting `view`, wires
    /// Enter→allow / Esc→deny key handling, and a close-safety-net that denies.
    private static func presentPanel<V: View>(
        view: V,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        let hostingController = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Tool Permission")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .alertPanel
        panel.contentViewController = hostingController

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        var windowSize = NSSize(
            width: max(fittingSize.width, 480),
            height: max(fittingSize.height, 300)
        )
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        }
        // Keep the decision on the launching app window's display. Falling
        // back to the mouse display can make a security prompt appear on a
        // different monitor than the chat that is visibly blocked on it.
        let targetScreen = preferredPresentationCandidate(
            keyWindow: NSApp.keyWindow?.screen,
            mainWindow: NSApp.mainWindow?.screen,
            mouse: mouseScreen,
            fallback: NSScreen.main
        )
        if let screen = targetScreen {
            let vf = screen.visibleFrame
            // The approval buttons must stay reachable: never size the panel
            // taller (or wider) than the visible screen area.
            windowSize = clampedWindowSize(windowSize, to: vf.size)
            panel.setFrame(
                NSRect(
                    x: vf.origin.x + (vf.width - windowSize.width) / 2,
                    y: vf.origin.y + (vf.height - windowSize.height) / 2,
                    width: windowSize.width,
                    height: windowSize.height
                ),
                display: false
            )
        } else {
            panel.setContentSize(windowSize)
            panel.center()
        }
        permissionWindow = panel

        nonisolated(unsafe) let onDenyForClose = onDeny
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in onDenyForClose() }

        let handleKeyEvent: (NSEvent) -> Bool = { event in
            if event.keyCode == 36 { onAllow(); return true }
            if event.keyCode == 53 { onDeny(); return true }
            return false
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldAcceptKeyboardShortcut(
                isVisible: permissionWindow?.isVisible == true,
                isKeyWindow: permissionWindow?.isKeyWindow == true,
                isAppActive: NSApp.isActive
            ) else {
                return event
            }
            return handleKeyEvent(event) ? nil : event
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.makeKey()
            if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
        }
    }

    /// Pure seams keep the security-sensitive screen and key-event policy
    /// deterministic in tests without constructing AppKit windows.
    nonisolated static func clampedWindowSize(_ size: NSSize, to visible: NSSize) -> NSSize {
        NSSize(
            width: min(size.width, visible.width),
            height: min(size.height, visible.height)
        )
    }

    nonisolated static func preferredPresentationCandidate<T>(
        keyWindow: T?,
        mainWindow: T?,
        mouse: T?,
        fallback: T?
    ) -> T? {
        keyWindow ?? mainWindow ?? mouse ?? fallback
    }

    nonisolated static func shouldAcceptKeyboardShortcut(
        isVisible: Bool,
        isKeyWindow: Bool,
        isAppActive: Bool
    ) -> Bool {
        isVisible && isKeyWindow && isAppActive
    }

    private static func dismissWindow() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        permissionWindow?.orderOut(nil)
        permissionWindow = nil
    }

    private static func cancelPolicyPrompt(id: UUID) {
        guard pendingPolicyPrompt?.id == id else { return }
        pendingPolicyPrompt?.cancel()
    }
}
