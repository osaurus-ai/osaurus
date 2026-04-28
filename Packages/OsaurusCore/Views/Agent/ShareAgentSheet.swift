//
//  ShareAgentSheet.swift
//  osaurus
//
//  Replaces the JSON-export-on-share button with a network share flow:
//  generate a signed `osaurus://...?pair=...` deeplink, render it as
//  text + QR + system ShareLink, and surface the ledger of past invites
//  so the sender can revoke leaked links.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Expiry options

private enum ShareInviteExpiry: String, CaseIterable, Identifiable {
    case hour1
    case day1
    case days7
    case days30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour1: return "1 hour"
        case .day1: return "1 day"
        case .days7: return "7 days"
        case .days30: return "30 days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .day1: return 86_400
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        }
    }

    var date: Date {
        Date().addingTimeInterval(seconds)
    }
}

// MARK: - Sheet

struct ShareAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var relayManager = RelayTunnelManager.shared

    let agent: Agent

    @State private var expiry: ShareInviteExpiry = .days7
    @State private var generatedInvite: AgentInvite?
    @State private var generatedURL: URL?
    @State private var qrImage: NSImage?
    @State private var generationError: String?
    @State private var isGenerating: Bool = false
    @State private var copiedFlash: Bool = false

    @State private var ledger: [IssuedInviteRecord] = []
    @State private var revokeConfirm: IssuedInviteRecord?

    private var relayStatus: AgentRelayStatus {
        relayManager.agentStatuses[agent.id] ?? .disconnected
    }

    private var relayBaseURL: String? {
        if case .connected(let url) = relayStatus { return url }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    relayStatusCard
                    if relayBaseURL != nil {
                        inviteCard
                    }
                    if !ledger.isEmpty {
                        ledgerCard
                    }
                }
                .padding(20)
            }
            .background(theme.primaryBackground)
        }
        .frame(width: 520, height: 640)
        .background(theme.cardBackground)
        .onAppear {
            reloadLedger()
            // Best-effort relay enable so the user doesn't have to tab over to
            // the Sandbox tab first. Idempotent if already on.
            if relayStatus == .disconnected {
                relayManager.setTunnelEnabled(true, for: agent.id)
            }
        }
        .onChange(of: relayStatus) { _, newValue in
            if case .connected = newValue, generatedInvite == nil {
                Task { await generateInvite() }
            }
        }
        .themedAlert(
            "Revoke this invite?",
            isPresented: Binding(
                get: { revokeConfirm != nil },
                set: { if !$0 { revokeConfirm = nil } }
            ),
            message: revokeConfirm.map {
                "Anyone holding this link will lose access. The matching access key will also be revoked.\n\nNonce: \($0.nonce.prefix(12))…"
            },
            primaryButton: .destructive("Revoke") {
                if let target = revokeConfirm { revoke(target) }
                revokeConfirm = nil
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Share Agent", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Send a one-tap invite link to add \(agent.name) on another device.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    // MARK: Relay status card

    private var relayStatusCard: some View {
        HStack(spacing: 12) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
            Spacer()
            if case .disconnected = relayStatus {
                Button {
                    relayManager.setTunnelEnabled(true, for: agent.id)
                } label: {
                    Text("Enable Relay", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private var statusIndicator: some View {
        let (color, icon): (Color, String) = {
            switch relayStatus {
            case .connected: return (theme.successColor, "checkmark.seal.fill")
            case .connecting: return (theme.accentColor, "arrow.triangle.2.circlepath")
            case .disconnected: return (theme.tertiaryText, "moon.zzz.fill")
            case .error: return (theme.errorColor, "exclamationmark.triangle.fill")
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color.opacity(0.12)))
    }

    private var statusTitle: String {
        switch relayStatus {
        case .connected: return "Relay Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Relay Off"
        case .error(let msg): return "Relay Error: \(msg)"
        }
    }

    private var statusSubtitle: String {
        switch relayStatus {
        case .connected(let url):
            return url
        case .connecting:
            return "Connecting your agent to the share network."
        case .disconnected:
            return "Enable the relay tunnel so others can reach this agent."
        case .error:
            return "Open the Sandbox tab to retry the relay connection."
        }
    }

    // MARK: Invite card

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invite Link", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
                Spacer()
                expiryPicker
            }

            if let error = generationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing invite…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let url = generatedURL {
                inviteContent(url: url)
            } else {
                Button {
                    Task { await generateInvite() }
                } label: {
                    Text("Generate Invite", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var expiryPicker: some View {
        Menu {
            ForEach(ShareInviteExpiry.allCases) { option in
                Button(option.label) {
                    expiry = option
                    if generatedInvite != nil {
                        Task { await generateInvite() }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(expiry.label)
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(theme.inputBackground)
                    .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func inviteContent(url: URL) -> some View {
        // QR + URL row
        HStack(alignment: .top, spacing: 14) {
            qrView
                .frame(width: 124, height: 124)

            VStack(alignment: .leading, spacing: 8) {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )

                HStack(spacing: 6) {
                    Button {
                        copyToPasteboard(url.absoluteString)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedFlash ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedFlash ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(copiedFlash ? theme.successColor : theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill((copiedFlash ? theme.successColor : theme.accentColor).opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)

                    ShareLink(item: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10))
                            Text("Share…", bundle: .module)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if let invite = generatedInvite {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(
                    "Single-use, expires \(invite.expirationDate.formatted(date: .abbreviated, time: .shortened)). Anyone with this link can add this agent on their device."
                )
                .lineLimit(3)
            }
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var qrView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 36))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
            }
        }
    }

    // MARK: Ledger card

    private var ledgerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Issued Invites", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
                Spacer()
                Text("\(ledger.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.inputBackground))
            }

            VStack(spacing: 4) {
                ForEach(ledger) { record in
                    ledgerRow(record)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func ledgerRow(_ record: IssuedInviteRecord) -> some View {
        HStack(spacing: 10) {
            statusBadge(for: record.displayStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(record.nonce.prefix(12))…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Issued \(record.issuedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let used = record.usedAt {
                        Text("·")
                        Text("Used \(used.formatted(date: .abbreviated, time: .shortened))")
                    } else if record.displayStatus == .expired {
                        Text("·")
                        Text("Expired \(record.expirationDate.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("·")
                        Text("Expires \(record.expirationDate.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
            }
            Spacer()
            if record.displayStatus == .active || record.displayStatus == .used {
                Button {
                    revokeConfirm = record
                } label: {
                    Text("Revoke", bundle: .module)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.errorColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.errorColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.5))
        )
    }

    private func statusBadge(for status: IssuedInviteRecord.DisplayStatus) -> some View {
        let (color, label, icon): (Color, String, String) = {
            switch status {
            case .active: return (theme.successColor, "Active", "checkmark.circle.fill")
            case .used: return (theme.accentColor, "Used", "person.fill.checkmark")
            case .revoked: return (theme.errorColor, "Revoked", "xmark.octagon.fill")
            case .expired: return (theme.tertiaryText, "Expired", "clock.badge.xmark.fill")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Behaviour

    private func generateInvite() async {
        guard let baseURL = relayBaseURL else { return }
        isGenerating = true
        defer { isGenerating = false }
        generationError = nil

        do {
            let invite = try AgentInviteIssuer.issue(
                for: agent,
                relayBaseURL: baseURL,
                expiresAt: expiry.date
            )
            AgentInviteStore.record(invite, for: agent.id)
            generatedInvite = invite
            generatedURL = try invite.deeplinkURL()
            qrImage = generatedURL.flatMap { renderQR($0.absoluteString) }
            reloadLedger()
        } catch let error as AgentInviteError {
            generationError = error.errorDescription
        } catch {
            generationError = "Could not generate invite: \(error.localizedDescription)"
        }
    }

    private func reloadLedger() {
        AgentInviteStore.purgeOld(for: agent.id)
        ledger = AgentInviteStore.list(for: agent.id)
    }

    private func revoke(_ record: IssuedInviteRecord) {
        let keyId = AgentInviteStore.revoke(nonce: record.nonce, for: agent.id)
        if let keyId {
            APIKeyManager.shared.revoke(id: keyId)
        }
        // If the user revokes the active invite, force regeneration on next view.
        if record.nonce == generatedInvite?.nonce {
            generatedInvite = nil
            generatedURL = nil
            qrImage = nil
        }
        reloadLedger()
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedFlash = false
        }
    }

    private func renderQR(_ string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaleX: CGFloat = 8
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleX))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
