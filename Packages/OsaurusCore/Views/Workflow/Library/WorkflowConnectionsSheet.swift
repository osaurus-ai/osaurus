//
//  WorkflowConnectionsSheet.swift
//  osaurus
//
//  The Workflows window's Connections: the sign-ins installed workflows
//  use, with Sign In Again right here, and the connections a workflow's
//  setup still needs. Renaming, removing, and choosing which agent uses
//  which session stay in Vault → Accounts.
//

import SwiftUI

struct WorkflowConnectionsSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var connections = WorkflowConnectionStore.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var sessions = SignInSessionStore.shared

    let onSetUp: (InstalledWorkflow) -> Void
    let onClose: () -> Void

    @State private var busy: [UUID: Task<Void, Never>] = [:]
    @State private var replacing: SignInSession?
    /// Bumped after a sign-in so Keychain-backed status reads again.
    @State private var refreshTick = 0

    private var overview: WorkflowConnectionOverview {
        _ = refreshTick
        return WorkflowConnectionOverview.build(
            connections: connections.connections, workflows: installed.workflows,
            hasValue: { connections.hasValue($0) },
            isSetUp: { WorkflowCredentials.isSetUp(scope: $0, key: $1) })
    }

    var body: some View {
        let overview = overview
        SettingsSheet(
            icon: "link",
            title: "Connections",
            subtitle: "The services your workflows sign in to. Sign in again here when one expires.",
            width: SettingsSheetWidth.regular,
            secondary: .init(label: "Done", handler: close),
            onClose: close
        ) {
            if !overview.needs.isEmpty {
                SettingsSection(title: "Needs Setup") {
                    ForEach(overview.needs) { need in needRow(need) }
                }
            }
            SettingsSection(title: "Sign-Ins") {
                if overview.entries.isEmpty {
                    SettingsEmptyState(
                        inline: "link", title: "No sign-ins yet",
                        hint: "A workflow that logs in to a service asks for it while you set it up.")
                }
                ForEach(overview.entries) { entry in entryRow(entry) }
            }
            SettingsSection(title: "Vault") {
                SettingsLinkRow(
                    title: "Manage All Sign-Ins in Vault",
                    description: "Rename or remove sessions, and choose which agent uses which.",
                    actionTitle: "Open Vault",
                    action: openVault)
            }
        }
        .onAppear { connections.loadIfNeeded() }
        .sheet(item: $replacing) { session in
            VaultSessionSheet(mode: .replace(session)) {
                replacing = nil
                refreshTick += 1
            }
            .environment(\.theme, theme)
        }
    }

    // MARK: Rows

    private func entryRow(_ entry: WorkflowConnectionOverview.Entry) -> some View {
        let connection = entry.connection
        let isBusy = busy[connection.id] != nil
        return LibraryRow(
            title: connection.name,
            subtitle: subtitle(entry),
            leading: {
                LibraryIcon(
                    symbol: WorkflowConnectionActions.pastesValue(connection) ? "key.fill" : "person.badge.key.fill",
                    tint: theme.text.link, size: 32)
            },
            badges: { statusChip(entry.status) },
            trailing: {
                if isBusy {
                    SettingsButton(.secondary, "Cancel", isLoading: true, size: .compact) { cancel(connection.id) }
                } else {
                    SettingsButton(
                        entry.status == .ready ? .secondary : .primary,
                        WorkflowConnectionActions.pastesValue(connection) ? "Replace Value" : "Sign In Again",
                        size: .compact
                    ) { renew(connection) }
                }
            }
        )
    }

    private func needRow(_ need: WorkflowConnectionOverview.Need) -> some View {
        let service = need.secret.provider.flatMap(ConnectionProviders.provider(id:))?.name
            ?? need.secret.serviceHost ?? need.secret.label
        return LibraryRow(
            title: need.workflowName,
            subtitle: L("Needs a sign-in to \(service) for \(need.secret.label)."),
            leading: { LibraryIcon(symbol: "exclamationmark.triangle.fill", tint: theme.status.warning.foreground, size: 32) },
            trailing: {
                SettingsButton(.primary, "Set Up", icon: "checklist", size: .compact) { setUp(need.workflowID) }
            }
        )
    }

    private func subtitle(_ entry: WorkflowConnectionOverview.Entry) -> String {
        var parts: [String] = []
        if let host = entry.connection.service { parts.append(host) }
        parts.append(
            entry.workflows.isEmpty
                ? L("Not used by a workflow") : L("Used by \(WorkflowSummary.list(entry.workflows))"))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusChip(_ status: WorkflowConnectionOverview.Entry.Status) -> some View {
        switch status {
        case .ready: StatusChip(L("Signed in"), tone: .success, showsDot: true)
        case .signInExpired: StatusChip(L("Sign-in expired"), tone: .warning, showsDot: true)
        case .noValue: StatusChip(L("No value"), tone: .warning, showsDot: true)
        }
    }

    // MARK: Actions

    private func renew(_ connection: WorkflowConnection) {
        if WorkflowConnectionActions.pastesValue(connection) {
            replacing = sessions.session(id: connection.id)
            return
        }
        guard busy[connection.id] == nil else { return }
        busy[connection.id] = Task { @MainActor in
            defer { refreshTick += 1 }
            do {
                try await WorkflowConnectionActions.signInAgain(connection)
                NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    _ = ToastManager.shared.error(
                        L("Couldn't sign in to \(connection.name)"), message: WorkflowErrorText.text(error))
                }
            }
            if !Task.isCancelled { busy[connection.id] = nil }
        }
    }

    private func cancel(_ id: UUID) {
        busy[id]?.cancel()
        busy[id] = nil
        refreshTick += 1
    }

    private func setUp(_ workflowID: UUID) {
        guard let workflow = installed.workflow(id: workflowID) else { return }
        close()
        onSetUp(workflow)
    }

    private func openVault() {
        close()
        let state = ManagementStateManager.shared
        state.keysSubTabRequest = KeysTab.accounts.rawValue
        state.selectedTab = .keys
        AppDelegate.shared?.showManagementWindow(initialTab: .keys)
    }

    /// A waiting sign-in holds the redirect port, so closing cancels it.
    private func close() {
        for task in busy.values { task.cancel() }
        busy = [:]
        onClose()
    }
}
