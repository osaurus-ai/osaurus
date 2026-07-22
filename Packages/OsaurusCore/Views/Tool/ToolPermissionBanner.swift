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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.warningColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.warningColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                    Text("Open System Settings", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text("Open System Settings to grant permissions", bundle: .module))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }
}
