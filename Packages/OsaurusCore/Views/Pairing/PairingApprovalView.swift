//
//  PairingApprovalView.swift
//  osaurus
//
//  Approval dialog shown on the advertiser when a remote device requests pairing.
//

import AppKit
import SwiftUI

struct PairingApprovalView: View {
    let agentName: String
    let connectorAddress: OsaurusID
    /// Called with `isPermanent` when the user approves.
    let onAllow: (Bool) -> Void
    let onDeny: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var appeared = false
    @State private var isPermanent = false

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [theme.cardBackground, theme.cardBackground.opacity(0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardGradient)

            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)

                addressBlock
                    .padding(.top, 12)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 4)

                Toggle(isOn: $isPermanent) {
                    Text("Remember this device", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 12)
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)

                Rectangle()
                    .fill(theme.primaryBorder.opacity(0.3))
                    .frame(height: 1)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)

                actionButtons
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 2),
            radius: 24,
            x: 0,
            y: 12
        )
        .onAppear {
            withAnimation(theme.springAnimation(responseMultiplier: 1.25).delay(0.05)) {
                appeared = true
            }
        }
        .environment(\.theme, themeManager.currentTheme)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(theme.accentColor.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                )

            Text("Pairing Request", bundle: .module)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)

            Text("A device wants to pair with **\(agentName)**.\nAllow this device to connect?", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Address Block

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("Device Address", bundle: .module) } icon: { Image(systemName: "person.badge.key.fill") }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Text(connectorAddress)
                .font(theme.monoFont(size: 11.5))
                .foregroundColor(theme.primaryText.opacity(0.9))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBlockBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                        theme.primaryBorder.opacity(0.6),
                        lineWidth: 1
                    )
                )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            PairingActionButton(
                title: "Deny",
                shortcutHint: "esc",
                icon: "xmark",
                isPrimary: false,
                color: theme.errorColor,
                action: onDeny
            )
            PairingActionButton(
                title: "Allow",
                shortcutHint: "return",
                icon: "checkmark",
                isPrimary: true,
                color: theme.successColor,
                action: { onAllow(isPermanent) }
            )
        }
    }
}

// MARK: - Pairing Action Button

private struct PairingActionButton: View {
    let title: String
    let shortcutHint: String
    let icon: String
    let isPrimary: Bool
    let color: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isPrimary ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText)
                Text(shortcutHint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isPrimary ? Color.white.opacity(0.7) : theme.secondaryText.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isPrimary ? Color.white.opacity(0.15) : theme.tertiaryBackground.opacity(0.5))
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isPrimary
                    ? color.opacity(isHovering ? 0.9 : 1.0)
                    : theme.tertiaryBackground.opacity(isHovering ? 0.8 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                    isPrimary ? .clear : (isHovering ? theme.primaryBorder : theme.cardBorder),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
