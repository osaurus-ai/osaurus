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

    /// Outcome of an approval request. `busy` lets the caller return a distinct
    /// "try again" status when another prompt is already on screen, instead of
    /// silently denying or clobbering the in-flight prompt.
    enum ApprovalResult: Equatable {
        case approved(isPermanent: Bool)
        case denied
        case busy
    }

    /// How long an unattended prompt stays up before auto-denying. Bounds the
    /// `/pair` request (and its awaited continuation) so it can't hang forever.
    private static let approvalTimeout: TimeInterval = 120

    private static var pairingWindow: NSPanel?
    private static var localKeyMonitor: Any?
    private static var closeObserver: NSObjectProtocol?
    private static var timeoutWorkItem: DispatchWorkItem?

    static func requestApproval(
        connectorAddress: OsaurusID,
        agentName: String
    ) async -> ApprovalResult {
        // Only one approval prompt at a time. Concurrent `/pair` requests get a
        // `busy` result (mapped to HTTP 429) rather than racing the static
        // window/monitor state or hanging behind the first prompt.
        if pairingWindow != nil {
            return .busy
        }

        return await withCheckedContinuation { continuation in
            var hasResumed = false

            let onAllow = { (isPermanent: Bool) in
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: .approved(isPermanent: isPermanent))
            }

            let onDeny = {
                guard !hasResumed else { return }
                hasResumed = true
                dismissWindow()
                continuation.resume(returning: .denied)
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

            // Local monitor only — it fires solely while Osaurus is the active
            // app and this panel is key. The previous GLOBAL monitor approved
            // pairing on a stray Return even when another app was focused,
            // which (combined with the unauthenticated `/pair` endpoint) let a
            // LAN attacker time a request so a user's keystroke granted a key.
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard pairingWindow?.isKeyWindow == true else { return event }
                if handleKeyEvent(event) { return nil }
                return event
            }

            // Auto-deny if the user never responds so the awaiting `/pair`
            // request (and its continuation) can't be parked indefinitely.
            let timeout = DispatchWorkItem { onDeny() }
            timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + approvalTimeout, execute: timeout)

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
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
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
