//
//  SandboxChipPopover.swift
//  osaurus
//
//  What the composer's sandbox chip opens once the sandbox is on for the
//  agent: live status (with first-use progress), this agent's network, and
//  the few actions a user may need without leaving the chat.
//

import AppKit
import SwiftUI

struct SandboxChipPopover: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    let agentId: UUID
    let failure: SandboxToolRegistrar.UnavailabilityReason?
    let onRetry: () -> Void
    let onTurnOff: () -> Void
    let onOpenSettings: () -> Void

    /// Below this the sandbox can't start or set up an agent, so a failure
    /// offers Free Up Space.
    static let lowDiskBytes: Int64 = 2 * 1_073_741_824
    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!

    @State private var copied = false

    private var diskIsLow: Bool {
        guard failure != nil, let free = SandboxManager.hostFreeBytes() else { return false }
        return free < Self.lowDiskBytes
    }

    private var isLoading: Bool {
        sandboxState.status == .starting || sandboxState.isProvisioning
    }

    private var dotColor: Color {
        if failure != nil { return theme.status.error.foreground }
        if isLoading { return theme.status.warning.foreground }
        if sandboxState.status.isRunning { return theme.status.success.foreground }
        return theme.text.tertiary
    }

    private var title: String {
        if failure != nil { return L("Sandbox unavailable") }
        if isLoading { return L("Sandbox is starting") }
        if sandboxState.status.isRunning { return L("Sandbox is on") }
        return L("Sandbox starts when needed")
    }

    private var detail: String? {
        if let failure { return failure.message }
        if isLoading {
            if let phase = sandboxState.provisioningPhase, !phase.isEmpty { return phase }
            return L("The first start downloads the Linux runtime; later starts take a few seconds.")
        }
        if sandboxState.status.isRunning {
            return L("Commands this agent runs stay inside its own Linux container.")
        }
        return L("It starts the next time this agent runs a command.")
    }

    private var networkLine: String {
        switch SandboxManager.egressMode(forAgentId: agentId) {
        case .open: return L("Network: on")
        case .allowlist(let domains):
            return domains.count == 1
                ? L("Network: \(domains[0]) only")
                : L("Network: \(domains.count) allowed domains only")
        case .none: return L("Network: off")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(verbatim: title)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
            }

            if let detail {
                Text(verbatim: detail)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLoading, let progress = sandboxState.provisioningProgress {
                SettingsProgressBar(value: progress, tint: theme.status.warning.foreground)
            }

            Text(verbatim: networkLine)
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)

            HStack(spacing: theme.space.s8) {
                if diskIsLow {
                    SettingsButton(.primary, "Free Up Space", size: .compact) {
                        NSWorkspace.shared.open(Self.storageSettingsURL)
                    }
                } else if failure != nil {
                    SettingsButton(.primary, "Try Again", size: .compact, action: onRetry)
                }
                if let failure {
                    SettingsIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "Sandbox unavailable (\(failure.kind.rawValue)): \(failure.message)\nOsaurus \(SandboxBridgeMigrationFlag.currentAppVersion)",
                            forType: .string
                        )
                        copied = true
                    }
                }
                SettingsButton(.secondary, "Turn Off for This Agent", size: .compact, action: onTurnOff)
                Spacer(minLength: 0)
                SettingsButton(.tertiary, "Sandbox Settings", icon: "gearshape", size: .compact, action: onOpenSettings)
            }
            .padding(.top, theme.space.s4)
        }
        .padding(theme.space.s12)
        .frame(width: 320, alignment: .leading)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
    }
}
