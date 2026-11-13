//
//  AgentKeyManagement.swift
//  osaurus
//
//  Per-agent key administration nested inside `IdentityView.AgentAddressesSection`.
//  Provides the expandable detail row for each agent: rotate / revoke its
//  derived address and list / generate / revoke the osk-v1 access keys whose
//  audience is that agent's address.
//

import AppKit
import SwiftUI

private let identityMediumDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f
}()

struct AgentKeyManagementRow: View {
    @Environment(\.theme) private var theme

    let agent: Agent
    let isMismatched: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onRotate: () -> Void
    let onRevoke: () -> Void
    let onGenerateAccessKey: () -> Void
    let onRevokeAccessKey: (UUID) -> Void
    let copiedAddress: OsaurusID?
    let onCopyAddress: (OsaurusID) -> Void
    let accessKeys: [AccessKeyInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            headerRow
            if isExpanded {
                Divider()
                    .background(theme.border.default)
                    .padding(.vertical, theme.space.s8)
                expansionBody
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
    }

    // MARK: - Header (always visible)

    private var headerRow: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "person.fill")
                .glyphSize(.micro)
                .foregroundColor(theme.text.link)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(agent.name)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    if isMismatched {
                        StatusChip(L("Stale"), tone: .error)
                    }
                }

                if let address = agent.agentAddress {
                    Text(address)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No address", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            Spacer()

            if let address = agent.agentAddress {
                let isCopied = copiedAddress == address
                SettingsIconButton(
                    isCopied ? "checkmark" : "doc.on.doc",
                    help: "Copy address",
                    size: .compact
                ) {
                    onCopyAddress(address)
                }
            }

            SettingsIconButton(
                isExpanded ? "chevron.up" : "chevron.down",
                help: isExpanded ? "Collapse" : "Manage agent key",
                size: .compact,
                action: onToggleExpanded
            )
        }
    }

    // MARK: - Expansion (rotate / revoke + access keys)

    private var expansionBody: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if agent.agentAddress != nil {
                rotateRevokeRow
                accessKeysBlock
            } else {
                noAddressRow
            }
        }
    }

    private var rotateRevokeRow: some View {
        HStack(spacing: theme.space.s8) {
            SettingsButton(
                .secondary,
                "Rotate key",
                icon: "arrow.triangle.2.circlepath",
                size: .compact,
                help: "Derive a new agent address and revoke any access keys scoped to the previous one.",
                action: onRotate
            )

            SettingsButton(
                .destructive,
                "Revoke",
                icon: "xmark.shield",
                size: .compact,
                help: "Clear this agent's address and revoke every access key scoped to it.",
                action: onRevoke
            )

            Spacer()
        }
    }

    private var noAddressRow: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "info.circle")
                .glyphSize(.footnote)
                .foregroundColor(theme.text.tertiary)
            Text("Generate an address for this agent first.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var accessKeysBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Text("Access keys", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer(minLength: 0)
                Button(action: onGenerateAccessKey) {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "plus")
                        Text("Generate", bundle: .module)
                    }
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            }

            if accessKeys.isEmpty {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "key.slash")
                        .glyphSize(.micro)
                        .foregroundColor(theme.text.tertiary)
                    Text("No access keys for this agent yet.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(theme.space.s8)
                .settingsChrome(.surface)
            } else {
                ForEach(accessKeys) { key in
                    accessKeyRow(key)
                }
            }
        }
    }

    private func accessKeyRow(_ key: AccessKeyInfo) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "key.fill")
                .glyphSize(.micro)
                .foregroundColor(key.isActive ? theme.text.link : theme.text.tertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(key.label)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(key.isActive ? theme.text.primary : theme.text.tertiary)
                    if key.revoked {
                        statusBadge("Revoked", color: theme.status.error.foreground)
                    } else if key.isExpired {
                        statusBadge("Expired", color: theme.status.warning.foreground)
                    } else {
                        statusBadge("Active", color: theme.status.success.foreground)
                    }
                }
                HStack(spacing: theme.space.s6) {
                    Text(key.prefix + "…")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                    if let expiresAt = key.expiresAt {
                        Text(
                            key.isExpired
                                ? "Expired \(identityMediumDateFormatter.string(from: expiresAt))"
                                : "Expires \(identityMediumDateFormatter.string(from: expiresAt))"
                        )
                        .textStyle(.micro)
                        .foregroundColor(theme.text.tertiary)
                    } else {
                        Text("Never expires", bundle: .module)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            }

            Spacer()

            if !key.revoked {
                SettingsButton(.destructive, "Revoke", size: .compact) {
                    onRevokeAccessKey(key.id)
                }
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.surface)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        StatusChip(text, tint: color)
    }
}
