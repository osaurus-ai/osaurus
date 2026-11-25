//
//  SwarmAddNodeSheet.swift
//  osaurus
//
//  Add Node: shows a pairing code (and its QR) that the node's owner enters
//  in Osaurus Swarm on that device. The code expires after 5 minutes and
//  closes after five wrong attempts. Pairing grants inference only: the node
//  never gets chats, agents, memory or keys.
//

import SwiftUI

struct SwarmAddNodeSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var swarm = SwarmManager.shared
    let onClose: () -> Void

    private static let qrSide: CGFloat = 148

    var body: some View {
        SettingsSheet(
            icon: "plus.circle",
            title: "Add Node",
            subtitle: "On the other Mac, open Osaurus Swarm and enter this code.",
            width: SettingsSheetWidth.regular,
            primary: primaryAction,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                switch swarm.pairing {
                case .idle, .starting:
                    SettingsSpinner()
                case .offering(let offer):
                    offerPanel(offer)
                case .paired(let node):
                    SettingsCallout(
                        icon: "checkmark.circle.fill",
                        title: "Node Paired",
                        message: String(
                            format: L("%@ is now a Swarm node: %@. Open it from the node list to install models."),
                            node.name,
                            SwarmFormat.hardwareLine(node)
                        ),
                        verbatimMessage: true,
                        tone: .success
                    )
                case .failed(let reason):
                    SettingsCallout(
                        icon: "exclamationmark.triangle.fill",
                        title: "Pairing Failed",
                        message: reason,
                        verbatimMessage: true,
                        tone: .error
                    ) {
                        SettingsButton(.secondary, "New Code") { Task { await swarm.beginPairing() } }
                    }
                }
                Text(
                    "Pairing lets this Osaurus run models on that device and install or delete models there. The device never gets your chats, agents, memory or keys, and its owner sets its memory cap and pause rules.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryAction: SettingsSheetFooter.Action? {
        if case .paired = swarm.pairing {
            return .init(label: "Done", handler: onClose)
        }
        return nil
    }

    private func offerPanel(_ offer: SwarmPairingOffer) -> some View {
        HStack(alignment: .top, spacing: theme.space.s16) {
            ShareQRCardView(text: offer.qrPayload)
                .frame(width: Self.qrSide, height: Self.qrSide)
            VStack(alignment: .leading, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text("Pairing code", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.tertiary)
                    Text(verbatim: offer.groupedCode)
                        .font(SettingsFont.detailTitle)
                        .monospaced()
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(offer.expiresAt.timeIntervalSince(context.date)))
                    Text(
                        verbatim: remaining > 0
                            ? String(format: L("Expires in %d:%02d"), remaining / 60, remaining % 60)
                            : L("This code expired.")
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(remaining > 0 ? theme.text.secondary : theme.status[.warning].foreground)
                    .monospacedDigit()
                }
                Text(
                    "12 characters. Enter it in Osaurus Swarm → Pair with your Osaurus, or scan the QR code. Waiting for the node…",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                SettingsButton(.secondary, "New Code", icon: "arrow.clockwise", size: .compact) {
                    Task { await swarm.beginPairing() }
                }
            }
        }
    }
}
