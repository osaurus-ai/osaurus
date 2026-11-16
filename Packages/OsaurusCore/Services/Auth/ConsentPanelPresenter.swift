//
//  ConsentPanelPresenter.swift
//  OsaurusCore
//
//  The one on-screen slot for consent panels such as "Log in with Osaurus":
//  one prompt at a time, auto-deny when unattended, keyboard shortcuts only
//  while the panel is key, and closing the panel counts as Cancel.
//

import AppKit
import Foundation
import SwiftUI

enum ConsentPanelResult: Equatable, Sendable {
    case approved
    case denied
    case timedOut
    /// Another consent panel is already on screen.
    case busy
}

@MainActor
enum ConsentPanelPresenter {
    static let approvalTimeout: TimeInterval = 120

    private static var panel: NSPanel?
    private static var localKeyMonitor: Any?
    private static var closeObserver: NSObjectProtocol?
    private static var timeoutWorkItem: DispatchWorkItem?

    static var isPresenting: Bool { panel != nil }

    /// `confirmsOnReturn` false leaves Return unbound, so only a click
    /// approves (used for anything that moves credits).
    static func present<Content: View>(
        minSize: NSSize,
        confirmsOnReturn: Bool,
        @ViewBuilder content: (_ approve: @escaping () -> Void, _ cancel: @escaping () -> Void) -> Content
    ) async -> ConsentPanelResult {
        if panel != nil { return .busy }

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let finish = { (result: ConsentPanelResult) in
                guard !hasResumed else { return }
                hasResumed = true
                dismissPanel()
                continuation.resume(returning: result)
            }
            let onApprove = { finish(.approved) }
            let onCancel = { finish(.denied) }

            let view = content(onApprove, onCancel)
                .environment(\.theme, ThemeManager.shared.currentTheme)
            let hostingController = NSHostingController(rootView: view)

            let newPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: minSize),
                styleMask: [.fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .modalPanel
            newPanel.hidesOnDeactivate = false
            newPanel.isMovableByWindowBackground = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.animationBehavior = .alertPanel
            newPanel.contentViewController = hostingController

            hostingController.view.layoutSubtreeIfNeeded()
            let fitting = hostingController.view.fittingSize
            let size = NSSize(width: max(fitting.width, minSize.width), height: max(fitting.height, minSize.height))
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                newPanel.setFrame(
                    NSRect(
                        x: visible.origin.x + (visible.width - size.width) / 2,
                        y: visible.origin.y + (visible.height - size.height) / 2,
                        width: size.width, height: size.height),
                    display: false)
            } else {
                newPanel.setContentSize(size)
                newPanel.center()
            }
            panel = newPanel

            nonisolated(unsafe) let onCancelForClose = onCancel
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newPanel,
                queue: .main
            ) { _ in
                onCancelForClose()
            }

            // Local monitor only: a keystroke aimed at another app must never
            // approve anything.
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard panel?.isKeyWindow == true else { return event }
                switch event.keyCode {
                case 36 where confirmsOnReturn:
                    onApprove()
                    return nil
                case 53:
                    onCancel()
                    return nil
                default:
                    return event
                }
            }

            let timeout = DispatchWorkItem { finish(.timedOut) }
            timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + approvalTimeout, execute: timeout)

            NSApp.activate(ignoringOtherApps: true)
            newPanel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                newPanel.makeKey()
                if let contentView = newPanel.contentView {
                    newPanel.makeFirstResponder(contentView)
                }
            }
        }
    }

    private static func dismissPanel() {
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
        panel?.orderOut(nil)
        panel = nil
    }
}
