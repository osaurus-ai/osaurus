//
//  AgentSharedWithSection.swift
//  osaurus
//
//  "Shared with" card on a local agent's Network tab: the workspaces this
//  agent is shared into (from the roster store), each with `Open workspace`
//  and `Unshare`. Localizes roster observation so the parent detail view
//  doesn't re-render on every roster refresh.
//

import SwiftUI

struct AgentSharedWithSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared
    @ObservedObject private var workspacesService = WorkspacesService.shared

    let agent: Agent

    private var address: String? { agent.agentAddress }

    private var sharedWorkspaces: [OsaurusRouterWorkspaceSummary] {
        AgentSharedWithSection.sharedWorkspaces(for: agent, rosterStore: rosterStore)
    }

    /// Workspaces the user could still share this agent into.
    private var shareableWorkspaces: [OsaurusRouterWorkspaceSummary] {
        AgentSharedWithSection.shareableWorkspaces(
            for: agent,
            workspaces: workspacesService.workspaces,
            rosterStore: rosterStore
        )
    }

    var body: some View {
        AgentDetailSection(
            title: L("Shared with"),
            icon: "person.2.fill",
            subtitle: sharedWorkspaces.isEmpty ? nil : "\(sharedWorkspaces.count)",
            trailing: {
                if !shareableWorkspaces.isEmpty {
                    Menu {
                        ForEach(shareableWorkspaces) { workspace in
                            Button {
                                RemoteAgentWorkspaceAttribution.openWorkspace(id: workspace.id)
                            } label: {
                                Text(workspace.name)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Share to workspace…", bundle: .module)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                }
            }
        ) {
            if !OsaurusRouter.isEnabled {
                AgentSectionEmptyState(
                    icon: "rectangle.3.group",
                    title: "Workspaces need Osaurus Router",
                    hint: "Turn on Router in Settings to share this agent with a workspace.",
                    actionLabel: "Open Router settings",
                    action: {
                        ManagementStateManager.shared.selectedTab = .settings
                    }
                )
            } else if sharedWorkspaces.isEmpty {
                AgentSectionEmptyState(
                    icon: "person.2",
                    title: "Not shared with any workspace",
                    hint: shareableWorkspaces.isEmpty
                        ? "Join or create a workspace, then share this agent from its Shared Agents tab."
                        : "Teammates in a workspace can chat with this agent while it runs on this Mac."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(sharedWorkspaces) { workspace in
                        workspaceRow(workspace)
                    }
                }
                Text(
                    "Teammates reach this agent through its relay tunnel. Turning the relay off or deleting the agent cuts them off.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func workspaceRow(_ workspace: OsaurusRouterWorkspaceSummary) -> some View {
        let sharedAs = address.flatMap { addr in
            rosterStore.agent(forAddress: addr, workspaceId: workspace.id)?.displayName
        }
        let isBusy = address.map { workspacesService.isBusy("agent.\($0.lowercased())") } ?? false
        return HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: nil,
                name: workspace.name,
                tint: agentColorFor(workspace.name),
                diameter: 28,
                monogramFontSize: 12,
                borderWidth: 1.5
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let role = workspace.typedRole {
                        CapsuleBadge(role.displayName, tint: theme.secondaryText, style: .tag)
                    }
                }
                if let sharedAs, sharedAs != agent.name {
                    Text(String(format: L("shared as “%@”"), sharedAs))
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                RemoteAgentWorkspaceAttribution.openWorkspace(id: workspace.id)
            } label: {
                Text("Open workspace", bundle: .module)
            }
            .buttonStyle(SecondaryButtonStyle(size: .compact))
            Button {
                confirmUnshare(from: workspace)
            } label: {
                Text("Unshare", bundle: .module)
            }
            .buttonStyle(DestructiveButtonStyle(isLoading: isBusy, size: .compact))
            .disabled(isBusy)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.5))
        )
    }

    private func confirmUnshare(from workspace: OsaurusRouterWorkspaceSummary) {
        guard let address else { return }
        ThemedAlertCenter.shared.confirmDestructive(
            scope: alertScope,
            title: String(format: L("Unshare %@?"), agent.name),
            message: String(
                format: L("Teammates in %@ will lose access immediately; their conversations stay readable."),
                workspace.name
            ),
            destructiveTitle: L("Unshare")
        ) {
            Task {
                _ = await WorkspacesService.shared.unshareAgent(
                    workspaceId: workspace.id,
                    agentAddress: address
                )
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Workspaces whose roster lists this agent's address.
    static func sharedWorkspaces(
        for agent: Agent,
        rosterStore: WorkspaceRosterStore
    ) -> [OsaurusRouterWorkspaceSummary] {
        guard let address = agent.agentAddress else { return [] }
        return rosterStore.workspacesSharing(agentAddress: address)
    }

    /// Workspaces the user can share into that don't already list the agent.
    static func shareableWorkspaces(
        for agent: Agent,
        workspaces: [OsaurusRouterWorkspaceSummary],
        rosterStore: WorkspaceRosterStore
    ) -> [OsaurusRouterWorkspaceSummary] {
        let shared = Set(sharedWorkspaces(for: agent, rosterStore: rosterStore).map(\.id))
        return workspaces.filter { workspace in
            !shared.contains(workspace.id) && (workspace.typedRole?.canShareAgents ?? false)
        }
    }
}
