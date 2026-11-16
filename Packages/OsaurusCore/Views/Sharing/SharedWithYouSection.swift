//
//  SharedWithYouSection.swift
//  osaurus
//
//  Agents other people shared with you through a guest link, with the same
//  status chip the chat sidebar uses (including "Access revoked"), Open Chat,
//  Remove, and Add Shared Agent for a link that arrived as text. Agents a
//  teammate shares into a workspace are listed under Workspaces instead.
//

import SwiftUI

struct SharedWithYouSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var remoteAgents = RemoteAgentManager.shared
    @ObservedObject private var providers = RemoteProviderManager.shared

    var anchorId: String? = nil

    @State private var isAdding = false
    @State private var link = ""

    private var directShares: [RemoteAgent] {
        remoteAgents.remoteAgents
            .filter { !$0.isWorkspaceManaged }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SettingsSection(
            title: "Shared With You",
            caption: directShares.isEmpty ? nil : "\(directShares.count)",
            subtitle: "Agents people shared with you through a guest link. They run on the owner's Mac. Agents your teammates share are under Workspaces.",
            anchorId: anchorId,
            accessory: {
                SettingsButton(.secondary, isAdding ? "Cancel" : "Add Shared Agent…", icon: isAdding ? nil : "plus", size: .compact) {
                    isAdding.toggle()
                    link = ""
                }
            }
        ) {
            if isAdding {
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(placeholder: "osaurus://…", text: $link, monospaced: true, onSubmit: add)
                    SettingsButton(.primary, "Add", action: add)
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if directShares.isEmpty {
                SettingsEmptyState(
                    inline: "person.2",
                    title: "Nothing shared with you yet",
                    hint: "Open a guest link someone sent you, or paste it with Add Shared Agent."
                )
            } else {
                ForEach(directShares) { agent in
                    row(agent)
                }
            }
        }
    }

    private func row(_ agent: RemoteAgent) -> some View {
        let status: SharedAgentStatus = {
            _ = providers.providerStates
            return SharedAgentStatus.forDirectShareRow(agent)
        }()
        return SettingsRow(
            title: agent.name,
            verbatimTitle: true,
            leading: {
                AgentAvatarView(
                    mascotId: agent.avatar,
                    name: agent.name,
                    tint: theme.dataInk(seed: agent.name),
                    diameter: 26,
                    monogramFontSize: 11,
                    borderWidth: theme.stroke.default
                )
            },
            description: {
                Text(verbatim: detail(agent))
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    PresenceStatusChip(status)
                    if !isRevoked(status) {
                        SettingsButton(.secondary, "Open Chat", size: .compact) {
                            ChatWindowManager.shared.openChat(withWorkspaceAgentAddress: agent.agentAddress.lowercased(), workspaceId: "")
                        }
                    }
                    SettingsIconButton("trash", help: "Remove", size: .compact, isDestructive: true) {
                        confirmRemove(agent)
                    }
                }
            }
        )
    }

    private func isRevoked(_ status: SharedAgentStatus) -> Bool {
        if case .accessRevoked = status { return true }
        return false
    }

    private func detail(_ agent: RemoteAgent) -> String {
        var parts = [ParticipantFormatter.shortAddress(agent.agentAddress)]
        if let model = agent.model, !model.isEmpty { parts.append(model) }
        parts.append(String(format: L("Added %@"), agent.pairedAt.formatted(date: .abbreviated, time: .omitted)))
        return parts.joined(separator: " · ")
    }

    private func add() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), PairingDeepLinkRouter.handle(url) else {
            ToastManager.shared.error(L("Invalid invite"), message: L("Paste the whole guest link, starting with osaurus://"))
            return
        }
        isAdding = false
        link = ""
    }

    private func confirmRemove(_ agent: RemoteAgent) {
        ThemedAlertCenter.shared.confirmDestructive(
            scope: alertScope,
            title: L("Remove shared agent?"),
            message: String(
                format: L("%@ will disappear from this Mac. The owner can share it with you again with a new link."),
                agent.name
            ),
            destructiveTitle: L("Remove")
        ) {
            _ = RemoteAgentManager.shared.remove(id: agent.id)
        }
    }
}
