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

            // Calculate window size based on content
            let fittingSize = hostingController.view.fittingSize
            let windowSize = NSSize(
                width: max(fittingSize.width, 480),
                height: max(fittingSize.height, 300)
            )

            // Center on active screen
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let initialRect: NSRect
            if let s = screen {
                let x = s.visibleFrame.midX - windowSize.width / 2
                let y = s.visibleFrame.midY - windowSize.height / 2
                initialRect = NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
            } else {
                initialRect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
            }

            // Create custom panel
            let panel = NSPanel(
                contentRect: initialRect,
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .alertPanel
            panel.contentViewController = hostingController

            permissionWindow = panel

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

            // Pre-layout and show
            hostingController.view.layoutSubtreeIfNeeded()

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

    private static func dismissWindow() {
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
