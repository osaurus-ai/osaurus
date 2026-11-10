//
//  RemoteAccessSection.swift
//  osaurus
//
//  Remote access gives an agent a public address so teammates, guests and
//  webhooks can reach it while it runs on this Mac. One row per agent, used
//  by Sharing → Access (every agent) and the agent's Sharing tab (one).
//  Turning it on goes through `RemoteAccessConsent`; turning it off for an
//  agent shared into a workspace asks first, because teammates lose reach.
//

import AppKit
import SwiftUI

struct RemoteAccessSection: View {
    @ObservedObject private var agentManager = AgentManager.shared

    /// nil lists every agent that can have remote access.
    var agentId: UUID? = nil
    var anchorId: String? = nil

    private var agents: [Agent] {
        if let agentId {
            return agentManager.agent(for: agentId).map { [$0] } ?? []
        }
        return agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        SettingsSection(
            title: "Remote Access",
            subtitle: agentId == nil
                ? "Gives an agent a public address so teammates, guests and webhooks can reach it while it runs on this Mac."
                : "Gives this agent a public address so teammates, guests and webhooks can reach it while it runs on this Mac.",
            anchorId: anchorId
        ) {
            if agents.isEmpty {
                SettingsEmptyState(inline: "person.crop.circle.badge.questionmark", title: "Create an agent first")
            } else {
                ForEach(agents) { agent in
                    RemoteAccessRow(agent: agent, showsName: agentId == nil)
                }
            }
        }
        .task {
            for agent in agents where agent.agentAddress == nil {
                agentManager.assignAddressInBackground(to: agent)
            }
        }
    }
}

/// One agent's remote access: status, public URL with Copy, and the switch.
struct RemoteAccessRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared

    let agent: Agent
    var showsName: Bool = true

    @State private var showConsent = false
    @State private var showOffConfirm = false
    @State private var copied = false

    private var status: AgentRelayStatus { relayManager.agentStatuses[agent.id] ?? .disconnected }
    private var hasAddress: Bool { agent.agentAddress != nil && agent.agentIndex != nil }

    private var sharedWorkspaceNames: [String] {
        guard let address = agent.agentAddress else { return [] }
        return rosterStore.workspacesSharing(agentAddress: address).map(\.name)
    }

    var body: some View {
        SettingsRow(
            title: showsName ? agent.name : L("Remote Access"),
            verbatimTitle: true,
            leading: {
                if showsName {
                    AgentAvatarView(
                        mascotId: agent.avatar,
                        name: agent.name,
                        tint: agentColorFor(agent.name),
                        diameter: 26,
                        customImageURL: agent.customAvatarURL,
                        monogramFontSize: 11,
                        borderWidth: theme.stroke.default
                    )
                }
            },
            description: { description },
            trailing: { trailing }
        )
        .remoteAccessConsent(isPresented: $showConsent, agentName: agent.name) {
            relayManager.setTunnelEnabled(true, for: agent.id)
        }
        .themedAlert(
            L("Turn off remote access?"),
            isPresented: $showOffConfirm,
            message: String(
                format: L(
                    "This agent is shared with %@. Turning off remote access disconnects teammates immediately. It stays shared, so turning remote access back on restores their access."
                ),
                ListFormatter.localizedString(byJoining: sharedWorkspaceNames)
            ),
            primaryButton: .destructive(L("Turn Off")) {
                relayManager.setTunnelEnabled(false, for: agent.id)
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    @ViewBuilder
    private var description: some View {
        if !hasAddress {
            Text("Needs an agent address. Set up your Osaurus ID first.", bundle: .module)
        } else {
            switch status {
            case .connected(let url):
                Text(verbatim: url)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .error(let message):
                Text(verbatim: message)
                    .foregroundColor(theme.status.error.foreground)
            case .servedElsewhere:
                Text("Another Mac signed in to your Osaurus ID is serving this agent.", bundle: .module)
            case .connecting:
                Text("Getting a public address…", bundle: .module)
            case .disconnected:
                if let address = agent.agentAddress {
                    Text(verbatim: ParticipantFormatter.shortAddress(address))
                        .font(SettingsFont.monoSmall)
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: theme.space.s8) {
            if !hasAddress {
                SettingsButton(.secondary, "Open Osaurus ID", size: .compact) {
                    ManagementStateManager.shared.selectedTab = .identity
                }
            } else {
                PresenceStatusChip(remoteAccess: status)
                if case .connected(let url) = status {
                    SettingsIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy public URL", size: .compact) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                }
                if case .servedElsewhere = status {
                    SettingsButton(.secondary, "Serve From This Mac", size: .compact) {
                        relayManager.reclaimTunnel(for: agent.id)
                    }
                } else {
                    Toggle("", isOn: toggleBinding)
                        .settingsSwitch()
                        .accessibilityLabel(Text(String(format: L("Remote access for %@"), agent.name)))
                }
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { relayManager.isTunnelEnabled(for: agent.id) },
            set: { newValue in
                if newValue {
                    showConsent = true
                } else if !sharedWorkspaceNames.isEmpty {
                    showOffConfirm = true
                } else {
                    relayManager.setTunnelEnabled(false, for: agent.id)
                }
            }
        )
    }
}
