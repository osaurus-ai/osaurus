//
//  ToolPermissionBanner.swift
//  osaurus
//
//  Actionable banner shown when tools (or plugins) are missing macOS system
//  permissions. Shared by the Tools catalog and PluginsView.
//

import AppKit
import SwiftUI

struct ToolPermissionBanner: View {
    /// What the count refers to. The Tools catalog counts individual tools;
    /// PluginsView counts whole plugins.
    enum Subject {
        case tools
        case plugins
    }

    @Environment(\.theme) private var theme
    let count: Int
    var subject: Subject = .tools

    private var title: String {
        switch subject {
        case .tools:
            return count == 1
                ? L("1 tool needs permission")
                : L("\(count) tools need permission")
        case .plugins:
            return count == 1
                ? L("1 plugin needs system permissions")
                : L("\(count) plugins need system permissions")
        }
    }

    private var subtitle: String {
        switch subject {
        case .tools:
            return L(
                "Grant access in System Settings — filter by \u{201C}Needs attention\u{201D} to see which tools are waiting"
            )
        case .plugins:
            return L("Expand each plugin to grant the required permissions")
        }
    }

    var body: some View {
        HStack(spacing: theme.space.s12) {
            ZStack {
                Circle()
                    .fill(theme.status.warning.background)
                    .frame(width: 36, height: 36)
                Image(systemName: "lock.shield.fill")
                    .glyphSize(.medium)
                    .foregroundColor(theme.status.warning.foreground)
            }

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(title)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Text(subtitle)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }

            Spacer()

            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "gear")
                        .glyphSize(.footnote)
                    Text("Open System Settings", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                .foregroundColor(theme.text.link)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.selected)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text("Open System Settings to grant permissions", bundle: .module))
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.warning))
        .accessibilityElement(children: .combine)
    }
}
