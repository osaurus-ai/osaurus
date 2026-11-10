//
//  HostedApprovalCard.swift
//  osaurus
//
//  A tool call the agent running on another of the user's Macs is waiting
//  on. The answer goes back to that Mac.
//

import SwiftUI

struct HostedApprovalCard: View {
    let approval: SyncHostedRunContract.PendingApproval
    let hostName: String
    let onAnswer: (SyncHostedRunContract.Answer) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "hand.raised.fill")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text(String(format: L("Allow %1$@ on %2$@?"), approval.tool, hostName))
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
            }
            if !approval.description.isEmpty {
                Text(approval.description)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !approval.arguments.isEmpty, approval.arguments != "{}" {
                Text(approval.arguments)
                    .textStyle(.code)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(approval.arguments)
            }
            HStack(spacing: theme.space.s6) {
                Button(action: { onAnswer(.denied) }) { Text(L("Deny")) }
                    .buttonStyle(.settings(.secondary, size: .compact))
                Spacer(minLength: 0)
                Button(action: { onAnswer(.allowOnce) }) { Text(L("Allow")) }
                    .buttonStyle(.settings(.secondary, size: .compact))
                if approval.offersRunLease {
                    Button(action: { onAnswer(.allowForRun) }) { Text(L("Allow for This Conversation")) }
                        .buttonStyle(.settings(.secondary, size: .compact))
                }
                Button(action: { onAnswer(.alwaysAllow) }) { Text(L("Always Allow")) }
                    .buttonStyle(.settings(.primary, size: .compact))
            }
        }
        .padding(theme.space.s12)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .fill(theme.status.warning.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(theme.status.warning.border, lineWidth: theme.stroke.default)
        )
        .padding(.bottom, theme.space.s8)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
