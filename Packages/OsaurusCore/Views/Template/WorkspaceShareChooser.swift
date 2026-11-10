//
//  WorkspaceShareChooser.swift
//  osaurus
//
//  Which workspaces a Workspace listing is shared with. Owners, admins,
//  and members of an active workspace can share; viewers only install.
//  Used by the share sheet and the published dashboard.
//

import SwiftUI

struct WorkspaceShareChooser: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var workspaces = WorkspacesService.shared

    @Binding var selection: Set<String>

    /// Workspaces this Mac's wallet may share a listing with.
    static func eligible(_ list: [OsaurusRouterWorkspaceSummary]) -> [OsaurusRouterWorkspaceSummary] {
        list.filter { $0.typedRole?.canShareAgents == true && $0.active != false && !$0.isSuspended }
    }

    /// Whether the Workspace option has anywhere to go.
    @MainActor static var isAvailable: Bool { !eligible(WorkspacesService.shared.workspaces).isEmpty }

    private var choices: [OsaurusRouterWorkspaceSummary] { Self.eligible(workspaces.workspaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if choices.isEmpty {
                Text(
                    "You're not in a workspace you can share with. Create or join one in Settings, Workspaces. Viewers can install a workspace's workflows but not share.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(choices) { workspace in
                    ShareOptionRow(
                        icon: "person.2", title: workspace.name,
                        detail: workspace.typedRole?.displayName ?? workspace.role,
                        isSelected: selection.contains(workspace.id),
                        isEnabled: selection.contains(workspace.id) || selection.count < WorkflowVisibility.maxWorkspaces,
                        action: { toggle(workspace.id) })
                }
                Text(
                    "Members install their own copy and run it on their Mac. Viewers can install it too.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, theme.space.s2)
        .task {
            if !workspaces.hasLoadedWorkspaces { await workspaces.refreshWorkspaces() }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(theme.motion.quick) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }
}
