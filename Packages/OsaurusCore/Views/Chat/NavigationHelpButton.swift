//
//  NavigationHelpButton.swift
//  osaurus
//
//  The Help entry on the main window's navigation rail, above Usage and
//  Settings. Opens the Help window (report a problem, read the team's
//  replies) and carries a dot while a reply is waiting to be read.
//

import SwiftUI

struct NavigationHelpButton: View {
    @ObservedObject private var support = SupportService.shared
    @Environment(\.theme) private var theme

    private var hasUnread: Bool { support.unreadCount > 0 }

    var body: some View {
        SettingsIconButton("questionmark.circle", help: "Help", size: .regular, role: .tertiary) {
            HelpWindow.show()
        }
        .frame(width: 32, height: 32)
        .overlay(alignment: .topTrailing) {
            if hasUnread {
                Circle()
                    .fill(theme.action.primary.default.background)
                    .frame(width: theme.space.s8, height: theme.space.s8)
                    .overlay(Circle().strokeBorder(theme.surface.canvas, lineWidth: theme.stroke.default))
                    .padding(theme.space.s2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(theme.motion.quick, value: hasUnread)
        .accessibilityLabel(Text("Help", bundle: .module))
        .accessibilityValue(hasUnread ? Text("New reply", bundle: .module) : Text(verbatim: ""))
    }
}
