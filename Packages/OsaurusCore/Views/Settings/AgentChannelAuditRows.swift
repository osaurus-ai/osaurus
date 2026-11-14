//
//  AgentChannelAuditRows.swift
//  osaurus
//
//  Rows for channel receive decisions and inbox messages, shared
//  by Automations History and each channel's diagnostics.
//

import SwiftUI

// MARK: - Activity Rows

struct AgentChannelAuditDecisionRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    let event: AgentChannelAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Image(systemName: statusIcon)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(statusColor)
                    .frame(width: 18)
                Text(event.status.rawValue.capitalized)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(themeManager.currentTheme.text.primary)
                Text(event.action)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(event.createdAt.formatted(.relative(presentation: .named)))
                    .font(SettingsFont.footnote)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                    .lineLimit(1)
            }

            if !event.redactedSummary.isEmpty {
                Text(event.redactedSummary)
                    .font(SettingsFont.caption)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: theme.space.s8) {
                Label(scopeLabel, systemImage: "app.connected.to.app.below.fill")
                if let roomId = event.roomId {
                    Label(roomId, systemImage: "number")
                }
                if let reason = event.reason {
                    Label(reason, systemImage: "info.circle")
                }
            }
            .textStyle(.micro)
            .foregroundColor(themeManager.currentTheme.text.tertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.surface.raised)
    }

    private var scopeLabel: String {
        AgentChannelKind(rawValue: event.connectionId)?.displayName ?? event.connectionId
    }

    private var statusIcon: String {
        switch event.status {
        case .accepted: "checkmark.shield.fill"
        case .duplicate: "arrow.triangle.2.circlepath"
        case .denied: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .accepted:
            themeManager.currentTheme.status.success.foreground
        case .duplicate:
            themeManager.currentTheme.action.primary.default.background
        case .denied, .failed:
            themeManager.currentTheme.status.warning.foreground
        }
    }
}

struct AgentChannelInboxMessageRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: AgentChannelInboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Image(systemName: message.direction == .inbound ? "tray.and.arrow.down" : "paperplane")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(themeManager.currentTheme.text.link)
                    .frame(width: 18)
                Text(message.direction == .inbound ? L("Received") : L("Sent"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(themeManager.currentTheme.text.primary)
                Text(message.roomId)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(message.receivedAt.formatted(.relative(presentation: .named)))
                    .font(SettingsFont.footnote)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
                    .lineLimit(1)
            }

            Text(message.preview.isEmpty ? L("Empty message") : message.preview)
                .font(SettingsFont.caption)
                .foregroundColor(themeManager.currentTheme.text.secondary)
                .lineLimit(2)

            HStack(spacing: theme.space.s8) {
                Label(scopeLabel, systemImage: "app.connected.to.app.below.fill")
                if let authorDisplay = message.authorDisplay, !authorDisplay.isEmpty {
                    Label(authorDisplay, systemImage: "person")
                }
            }
            .textStyle(.micro)
            .foregroundColor(themeManager.currentTheme.text.tertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.surface.raised)
    }

    private var scopeLabel: String {
        AgentChannelKind(rawValue: message.connectionId)?.displayName ?? message.connectionId
    }
}
