//
//  AgentKeysSection.swift
//  osaurus
//
//  The Keys list on an agent's Sandbox page: what this agent can read when
//  it runs commands or plugins, with its own values next to the shared ones.
//

import SwiftUI

struct AgentKeysSection: View {
    let agentId: UUID

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var entries: [AgentKeyEntry] = []
    @State private var editor: CredentialEditorRequest?
    @State private var pendingDelete: String?

    var body: some View {
        let ownCount = entries.filter { $0.source != .shared }.count

        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                SettingsFieldLabel("Keys")
                if ownCount > 0 {
                    CountBadge(ownCount)
                }
                Spacer()
                SettingsButton(.tertiary, "Open Vault", icon: "arrow.up.right", size: .compact) {
                    CredentialRegistry.shared.focusAgentId = agentId
                    ManagementStateManager.shared.selectedTab = .keys
                }
                SettingsButton(.secondary, "Add Key", icon: "plus", size: .compact) {
                    editor = CredentialEditorRequest(scope: .agent(agentId))
                }
            }

            Text(
                "Keys this agent can use when it runs commands or plugins in the sandbox. Keys shared with all agents apply unless this agent has its own value.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)

            if entries.isEmpty {
                SettingsEmptyState(
                    inline: "key.fill",
                    title: "No keys yet",
                    hint: "Add a key here or in the Vault, and turn on “Agents Can Use This When Running Code”.")
                    .settingsChrome(.inset)
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            ThemeHairlineDivider()
                                .padding(.leading, theme.space.s12)
                        }
                        row(entry)
                    }
                }
                .settingsChrome(.inset)
            }
        }
        .sheet(item: $editor) { request in
            CredentialEditorSheet(
                request: request,
                usedBy: CredentialRegistry.shared.rows.first { $0.key == request.key }?.usedBy ?? []
            ) {
                editor = nil
            }
        }
        .themedAlert(
            L("Remove \(pendingDelete ?? "")?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            message: L("This agent's value is deleted. A value shared with all agents applies again."),
            buttons: [
                .destructive(L("Remove")) {
                    if let key = pendingDelete { SandboxCredentials.delete(key, agentId: agentId) }
                    pendingDelete = nil
                },
                .cancel(L("Cancel")) { pendingDelete = nil },
            ]
        )
        .task(id: agentId) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange, object: CredentialStore.shared)) { _ in
            Task { await load() }
        }
    }

    /// Keychain account listing is a securityd round-trip that hung the
    /// appear path on slow machines, so entries are built off the main actor.
    private func load() async {
        let agentId = agentId
        let loaded = await Task.detached(priority: .userInitiated) {
            AgentKeyEntry.load(agentId: agentId, store: .current)
        }.value
        guard agentId == self.agentId else { return }
        entries = loaded
    }

    private func row(_ entry: AgentKeyEntry) -> some View {
        HStack(spacing: theme.space.s8) {
            LibraryIcon(
                symbol: entry.record?.origin.symbol ?? "clock.arrow.circlepath",
                tint: entry.record.map { theme.dataInk($0.origin.ink) } ?? theme.status.warning.foreground,
                size: 24)
            Text(verbatim: entry.key)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            StatusChip(entry.note, tone: entry.tone)
            Spacer(minLength: theme.space.s8)
            switch entry.source {
            case .shared:
                SettingsButton(.tertiary, "Use a Different Value", size: .compact) {
                    editor = .override(entry.record, key: entry.key, agentId: agentId)
                }
            case .own:
                SettingsButton(.tertiary, "Edit", size: .compact) {
                    if let record = entry.record { editor = .edit(record) }
                }
                SettingsIconButton("trash", help: L("Remove"), size: .compact, isDestructive: true) {
                    pendingDelete = entry.key
                }
            case .legacy:
                SettingsButton(.tertiary, "Set Again", size: .compact) {
                    editor = .override(nil, key: entry.key, agentId: agentId)
                }
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }
}

/// One key an agent's sandbox can read: its own value, a value shared with
/// all agents, or a value saved before Keys that has not been copied yet.
struct AgentKeyEntry: Identifiable, Equatable {
    enum Source: Equatable { case own, shared, legacy }

    var key: String
    var source: Source
    var record: CredentialRecord?
    var overridesShared = false

    var id: String { key }

    var note: String {
        switch source {
        case .own: return overridesShared ? L("Different value for this agent") : L("Only for this agent")
        case .shared: return L("Shared with all agents")
        case .legacy: return L("Saved before the Vault")
        }
    }

    var tone: StatusChip.Tone {
        switch source {
        case .own: return .accent
        case .shared: return .neutral
        case .legacy: return .warning
        }
    }

    static func load(agentId: UUID, store: CredentialStore) -> [AgentKeyEntry] {
        let own = store.records(in: .agent(agentId)).filter(\.exposeToSandbox)
        let ownKeys = Set(own.map(\.key))
        let globalKeys = Set(store.records(in: .global).map(\.key))
        var entries = own.map {
            AgentKeyEntry(key: $0.key, source: .own, record: $0, overridesShared: globalKeys.contains($0.key))
        }
        entries += store.records(in: .global)
            .filter { $0.exposeToSandbox && !ownKeys.contains($0.key) }
            .map { AgentKeyEntry(key: $0.key, source: .shared, record: $0) }
        let known = Set(entries.map(\.key))
        entries += CredentialResolver.availableKeys(agentId: agentId, store: store)
            .filter { !known.contains($0) }
            .map { AgentKeyEntry(key: $0, source: .legacy) }
        return entries.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}
