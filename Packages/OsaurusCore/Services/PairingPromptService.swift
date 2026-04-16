//
//  PairingPromptService.swift
//  osaurus
//
//  Presents a pairing approval dialog when a remote device requests to pair.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
enum PairingPromptService {
    enum ShortcutAction: Equatable {
        case allow(isPermanent: Bool)
        case deny
        case none
    }

    private static var pairingWindow: NSPanel?
    private static var localKeyMonitor: Any?
    private static var globalKeyMonitor: Any?
    private static var closeObserver: NSObjectProtocol?

    static func requestApproval(
        connectorAddress: OsaurusID,
        agentName: String
    ) async -> (approved: Bool, isPermanent: Bool) {
        return await withCheckedContinuation { continuation in
            var hasResumed = false

            let onAllow = { (isPermanent: Bool) in
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: (approved: true, isPermanent: isPermanent))
            }

            let onDeny = {
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: (approved: false, isPermanent: false))
            }

            let approvalState = PairingApprovalState()
            let themeManager = ThemeManager.shared
            let approvalView = PairingApprovalView(
                agentName: agentName,
                connectorAddress: connectorAddress,
                state: approvalState,
                onAllow: onAllow,
                onDeny: onDeny
            )
            .environment(\.theme, themeManager.currentTheme)

            let hostingController = NSHostingController(rootView: approvalView)

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
            let targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

            if let screen = targetScreen {
                let visibleFrame = screen.visibleFrame
                let x = visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2
                let y = visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
                panel.setFrame(NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height), display: false)
            } else {
                panel.setContentSize(windowSize)
                panel.center()
            }

            pairingWindow = panel

            nonisolated(unsafe) let onDenyForClose = onDeny
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { _ in
                onDenyForClose()
            }

            let handleKeyEvent: (NSEvent) -> Bool = { event in
                switch shortcutAction(for: event.keyCode, isPermanent: approvalState.isPermanent) {
                case .allow(let isPermanent):
                    onAllow(isPermanent)
                    return true
                case .deny:
                    onDeny()
                    return true
                case .none:
                    return false
                }
            }

            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if handleKeyEvent(event) { return nil }
                return event
            }

            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard pairingWindow?.isVisible == true else { return }
                _ = handleKeyEvent(event)
            }

            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                panel.makeKey()
                if let contentView = panel.contentView {
                    panel.makeFirstResponder(contentView)
                }
            }
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
        pairingWindow?.orderOut(nil)
        pairingWindow = nil
    }

    nonisolated static func shortcutAction(for keyCode: UInt16, isPermanent: Bool) -> ShortcutAction {
        switch keyCode {
        case 36: return .allow(isPermanent: isPermanent)
        case 53: return .deny
        default: return .none
        }
    }
}
