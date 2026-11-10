//
//  WorkspaceWorkflowsSection.swift
//  osaurus
//
//  The workflows and agent templates members shared with one workspace
//  (`GET /workspaces/:id/workflows` on the store registry). Any member can
//  install a copy, viewers included; each one runs on the installer's own
//  Mac. The author, and the workspace's owners and admins, can take a
//  listing out. Sharing happens from a template's Share sheet (Who can see
//  it, Workspace). The list comes from `WorkspaceWorkflowCatalog`, which
//  the Workflows window's Workspaces tab shares.
//

import SwiftUI

struct WorkspaceWorkflowsSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var templates = TemplateStore.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var catalog = WorkspaceWorkflowCatalog.shared

    let workspaceId: String
    let workspaceActive: Bool
    /// Owner or admin: may take anyone's listing out.
    let canModerate: Bool

    @State private var actionError: String?
    @State private var removingID: String?
    @State private var pendingRemoval: WorkflowsRegistryWorkspaceItem?

    private var entry: WorkspaceWorkflowCatalog.Entry { catalog.entry(workspaceId) }
    private var items: [WorkflowsRegistryWorkspaceItem] { entry.listings }
    private var isLoading: Bool { entry.state == .loading }
    private var loadError: String? {
        if case .failed(let message) = entry.state { return message }
        return nil
    }

    private var myAddress: String? { OsaurusRouterWalletCache.lastSignedAddress?.lowercased() }

    var body: some View {
        SettingsSection(
            title: "Workflows",
            caption: items.isEmpty ? nil : "\(items.count)",
            accessory: {
                HStack(spacing: theme.space.s6) {
                    SettingsButton(.tertiary, "Open in Workflows", icon: "arrow.up.forward.app", size: .extraSmall) {
                        ChatWindowManager.shared.showWorkflowsSurface(destination: .workspace(workspaceId))
                    }
                    SettingsIconButton("arrow.clockwise", isLoading: isLoading, help: "Refresh") {
                        Task { await catalog.refresh(workspaceId, force: true) }
                    }
                }
            }
        ) {
            if let error = actionError ?? loadError {
                InlineBanner(kind: .error, title: error) { actionError = nil }
            }
            if items.isEmpty {
                if isLoading || entry.fetchedAt == nil {
                    SettingsEmptyState(loading: "Loading workflows…")
                } else {
                    SettingsEmptyState(
                        inline: "square.stack.3d.up",
                        title: "No workflows shared yet",
                        hint:
                            "Share a workflow or agent here from its Share sheet: Who can see it, then Workspace. Members install their own copy."
                    )
                }
            } else {
                VStack(spacing: theme.space.s8) {
                    ForEach(items) { item in row(item) }
                }
            }
        }
        .settingsLandingAnchor("workspaces.workflows")
        .task(id: workspaceId) { await catalog.refresh(workspaceId) }
        .themedAlert(
            L("Remove from Workspace?"),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            message: pendingRemoval.map {
                String(
                    format: L("Members stop seeing “%@” here. Copies already installed keep working."), $0.name)
            },
            primaryButton: .destructive(L("Remove")) {
                guard let item = pendingRemoval else { return }
                pendingRemoval = nil
                remove(item)
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private func row(_ item: WorkflowsRegistryWorkspaceItem) -> some View {
        let isMine = item.author.address.lowercased() == myAddress
        let state = catalog.installState(for: item)
        return HStack(alignment: .top, spacing: theme.space.s8) {
            SettingsIconTile(icon: item.kind == .agent ? "person.crop.circle" : "square.stack.3d.up", size: 30)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: item.name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if isMine { StatusChip(L("Yours"), tone: .accent) }
                    switch state {
                    case .update: StatusChip(L("Update"), tone: .info)
                    case .installed: StatusChip(L("Installed"), tone: .success)
                    case .setUp: StatusChip(L("Needs setup"), tone: .warning)
                    case .notInstalled: EmptyView()
                    }
                }
                Text(
                    verbatim: [
                        item.kind == .agent ? L("Agent") : L("Workflow"), item.author.handle,
                        L("Version \(item.latestVersion)"),
                    ].joined(separator: " · ")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                if !item.summary.isEmpty {
                    Text(verbatim: item.summary)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: theme.space.s6) {
                if state != .installed, state != .setUp {
                    Button {
                        TemplateImportRouter.importRegistryFile(item.rawURL, workspaceID: workspaceId)
                    } label: {
                        Text(state == .notInstalled ? "Install" : "Update", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(!workspaceActive)
                }
                if isMine || canModerate {
                    SettingsIconButton(
                        "minus.circle", isLoading: removingID == item.id, help: "Remove from workspace"
                    ) { pendingRemoval = item }
                }
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private func remove(_ item: WorkflowsRegistryWorkspaceItem) {
        let isMine = item.author.address.lowercased() == myAddress
        removingID = item.id
        Task { @MainActor in
            defer { removingID = nil }
            do {
                try await WorkflowShareService.shared.unshare(
                    registryID: item.id, fromWorkspace: workspaceId, moderating: !isMine)
                catalog.removeListing(item.id, from: workspaceId)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
