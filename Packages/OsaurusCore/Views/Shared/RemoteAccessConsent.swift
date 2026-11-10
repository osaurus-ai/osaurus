//
//  RemoteAccessConsent.swift
//  osaurus
//
//  The one consent step for turning on an agent's remote access (the
//  `*.agent.osaurus.ai` relay). Every surface that can switch it on (the
//  agent's Sharing tab, Access, Share Agent, the workspace share sheet and
//  the chat sidebar) asks with this copy before the tunnel opens.
//

import SwiftUI

enum RemoteAccessConsent {
    static var title: String { L("Turn on remote access?") }

    static var confirmTitle: String { L("Turn on remote access") }

    static func message(agentName: String) -> String {
        String(
            format: L(
                "%@ gets a public address at agent.osaurus.ai so people you share it with can reach it over the internet. Anyone with the address can send requests; access keys still protect every endpoint. The agent keeps running on this Mac."
            ),
            agentName
        )
    }

    /// Consent is only needed to switch remote access on; an agent whose
    /// tunnel is already enabled (connected, connecting or failing) was
    /// consented to when it was turned on.
    static func isNeeded(tunnelEnabled: Bool) -> Bool { !tunnelEnabled }

    /// Asks through `ThemedAlertCenter`, then enables the tunnel. Skips the
    /// question when the tunnel is already on.
    @MainActor
    static func request(
        for agent: Agent,
        scope: ThemedAlertScope,
        relay: RelayTunnelManager = .shared,
        onEnabled: (() -> Void)? = nil
    ) {
        guard isNeeded(tunnelEnabled: relay.isTunnelEnabled(for: agent.id)) else {
            onEnabled?()
            return
        }
        ThemedAlertCenter.shared.confirmDestructive(
            scope: scope,
            title: title,
            message: message(agentName: agent.name),
            destructiveTitle: confirmTitle
        ) {
            relay.setTunnelEnabled(true, for: agent.id)
            onEnabled?()
        }
    }
}

extension View {
    /// Binding-driven variant of `RemoteAccessConsent` for views that
    /// already present their own alerts (sheets use `.contained`).
    func remoteAccessConsent(
        isPresented: Binding<Bool>,
        agentName: String,
        presentationStyle: ThemedAlertPresentationStyle = .window,
        onConfirm: @escaping () -> Void
    ) -> some View {
        themedAlert(
            RemoteAccessConsent.title,
            isPresented: isPresented,
            message: RemoteAccessConsent.message(agentName: agentName),
            primaryButton: .destructive(RemoteAccessConsent.confirmTitle, action: onConfirm),
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: presentationStyle
        )
    }
}
