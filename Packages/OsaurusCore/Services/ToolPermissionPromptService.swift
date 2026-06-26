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
    private static var globalKeyMonitor: Any?
    private static var closeObserver: NSObjectProtocol?

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

            // Create the SwiftUI view
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

            let hostingController = NSHostingController(rootView: permissionView)

            // Create custom panel with a temporary rect (will be repositioned after content is set)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                styleMask: [.fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .alertPanel
            panel.contentViewController = hostingController

            // Layout the view to get accurate sizing
            hostingController.view.layoutSubtreeIfNeeded()

            // Calculate window size based on actual content
            let fittingSize = hostingController.view.fittingSize
            let windowSize = NSSize(
                width: max(fittingSize.width, 480),
                height: max(fittingSize.height, 300)
            )

            // Find the screen where the mouse is located (for multi-monitor support)
            let mouse = NSEvent.mouseLocation
            let targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

            // Center the window on the target screen
            if let screen = targetScreen {
                let visibleFrame = screen.visibleFrame
                let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
                let y = visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
                let centeredFrame = NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
                panel.setFrame(centeredFrame, display: false)
            } else {
                panel.setContentSize(windowSize)
                panel.center()
            }

            permissionWindow = panel

            // Safety net: if the panel is closed externally (system, force-quit, etc.)
            // without the user clicking a button, resume the continuation with deny.
            // The observer runs on .main queue, matching the @MainActor isolation of this type.
            nonisolated(unsafe) let onDenyForClose = onDeny
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { _ in
                onDenyForClose()
            }

            // Handler for keyboard shortcuts
            let handleKeyEvent: (NSEvent) -> Bool = { event in
                if event.keyCode == 36 {  // Enter key
                    onAllow()
                    return true
                } else if event.keyCode == 53 {  // Escape key
                    onDeny()
                    return true
                }
                return false
            }

            // Local monitor for when app is active and window has focus
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if handleKeyEvent(event) {
                    return nil
                }
                return event
            }

            // Global monitor as fallback when window might not have focus
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                // Only handle if our permission window is visible
                guard permissionWindow?.isVisible == true else { return }
                _ = handleKeyEvent(event)
            }

            // Activate app and ensure window becomes key
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)

            // Ensure panel becomes first responder after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                panel.makeKey()
                if let contentView = panel.contentView {
                    panel.makeFirstResponder(contentView)
                }
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
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
        let windowSize = NSSize(
            width: max(fittingSize.width, 480),
            height: max(fittingSize.height, 300)
        )
        let mouse = NSEvent.mouseLocation
        let targetScreen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen = targetScreen {
            let vf = screen.visibleFrame
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
            handleKeyEvent(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard permissionWindow?.isVisible == true else { return }
            _ = handleKeyEvent(event)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.makeKey()
            if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
        }
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
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        permissionWindow?.orderOut(nil)
        permissionWindow = nil
    }
}
