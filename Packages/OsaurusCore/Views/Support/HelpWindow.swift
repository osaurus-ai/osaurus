//
//  HelpWindow.swift
//  osaurus
//
//  Help in a window of its own, opened from the rail's Help button: report
//  a problem and read the team's replies without leaving the chat or
//  Settings behind. One window; asking again brings it forward.
//

import AppKit
import SwiftUI

@MainActor
enum HelpWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Help")
        window.contentViewController = NSHostingController(rootView: HelpWindowRoot())
        window.setContentSize(NSSize(width: 720, height: 760))
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("OsaurusHelpWindow")
        Self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Follows theme changes while the window is open.
private struct HelpWindowRoot: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        let theme = themeManager.currentTheme
        HelpView()
            .environment(\.theme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .frame(minWidth: 560, minHeight: 480)
    }
}
