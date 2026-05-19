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
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                Divider()
                    .background(theme.secondaryBorder)
                    .padding(.vertical, 8)
                expansionBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    // MARK: - Header (always visible)

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    if isMismatched {
                        Text(localized: "Stale")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.errorColor.opacity(0.12)))
                    }
                }

                if let address = agent.agentAddress {
                    Text(address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No address", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            if let address = agent.agentAddress {
                let isCopied = copiedAddress == address
                Button(action: { onCopyAddress(address) }) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Copy address")
            }

            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .help(isExpanded ? Text(localized: "Collapse") : Text(localized: "Manage agent key"))
        }
    }

    // MARK: - Expansion (rotate / revoke + access keys)

    private var expansionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if agent.agentAddress != nil {
                rotateRevokeRow
                accessKeysBlock
            } else {
                noAddressRow
            }
        }
    }

    private var rotateRevokeRow: some View {
        HStack(spacing: 8) {
            Button(action: onRotate) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Rotate Key", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp("Derive a new agent address and revoke any access keys scoped to the previous one.")

            Button(action: onRevoke) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Revoke", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.errorColor.opacity(0.10))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp("Clear this agent's address and revoke every access key scoped to it.")

            Spacer()
        }
    }

    private var noAddressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text("Generate an address for this agent first.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Spacer(minLength: 0)
        }
    }

    private var accessKeysBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ACCESS KEYS", bundle: .module)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(theme.tertiaryText)
                Spacer(minLength: 0)
                Button(action: onGenerateAccessKey) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Generate", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            if accessKeys.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Text("No access keys for this agent yet.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.cardBackground.opacity(0.4))
                )
            } else {
                ForEach(accessKeys) { key in
                    accessKeyRow(key)
                }
            }
        }
    }

    private func accessKeyRow(_ key: AccessKeyInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundColor(key.isActive ? theme.accentColor : theme.tertiaryText)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(key.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(key.isActive ? theme.primaryText : theme.tertiaryText)
                    if key.revoked {
                        statusBadge("Revoked", color: theme.errorColor)
                    } else if key.isExpired {
                        statusBadge("Expired", color: theme.warningColor)
                    } else {
                        statusBadge("Active", color: theme.successColor)
                    }
                }
                HStack(spacing: 6) {
                    Text(key.prefix + "…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                    if let expiresAt = key.expiresAt {
                        Text(
                            key.isExpired
                                ? "Expired \(identityMediumDateFormatter.string(from: expiresAt))"
                                : "Expires \(identityMediumDateFormatter.string(from: expiresAt))"
                        )
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    } else {
                        Text("Never expires", bundle: .module)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Spacer()

            if !key.revoked {
                Button(action: { onRevokeAccessKey(key.id) }) {
                    Text("Revoke", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.errorColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(theme.errorColor.opacity(0.10))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.cardBackground.opacity(0.4))
        )
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
