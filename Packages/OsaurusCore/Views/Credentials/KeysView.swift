//
//  KeysView.swift
//  osaurus
//
//  Management → Keys: the one place to find, set and edit every API key,
//  token and setting agents, tools and workflows use. Keys are shared by
//  all agents unless an agent has its own value. App keys (model providers,
//  web search, voice, downloads) are edited in place in their own stores;
//  Accounts lists every sign-in session and which agent uses which.
//

import SwiftUI

/// Tabs of the Keys page. Raw values are stable deep-link ids
/// (`keysSubTabRequest`, settings-search `subTab`).
enum KeysTab: String, CaseIterable, AnimatedTabItem {
    case keys
    case appKeys
    case accounts

    var title: String {
        switch self {
        case .keys: return L("Your Keys")
        case .appKeys: return L("App Keys")
        case .accounts: return L("Accounts")
        }
    }
}

struct KeysView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var registry = CredentialRegistry.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    @State private var tab: KeysTab = .keys
    @State private var search = ""
    /// nil shows the values for all agents; an id shows that agent's view.
    @State private var agentId: UUID?
    @State private var editor: CredentialEditorRequest?
    @State private var appKeyEditor: AppKeyRow?
    @State private var pendingDelete: CredentialRecord?
    @State private var pendingReset: CredentialRecord?
    @State private var revealed: [String: String] = [:]

    var body: some View {
        SettingsPage {
            header
        } content: {
            ForEach(Array(registry.loadIssues.enumerated()), id: \.offset) { _, issue in
                loadIssueCallout(issue)
            }
            switch tab {
            case .keys:
                if !filteredMissing.isEmpty { missingSection }
                keysSection
            case .appKeys:
                appKeysSection
            case .accounts:
                accountsSection
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .sheet(item: $editor) { request in
            CredentialEditorSheet(request: request, usedBy: usedBy(request.existingKey ?? request.key)) {
                editor = nil
            }
        }
        .sheet(item: $appKeyEditor) { row in
            AppKeyEditorSheet(row: row) { appKeyEditor = nil }
        }
        .themedAlert(
            L("Delete “\(pendingDelete?.key ?? "")”?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            message: deleteMessage,
            buttons: [
                .destructive(L("Delete")) {
                    if let record = pendingDelete { delete(record) }
                    pendingDelete = nil
                },
                .cancel(L("Cancel")) { pendingDelete = nil },
            ])
        .themedAlert(
            L("Remove this agent's own value?"),
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            message: resetMessage,
            buttons: [
                .destructive(L("Remove Own Value")) {
                    if let record = pendingReset { delete(record) }
                    pendingReset = nil
                },
                .cancel(L("Cancel")) { pendingReset = nil },
            ])
        .onAppear {
            applySubTabRequest(managementState.keysSubTabRequest)
            if let focus = registry.focusAgentId {
                tab = .keys
                agentId = focus
                registry.focusAgentId = nil
            }
            registry.isPageVisible = true
            registry.refresh(full: true)
        }
        .onChange(of: managementState.keysSubTabRequest) { _, request in
            applySubTabRequest(request)
        }
        .onChange(of: registry.focusAgentId) { _, focus in
            guard let focus else { return }
            tab = .keys
            agentId = focus
            registry.focusAgentId = nil
        }
        .onDisappear { registry.isPageVisible = false }
    }

    private func applySubTabRequest(_ request: String?) {
        guard let request else { return }
        if let requested = KeysTab(rawValue: request) { tab = requested }
        managementState.keysSubTabRequest = nil
    }

    private func loadIssueCallout(_ issue: CredentialLoadIssue) -> some View {
        let message: String
        switch issue {
        case .indexRebuilt(_, let recovered):
            message = L(
                "The saved list of keys couldn't be read, so it was rebuilt from the Keychain (\(recovered) hidden values found). Descriptions and visible values are in the backup copy.")
        case .indexRecoveryPending:
            message = L(
                "The saved list of keys couldn't be read. Unlock your Mac to rebuild it from the Keychain; nothing is changed until then.")
        case .bindingsReset:
            message = L(
                "The record of which key each tool uses couldn't be read and was reset. Tools now use their suggested key names.")
        }
        return SettingsCallout(icon: "exclamationmark.triangle.fill", title: "Keys Needed Repair", message: message, tone: .warning) {
            if let backup = issue.backup {
                SettingsButton(.secondary, "Show Backup", size: .compact) {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        SettingsPageHeader(
            title: "Vault",
            subtitle: "API keys, tokens, sign-ins, and settings your agents, tools, and workflows use.",
            count: ManagementBadgeStore.shared.headerCount(for: .keys),
            primary: {
                SettingsButton(.primary, "Add Key", icon: "plus") {
                    tab = .keys
                    editor = CredentialEditorRequest(scope: agentId.map { .agent($0) } ?? .global)
                }
                .settingsLandingAnchor("keys.add")
            },
            toolbar: {
                SettingsTabsRow(
                    selection: $tab,
                    counts: query.isEmpty ? nil : matchCounts,
                    badges: attentionBadges,
                    searchText: $search,
                    searchPlaceholder: "Search keys"
                ) {
                    if tab != .appKeys, !agentManager.agents.isEmpty {
                        agentScopePicker
                    }
                }
                .settingsLandingAnchor("keys.search")
            }
        )
    }

    /// While searching, every tab shows how many of its items match, so a
    /// hit on another tab is never hidden.
    private var matchCounts: [KeysTab: Int] {
        [.keys: filteredRows.count + filteredMissing.count, .appKeys: filteredAppKeys.count, .accounts: VaultAccountsView.matchCount(query: query)]
    }

    private var attentionBadges: [KeysTab: Int] {
        [.keys: registry.missing.count, .accounts: registry.signedInAccounts.filter { !$0.isSignedIn }.count]
    }

    /// Scopes the key list to one agent's overrides, or the account list to
    /// the sessions one agent uses.
    private var agentScopePicker: some View {
        SettingsMenuPicker(selection: $agentId, options: agentOptions)
            .settingsLandingAnchor(tab == .accounts ? "keys.accounts.agent" : "keys.agentOverrides")
    }

    private var agentOptions: [SettingsPickerRow<UUID?>.Option] {
        [.init(nil, L("All agents"), verbatim: true)]
            + agentManager.agents.map { .init($0.id, $0.displayName, verbatim: true) }
    }

    private var selectedAgentName: String {
        agentId.flatMap { agentManager.agent(for: $0)?.displayName } ?? L("this agent")
    }

    // MARK: - Search

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func matches(_ fields: String...) -> Bool {
        query.isEmpty || fields.contains { $0.lowercased().contains(query) }
    }

    private var filteredMissing: [CredentialMissingKey] {
        registry.missing.filter { matches($0.key, $0.slot.consumer, $0.slot.field) }
    }

    private var filteredAppKeys: [AppKeyRow] {
        registry.appKeys.filter { matches($0.title, $0.detail, $0.purpose ?? "", $0.group.rawValue) }
    }

    private var filteredRows: [CredentialKeyRow] {
        registry.rows.filter { row in
            if let agentId {
                guard row.global != nil || row.record(for: agentId) != nil else { return false }
            } else if row.global == nil, row.agentRecords.isEmpty {
                return false
            }
            let descriptions = ([row.global] + row.agentRecords).compactMap { $0?.description }
            return matches(row.key, descriptions.joined(separator: " "), row.usedBy.map(\.consumer).joined(separator: " "))
        }
    }

    private func usedBy(_ key: String) -> [CredentialSlot] {
        registry.rows.first { $0.key == key }?.usedBy ?? []
    }

    private var noMatches: some View {
        SettingsEmptyState(inline: "magnifyingglass", title: "No keys match.")
    }

    // MARK: - Missing keys

    private var missingSection: some View {
        SettingsSection(
            title: "Missing Keys",
            subtitle: "Something you set up needs a key before it can run.",
            anchorId: "keys.missing"
        ) {
            ForEach(filteredMissing) { missing in
                LibraryRow(
                    title: missing.slot.consumer,
                    subtitle: missingSubtitle(missing),
                    action: { editor = .fill(missing) },
                    leading: {
                        LibraryIcon(
                            symbol: missing.slot.category.origin.symbol, tint: theme.status.warning.foreground, size: 32)
                    },
                    trailing: {
                        SettingsButton(.primary, "Set", size: .compact) { editor = .fill(missing) }
                    }
                )
            }
        }
    }

    /// What needs the key, and which agents already have their own value,
    /// so a key set for one agent does not read as working everywhere.
    private func missingSubtitle(_ missing: CredentialMissingKey) -> String {
        var parts = [L("Needs \(missing.key) to run"), missing.slot.category.label]
        let names = missing.agentsWithOwnValue.compactMap { agentManager.agent(for: $0)?.displayName }
        if !names.isEmpty {
            parts.append(L("Set only for \(names.joined(separator: ", ")); runs without an agent need a shared value"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Keys

    private var keysSection: some View {
        SettingsSection(
            title: agentId == nil ? "All Agents" : "Keys for \(selectedAgentName)",
            subtitle: agentId == nil
                ? "Shared by every agent unless an agent has its own value."
                : "Pick a key to give \(selectedAgentName) a different value.",
            anchorId: "keys.allAgents",
            verbatimTitle: agentId != nil
        ) {
            if filteredRows.isEmpty {
                if query.isEmpty {
                    SettingsEmptyState(
                        inline: "key.fill",
                        title: "No keys yet",
                        hint: "Add an API key, token or setting once, and every agent can use it.",
                        action: .init(title: L("Add Key"), icon: "plus") {
                            editor = CredentialEditorRequest(scope: agentId.map { .agent($0) } ?? .global)
                        })
                } else {
                    noMatches
                }
            } else {
                ForEach(filteredRows) { row in
                    if let agentId {
                        agentRow(row, agentId: agentId)
                    } else {
                        globalRow(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func globalRow(_ row: CredentialKeyRow) -> some View {
        if let record = row.global {
            keyRow(record: record, row: row, scopeNote: overridesNote(row))
        }
        ForEach(row.global == nil ? row.agentRecords : []) { record in
            keyRow(record: record, row: row, scopeNote: onlyForNote(record))
        }
    }

    @ViewBuilder
    private func agentRow(_ row: CredentialKeyRow, agentId: UUID) -> some View {
        if let own = row.record(for: agentId) {
            keyRow(
                record: own, row: row,
                scopeNote: row.global == nil ? L("Only for \(selectedAgentName)") : L("Different value for this agent"),
                resetsToGlobal: row.global != nil)
        } else if let global = row.global {
            keyRow(record: global, row: row, scopeNote: L("Same as all agents"), overrideFor: agentId)
        }
    }

    private func overridesNote(_ row: CredentialKeyRow) -> String? {
        let names = row.agentRecords.compactMap { $0.scope.agentId.flatMap { agentManager.agent(for: $0)?.displayName } }
        guard !names.isEmpty else { return nil }
        return L("Different value for \(names.joined(separator: ", "))")
    }

    private func onlyForNote(_ record: CredentialRecord) -> String {
        let name = record.scope.agentId.flatMap { agentManager.agent(for: $0)?.displayName } ?? L("a deleted agent")
        return L("Only for \(name)")
    }

    /// One key: what it belongs to, its value, and quick Show / Copy.
    /// Clicking the row edits it, or in an agent's view of a shared key,
    /// gives that agent its own value.
    private func keyRow(
        record: CredentialRecord, row: CredentialKeyRow, scopeNote: String?,
        overrideFor: UUID? = nil, resetsToGlobal: Bool = false
    ) -> some View {
        LibraryRow(
            title: record.key,
            subtitle: detailLine(record: record, row: row, scopeNote: scopeNote),
            action: {
                if let overrideFor {
                    editor = .override(record, key: record.key, agentId: overrideFor)
                } else {
                    editor = .edit(record)
                }
            },
            leading: {
                LibraryIcon(symbol: record.origin.symbol, tint: theme.dataInk(record.origin.ink), size: 32)
            },
            badges: {
                if record.exposeToSandbox {
                    StatusChip(L("Code"), icon: "terminal", help: L("Available to agents' code as an environment variable."))
                }
            },
            trailing: {
                HStack(spacing: theme.space.s6) {
                    KeyValuePill(
                        value: record.kind == .variable ? record.variableValue : revealed[record.id],
                        isHidden: record.kind == .secret)
                    if record.kind == .secret {
                        SettingsIconButton(
                            revealed[record.id] == nil ? "eye" : "eye.slash",
                            help: revealed[record.id] == nil ? L("Show") : L("Hide"),
                            size: .compact
                        ) { toggleReveal(record) }
                    }
                    SettingsIconButton("doc.on.doc", help: L("Copy"), size: .compact) { copy(record) }
                    if let overrideFor {
                        SettingsButton(.secondary, "Use a Different Value", size: .compact) {
                            editor = .override(record, key: record.key, agentId: overrideFor)
                        }
                    }
                }
            },
            menu: {
                if overrideFor == nil {
                    Button(L("Edit…")) { editor = .edit(record) }
                }
                if overrideFor == nil, record.scope == .global {
                    Menu(L("Use a Different Value For")) {
                        ForEach(agentManager.agents.filter { row.record(for: $0.id) == nil }) { agent in
                            Button(agent.displayName) {
                                editor = .override(record, key: record.key, agentId: agent.id)
                            }
                        }
                    }
                }
                Button(record.exposeToSandbox ? L("Stop Agents Using This in Code") : L("Let Agents Use This in Code")) {
                    CredentialStore.current.updateMetadata(
                        record.key, scope: record.scope, exposeToSandbox: !record.exposeToSandbox)
                }
                if resetsToGlobal {
                    Button(L("Use the Value for All Agents…")) { pendingReset = record }
                } else if overrideFor == nil {
                    Divider()
                    Button(L("Delete…"), role: .destructive) { pendingDelete = record }
                }
            }
        )
    }

    private func detailLine(record: CredentialRecord, row: CredentialKeyRow, scopeNote: String?) -> String {
        var parts: [String] = []
        if !record.description.isEmpty { parts.append(record.description) }
        if let scopeNote { parts.append(scopeNote) }
        if !row.usedBy.isEmpty {
            parts.append(L("Used by \(row.usedBy.map(\.consumer).uniqued().joined(separator: ", "))"))
        }
        return parts.joined(separator: " · ")
    }

    private func delete(_ record: CredentialRecord) {
        let key = record.key
        let scope = record.scope
        Task { @MainActor in
            let outcome = await CredentialStore.current.perform { $0.delete(key, scope: scope) }
            if let failure = outcome.failureDescription {
                _ = ToastManager.shared.error(L("Couldn't delete \(key)"), message: failure)
            }
        }
    }

    private var deleteMessage: String? {
        guard let record = pendingDelete else { return nil }
        let users = usedBy(record.key).map(\.consumer).uniqued()
        let fallsBackToShared = record.scope != .global && registry.rows.first { $0.key == record.key }?.global != nil
        guard !fallsBackToShared, !users.isEmpty else { return L("This can't be undone.") }
        let names = users.joined(separator: ", ")
        if let agentId = record.scope.agentId {
            let agent = agentManager.agent(for: agentId)?.displayName ?? L("this agent")
            return L("\(names) will stop working for \(agent) until you set \(record.key) again.")
        }
        return L("\(names) will stop working until you set \(record.key) again.")
    }

    private var resetMessage: String? {
        guard let record = pendingReset, let agentId = record.scope.agentId else { return nil }
        let agent = agentManager.agent(for: agentId)?.displayName ?? L("this agent")
        return L("\(agent)'s own value for \(record.key) is deleted and it uses the value shared by all agents.")
    }

    // MARK: - Show / Copy

    private func readValue(_ record: CredentialRecord) async -> String? {
        if record.kind == .variable { return record.variableValue }
        let key = record.key
        let scope = record.scope
        return await CredentialReveal.read(reason: L("show the value of \(key)")) {
            CredentialStore.current.value(key, scope: scope)
        }
    }

    private func toggleReveal(_ record: CredentialRecord) {
        if revealed[record.id] != nil {
            revealed[record.id] = nil
            return
        }
        Task { @MainActor in
            guard let value = await readValue(record) else { return }
            revealed[record.id] = value
            try? await Task.sleep(for: CredentialReveal.remaskAfter)
            if revealed[record.id] == value { revealed[record.id] = nil }
        }
    }

    private func copy(_ record: CredentialRecord) {
        Task { @MainActor in
            guard let value = await readValue(record) else { return }
            CredentialReveal.copy(value)
            _ = ToastManager.shared.success(L("Copied \(record.key)"))
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VaultAccountsView(agentId: $agentId, query: query)
    }

    // MARK: - App keys

    private var appKeysSection: some View {
        SettingsSection(
            footer: "Keys Osaurus itself uses. They are the same for every agent.",
            anchorId: "keys.appKeys",
            layout: .plain
        ) {
            if filteredAppKeys.isEmpty {
                noMatches.settingsChrome(.card)
            }
            ForEach(AppKeyRow.Group.allCases, id: \.self) { group in
                let rows = filteredAppKeys.filter { $0.group == group }
                if !rows.isEmpty {
                    SettingsSection(title: group.rawValue, verbatimTitle: false) {
                        ForEach(rows) { row in
                            LibraryRow(
                                title: row.title,
                                subtitle: [row.detail, row.purpose].compactMap { $0 }.joined(separator: "\n"),
                                anchorId: row.store == .tts ? "keys.appKeys.tts" : nil,
                                action: { appKeyEditor = row },
                                leading: { LibraryIcon(symbol: group.symbol, tint: theme.dataInk(group.ink), size: 32) },
                                trailing: {
                                    HStack(spacing: theme.space.s8) {
                                        StatusChip(
                                            row.isSet ? L("Set") : L("Not set"),
                                            tone: row.isSet ? .success : .neutral, showsDot: row.isSet)
                                        SettingsButton(.secondary, row.isSet ? "Edit" : "Set", size: .compact) {
                                            appKeyEditor = row
                                        }
                                    }
                                },
                                menu: {
                                    Button(row.isSet ? L("Edit…") : L("Set…")) { appKeyEditor = row }
                                    if let destination = row.destination {
                                        Button(destination.title) { SettingsLanding.open(id: destination.settingId) }
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App key editor

struct AppKeyEditorSheet: View {
    let row: AppKeyRow
    let onClose: () -> Void

    @State private var value = ""
    @State private var current: String?
    @State private var isSaving = false
    @State private var error: String?

    private func save(_ value: String) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task { @MainActor in
            let saved = await AppKeys.save(value, to: row.store)
            isSaving = false
            if saved { onClose() } else { error = L("The Keychain didn't save this change. Try again.") }
        }
    }

    var body: some View {
        SettingsSheet(
            icon: row.group.symbol,
            title: LocalizedStringKey(row.title),
            subtitle: LocalizedStringKey(row.purpose ?? row.detail),
            primary: .init(
                label: "Save", isEnabled: !isSaving && !value.trimmingCharacters(in: .whitespaces).isEmpty
            ) { save(value) },
            secondary: .init(label: "Cancel", handler: onClose),
            warning: error,
            onClose: onClose
        ) {
            SettingsSection(title: "Value") {
                SettingsFieldRow(label: row.detail, verbatimLabel: true) {
                    SettingsTextField(
                        placeholder: row.isSet ? L("Enter a new value") : L("Paste the key"),
                        text: $value, monospaced: true, isSecure: true, revealable: true)
                }
                if row.isSet {
                    SettingsRow(title: "Current Value") {
                        KeyValuePill(value: current, isHidden: true)
                    } trailing: {
                        SettingsButton(.tertiary, current == nil ? "Show" : "Hide", size: .compact) {
                            if current != nil {
                                current = nil
                            } else {
                                let store = row.store
                                Task { @MainActor in
                                    let shown = await CredentialReveal.read(reason: L("show \(row.title) \(row.detail)")) {
                                        AppKeys.value(store)
                                    }
                                    current = shown
                                    guard shown != nil else { return }
                                    try? await Task.sleep(for: CredentialReveal.remaskAfter)
                                    if current == shown { current = nil }
                                }
                            }
                        }
                    }
                }
            }
            if let destination = row.destination {
                SettingsSection(title: "Where It's Used") {
                    SettingsLinkRow(title: destination.place, actionTitle: "Open") {
                        onClose()
                        SettingsLanding.open(id: destination.settingId)
                    }
                }
            }
            if row.isSet {
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Remove", description: L("Features that use this key stop working until you set it again."),
                        actionTitle: "Remove"
                    ) {
                        save("")
                    }
                }
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
