//
//  VaultAccountsView.swift
//  osaurus
//
//  Vault → Accounts: every sign-in, grouped by the service it signs in to.
//  A service can have several sessions (two Linear accounts, a second
//  Discord bot); one is its default, and each agent can be given its own.
//  Agents without one, the Orchestrator, and runs on shared keys use the
//  default.
//

import AppKit
import SwiftUI

/// One service on the Accounts tab.
struct VaultAccountService: Identifiable {
    let service: SignInService
    let title: String
    let symbol: String
    let tint: DataInk

    var id: String { service.key }

    /// Whether an agent can be given its own session. Slack posts through
    /// the workspace that owns the channel, so there is nothing to pick.
    var agentsCanPick: Bool { service != .channel(.slack) }

    /// Channel bots and workspaces are added, renamed and removed in
    /// Channels; here an agent only picks which one it posts as.
    var isManagedInChannels: Bool {
        if case .channel = service { return true }
        return false
    }

    @MainActor
    static func all(store: SignInSessionStore, connections: WorkflowConnectionStore) -> [VaultAccountService] {
        var services = store.services
        for provider in MCPProviderManager.shared.configuration.providers where provider.authType == .oauth {
            if !services.contains(.mcp(provider.id)) { services.append(.mcp(provider.id)) }
        }
        for provider in RemoteProviderManager.shared.configuration.providers
        where provider.authType == .openAICodexOAuth || provider.authType == .xaiOAuth {
            if !services.contains(.modelProvider(provider.id)) { services.append(.modelProvider(provider.id)) }
        }
        return services.compactMap { make($0, connections: connections) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @MainActor
    private static func make(_ service: SignInService, connections: WorkflowConnectionStore) -> VaultAccountService? {
        switch service {
        case .connection(let host):
            let title =
                host.hasPrefix("connection-")
                ? connections.connections.first { SignInService.connection($0) == service }?.name ?? host
                : host
            return VaultAccountService(service: service, title: title, symbol: "link", tint: CredentialOrigin.workflow.ink)
        case .mcp(let id):
            guard let provider = MCPProviderManager.shared.configuration.provider(id: id) else { return nil }
            return VaultAccountService(
                service: service, title: provider.name, symbol: CredentialOrigin.mcp.symbol, tint: CredentialOrigin.mcp.ink)
        case .modelProvider(let id):
            guard let provider = RemoteProviderManager.shared.configuration.provider(id: id) else { return nil }
            return VaultAccountService(
                service: service, title: provider.name, symbol: "cloud.fill", tint: AppKeyRow.Group.models.ink)
        case .channel(let kind):
            let title: String
            switch kind {
            case .discord: title = "Discord"
            case .slack: title = "Slack"
            case .telegram: title = "Telegram"
            default: title = kind.rawValue.capitalized
            }
            return VaultAccountService(
                service: service, title: title, symbol: CredentialOrigin.channel.symbol, tint: CredentialOrigin.channel.ink)
        }
    }
}

struct VaultAccountsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = SignInSessionStore.shared
    @ObservedObject private var connections = WorkflowConnectionStore.shared
    @ObservedObject private var agentManager = AgentManager.shared

    @Binding var agentId: UUID?
    let query: String

    @State private var statuses: [UUID: SignInSessionStatus] = [:]
    /// Sign-ins in progress per session, so a stuck one can be cancelled.
    @State private var busy: [UUID: Task<Void, Never>] = [:]
    @State private var sheet: VaultSessionSheet.Mode?
    @State private var renaming: SignInSession?
    @State private var newName = ""
    @State private var pendingRemove: SignInSession?
    @State private var refreshTick = 0

    private var services: [VaultAccountService] {
        VaultAccountService.all(store: store, connections: connections).filter { service in
            query.isEmpty || service.title.lowercased().contains(query)
                || store.sessions(for: service.service).contains { $0.name.lowercased().contains(query) }
        }
    }

    /// Agents a session pick applies to. Built-in agents use each
    /// service's default.
    private var pickingAgent: UUID? { SignInSessionResolver.sessionAgent(agentId) }

    private var selectedAgentName: String {
        agentId.flatMap { agentManager.agent(for: $0)?.displayName } ?? L("this agent")
    }

    var body: some View {
        SettingsSection(
            title: "Accounts",
            subtitle: agentId == nil
                ? "Sign-ins agents, tools, and workflows use. Each service has a default; an agent can use its own."
                : pickingAgent == nil
                    ? "\(selectedAgentName) uses each service's default session."
                    : "Pick which session \(selectedAgentName) uses for each service.",
            anchorId: "keys.accounts",
            layout: .plain
        ) {
            if services.isEmpty {
                if query.isEmpty {
                    SettingsEmptyState(
                        inline: "person.crop.circle.badge.checkmark",
                        title: "No accounts yet",
                        hint: "Sign in to an MCP server, a model provider, or a workflow connection, and it shows up here."
                    )
                    .settingsChrome(.card)
                } else {
                    SettingsEmptyState(inline: "magnifyingglass", title: "No accounts match.")
                        .settingsChrome(.card)
                }
            }
            ForEach(services) { service in serviceCard(service) }
        }
        .task(id: StatusKey(state: store.state, tick: refreshTick)) {
            statuses = await SignInSessionActions.statuses(of: store.sessions)
        }
        .task { await SignInSessionSync.run() }
        .onDisappear {
            for task in busy.values { task.cancel() }
            busy = [:]
        }
        .onReceive(NotificationCenter.default.publisher(for: .signInSessionsDidChange)) { _ in refreshTick += 1 }
        .sheet(item: $sheet) { mode in
            VaultSessionSheet(mode: mode) { sheet = nil }
        }
        .themedAlert(
            L("Rename “\(renaming?.name ?? "")”"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            accessory: AnyView(SettingsTextField(placeholder: L("Name"), text: $newName)),
            buttons: [
                .primary(L("Rename")) {
                    if let session = renaming { rename(session, to: newName) }
                    renaming = nil
                },
                .cancel(L("Cancel")) { renaming = nil },
            ])
        .themedAlert(
            L("Remove “\(pendingRemove?.name ?? "")”?"),
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            message: removeMessage,
            buttons: [
                .destructive(L("Remove")) {
                    if let session = pendingRemove { SignInSessionActions.forget(session) }
                    pendingRemove = nil
                },
                .cancel(L("Cancel")) { pendingRemove = nil },
            ])
    }

    private struct StatusKey: Equatable {
        let state: SignInSessionState
        let tick: Int
    }

    // MARK: - Service card

    private func serviceCard(_ service: VaultAccountService) -> some View {
        let sessions = store.sessions(for: service.service)
        return SettingsSection(
            title: service.title,
            subtitle: serviceSubtitle(service, sessions: sessions),
            anchorId: "keys.accounts.\(service.id)",
            verbatimTitle: true
        ) {
            HStack(spacing: theme.space.s8) {
                if let agent = pickingAgent, service.agentsCanPick, sessions.count > 1 {
                    agentPicker(service, sessions: sessions, agentId: agent)
                }
                if service.isManagedInChannels {
                    SettingsButton(.secondary, "Manage in Channels", icon: "arrow.up.forward", size: .compact) {
                        openInChannels(nil)
                    }
                    .help(L("Add, rename and remove bots and workspaces in Channels"))
                    .settingsLandingAnchor("keys.accounts.manageInChannels")
                } else {
                    SettingsButton(.secondary, sessions.isEmpty ? "Sign In" : "Add Session", icon: "plus", size: .compact) {
                        sheet = .add(service)
                    }
                }
            }
        } content: {
            if sessions.isEmpty {
                LibraryRow(
                    title: L("Not signed in"),
                    subtitle: L("Sign in once and every agent can use it."),
                    leading: { LibraryIcon(symbol: service.symbol, tint: theme.dataInk(service.tint), size: 32) },
                    trailing: { StatusChip(L("Signed out"), tone: .warning, showsDot: true) }
                )
            }
            ForEach(sessions) { session in sessionRow(session, service: service) }
        }
    }

    private func serviceSubtitle(_ service: VaultAccountService, sessions: [SignInSession]) -> String {
        var parts = [service.service.kindLabel]
        if sessions.count > 1 { parts.append(L("\(sessions.count) sessions")) }
        if let agent = pickingAgent, service.agentsCanPick,
            let picked = store.assignment(agentId: agent, service: service.service)
        {
            parts.append(L("\(selectedAgentName) uses \(picked.name)"))
        }
        return parts.joined(separator: " · ")
    }

    private func agentPicker(_ service: VaultAccountService, sessions: [SignInSession], agentId: UUID) -> some View {
        let fallback = store.defaultSession(for: service.service)?.name ?? L("Default")
        let options: [SettingsPickerRow<UUID?>.Option] =
            [.init(nil, L("Default (\(fallback))"), verbatim: true)]
            + sessions.map { .init($0.id, $0.name, verbatim: true) }
        return HStack(spacing: theme.space.s6) {
            Text(L("This agent uses"))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
            SettingsMenuPicker(
                selection: Binding(
                    get: { store.assignment(agentId: agentId, service: service.service)?.id },
                    set: { store.assign(agentId: agentId, service: service.service, sessionId: $0) }),
                options: options
            )
        }
        .help(L("The session \(selectedAgentName) uses"))
    }

    // MARK: - Session row

    private func sessionRow(_ session: SignInSession, service: VaultAccountService) -> some View {
        let status = statuses[session.id]
        let isDefault = store.isDefault(session)
        let usedByAgent = pickingAgent.map { agent in
            SignInSessionResolver.state.resolve(service.service, agentId: agent)?.id == session.id
        } ?? false
        return LibraryRow(
            title: session.name,
            subtitle: sessionSubtitle(session),
            isSelected: usedByAgent,
            leading: { LibraryIcon(symbol: service.symbol, tint: theme.dataInk(service.tint), size: 32) },
            badges: {
                if isDefault {
                    StatusChip(L("Default"), tone: .accent, help: L("Agents without their own session use this one."))
                }
                if usedByAgent {
                    StatusChip(L("\(selectedAgentName) uses this"), tone: .info)
                }
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    if busy[session.id] != nil {
                        SettingsSpinner()
                        SettingsButton(.secondary, "Cancel", size: .compact) { cancelSignIn(session) }
                    } else if let status {
                        statusChip(status)
                        if status != .signedIn, !service.isManagedInChannels {
                            SettingsButton(.primary, "Sign In", size: .compact) { signInAgain(session, service: service) }
                        }
                    }
                }
            },
            menu: {
                if service.isManagedInChannels {
                    if !isDefault, service.agentsCanPick {
                        Button(L("Make Default")) { store.makeDefault(session.id) }
                    }
                    Button(L("Open in Channels")) { openInChannels(session) }
                } else {
                    Button(L("Rename…")) {
                        newName = session.name
                        renaming = session
                    }
                    if !isDefault, service.agentsCanPick {
                        Button(L("Make Default")) { store.makeDefault(session.id) }
                    }
                    Button(L("Sign In Again")) { signInAgain(session, service: service) }
                    if status == .signedIn {
                        Button(L("Sign Out")) { SignInSessionActions.signOut(session) }
                    }
                    Divider()
                    Button(L("Remove…"), role: .destructive) { pendingRemove = session }
                }
            }
        )
    }

    private func statusChip(_ status: SignInSessionStatus) -> StatusChip {
        switch status {
        case .signedIn: return StatusChip(L("Signed in"), tone: .success, showsDot: true)
        case .expired: return StatusChip(L("Expired"), tone: .warning, showsDot: true)
        case .signedOut: return StatusChip(L("Signed out"), tone: .warning, showsDot: true)
        }
    }

    private func sessionSubtitle(_ session: SignInSession) -> String {
        var parts: [String] = []
        if let label = session.accountLabel, !label.isEmpty { parts.append(label) }
        if case .connection = session.service, let connection = connections.connection(id: session.id) {
            if connection.kind == .value {
                parts.append(L("Pasted value"))
            } else if let expiresAt = connection.expiresAt, !connection.needsSignIn() {
                parts.append(L("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))"))
            }
            let workflows = connections.users(of: connection.id).map(\.name)
            if !workflows.isEmpty { parts.append(L("Workflows: \(WorkflowSummary.list(workflows))")) }
        }
        let agents = store.agents(using: session.id).compactMap { agentManager.agent(for: $0)?.displayName }
        if !agents.isEmpty { parts.append(L("Agents: \(agents.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }

    private var removeMessage: String? {
        guard let session = pendingRemove else { return nil }
        var users: [String] = store.agents(using: session.id).compactMap { agentManager.agent(for: $0)?.displayName }
        if case .connection = session.service { users += connections.users(of: session.id).map(\.name) }
        let signOut = L("It is signed out and its tokens are removed from the Keychain.")
        guard !users.isEmpty else { return signOut }
        return signOut + " " + L("\(WorkflowSummary.list(users)) will use the default session instead.")
    }

    // MARK: - Actions

    /// The channel connection a bot or workspace session is.
    private static func channelConnectionId(_ session: SignInSession) -> String? {
        guard case .channel(let kind) = session.service else { return nil }
        if kind == .slack {
            return session.reference.map(ChannelAccounts.connectionId(slackTeamId:))
                ?? ChannelAccounts.primaryConnectionId(.slack)
        }
        return ChannelAccounts.connectionId(botSession: session)
    }

    /// Channels, with the session's own account sheet open when there is one.
    private func openInChannels(_ session: SignInSession?) {
        let state = ManagementStateManager.shared
        if let id = session.flatMap(Self.channelConnectionId), ChannelAccounts.account(connectionId: id) != nil {
            state.pendingChannelConnectionId = id
        }
        state.selectedTab = .agentChannels
    }

    private func rename(_ session: SignInSession, to name: String) {
        if case .connection = session.service {
            connections.rename(session.id, to: name)
        } else {
            store.rename(session.id, to: name)
        }
    }

    private func signInAgain(_ session: SignInSession, service: VaultAccountService) {
        switch session.service {
        case .connection:
            guard let connection = connections.connection(id: session.id) else { return }
            if WorkflowConnectionActions.pastesValue(connection) {
                sheet = .replace(session)
                return
            }
            run(session) { try await WorkflowConnectionActions.signInAgain(connection) }
        case .mcp(let id):
            run(session) { try await MCPProviderManager.shared.oauthSignIn(providerId: id, session: session) }
        case .modelProvider(let id):
            run(session) { try await RemoteProviderManager.shared.oauthSignIn(providerId: id, session: session) }
        case .channel(let kind):
            if ChannelSessions.botKinds.contains(kind) {
                sheet = .replace(session)
            } else {
                ManagementStateManager.shared.selectedTab = .agentChannels
            }
        }
    }

    private func run(_ session: SignInSession, _ work: @escaping @MainActor () async throws -> Void) {
        guard busy[session.id] == nil else { return }
        busy[session.id] = Task { @MainActor in
            defer { refreshTick += 1 }
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    _ = ToastManager.shared.error(L("Couldn't sign in to \(session.name)"), message: WorkflowErrorText.text(error))
                }
            }
            if !Task.isCancelled { busy[session.id] = nil }
        }
    }

    private func cancelSignIn(_ session: SignInSession) {
        busy[session.id]?.cancel()
        busy[session.id] = nil
        refreshTick += 1
    }

    /// Sessions matching the search, for the tab's match count.
    @MainActor
    static func matchCount(query: String) -> Int {
        let store = SignInSessionStore.shared
        return VaultAccountService.all(store: store, connections: .shared).reduce(0) { count, service in
            let sessions = store.sessions(for: service.service)
            if query.isEmpty || service.title.lowercased().contains(query) { return count + max(sessions.count, 1) }
            return count + sessions.filter { $0.name.lowercased().contains(query) }.count
        }
    }
}

// MARK: - Add or replace a session

struct VaultSessionSheet: View {
    @Environment(\.theme) private var theme
    enum Mode: Identifiable {
        /// A new session of a service.
        case add(VaultAccountService)
        /// A new value or bot token for a session that pastes one.
        case replace(SignInSession)

        var id: String {
            switch self {
            case .add(let service): return "add:\(service.id)"
            case .replace(let session): return "replace:\(session.id)"
            }
        }

        var service: SignInService {
            switch self {
            case .add(let service): return service.service
            case .replace(let session): return session.service
            }
        }
    }

    let mode: Mode
    let onClose: () -> Void

    @ObservedObject private var store = SignInSessionStore.shared
    @ObservedObject private var connections = WorkflowConnectionStore.shared

    @State private var name = ""
    @State private var value = ""
    @State private var isWorking = false
    @State private var error: String?
    /// The running sign-in; closing the sheet cancels it so it stops
    /// holding the redirect port.
    @State private var work: Task<Void, Never>?

    /// The connection a new connection session copies its sign-in from.
    private var template: WorkflowConnection? {
        guard case .connection = mode.service else { return nil }
        if case .replace(let session) = mode { return connections.connection(id: session.id) }
        return connections.connections.first { SignInService.connection($0) == mode.service }
    }

    /// Pastes a value (an API key or a bot token) instead of a browser sign-in.
    private var pastesValue: Bool {
        switch mode.service {
        case .connection: return template?.kind != .oauth2
        case .channel: return true
        case .mcp, .modelProvider: return false
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private var canSubmit: Bool {
        guard !isWorking else { return false }
        if pastesValue, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .add: return store.sessions(for: mode.service).isEmpty ? "Sign In" : "Add Session"
        case .replace: return "Sign In Again"
        }
    }

    private var valueLabel: String {
        if case .channel = mode.service { return L("Bot token") }
        return L("Value")
    }

    var body: some View {
        SettingsSheet(
            icon: "person.crop.circle.badge.plus",
            title: title,
            subtitle: pastesValue
                ? "The value is kept in the Keychain on this Mac."
                : "Finish signing in in your browser. Use another account there to add it as a new session.",
            primary: .init(label: pastesValue ? "Save" : "Sign In", isEnabled: canSubmit) { submit() },
            secondary: .init(label: "Cancel", handler: close),
            warning: error,
            onClose: close
        ) {
            SettingsSection(title: "Session") {
                if isAdding {
                    SettingsFieldRow(label: L("Name"), verbatimLabel: true) {
                        SettingsTextField(placeholder: L("New session name, e.g. Work"), text: $name)
                    }
                }
                if pastesValue {
                    SettingsFieldRow(label: valueLabel, verbatimLabel: true) {
                        SettingsTextField(placeholder: "", text: $value, monospaced: true, isSecure: true, revealable: true)
                    }
                }
                if isWorking {
                    HStack(spacing: theme.space.s8) {
                        SettingsSpinner()
                        Text(pastesValue ? L("Saving…") : L("Waiting for the browser sign-in…"))
                            .font(SettingsFont.rowDescription)
                    }
                    if template?.kind == .oauth2 {
                        Text(
                            L("If the service shows a redirect URL error, add \(OAuth2ConnectionFlow.redirectURL) to its app settings, then cancel and try again.")
                        )
                        .font(SettingsFont.rowDescription)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func close() {
        work?.cancel()
        work = nil
        onClose()
    }

    private func submit() {
        isWorking = true
        error = nil
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = value.trimmingCharacters(in: .whitespacesAndNewlines)
        work = Task { @MainActor in
            defer { isWorking = false }
            do {
                switch mode {
                case .add: try await add(name: typed, value: pasted)
                case .replace(let session): try replace(session, value: pasted)
                }
                NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
                onClose()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = WorkflowErrorText.text(error) }
            }
        }
    }

    private func add(name: String, value: String) async throws {
        let service = mode.service
        let label = name.isEmpty ? nil : name
        switch service {
        case .connection(let host):
            let connectionName = label ?? L("\(host) sign-in")
            if let template, template.kind == .oauth2, let spec = template.oauth2 {
                let secret = WorkflowSecretsKeychain.read(
                    account: WorkflowSecretsKeychain.connectionAccount(id: template.id, field: "client_secret"))
                _ = try await OAuth2ConnectionFlow.signIn(spec: spec, name: connectionName, clientSecret: secret)
            } else if connections.addValue(name: connectionName, service: template?.service ?? host, value: value) == nil {
                throw VaultSessionError.notSaved
            }
        case .mcp(let id):
            let session = newSession(service, name: label)
            do {
                try await MCPProviderManager.shared.oauthSignIn(providerId: id, session: session)
            } catch {
                if !session.isPrimary { store.remove(session.id) }
                throw error
            }
        case .modelProvider(let id):
            let session = newSession(service, name: label)
            do {
                try await RemoteProviderManager.shared.oauthSignIn(providerId: id, session: session)
            } catch {
                if !session.isPrimary { store.remove(session.id) }
                throw error
            }
        case .channel(let kind):
            let session = newSession(service, name: label)
            guard ChannelSessions.saveBotToken(value, kind: kind, session: session) else {
                if !session.isPrimary { store.remove(session.id) }
                throw VaultSessionError.notSaved
            }
        }
    }

    /// The first sign-in of a service is its primary session, in the
    /// Keychain account the service always used.
    private func newSession(_ service: SignInService, name: String?) -> SignInSession {
        if !store.sessions(for: service).contains(where: \.isPrimary) {
            let primary = store.ensurePrimary(for: service)
            if let name { store.rename(primary.id, to: name) }
            return store.session(id: primary.id) ?? primary
        }
        return store.add(service: service, name: name ?? L("Session \(store.sessions(for: service).count + 1)"))
    }

    private func replace(_ session: SignInSession, value: String) throws {
        switch session.service {
        case .connection:
            guard WorkflowConnectionActions.replaceValue(value, in: session.id) else { throw VaultSessionError.notSaved }
        case .channel(let kind):
            guard ChannelSessions.saveBotToken(value, kind: kind, session: session) else {
                throw VaultSessionError.notSaved
            }
        case .mcp, .modelProvider:
            break
        }
    }
}

enum VaultSessionError: LocalizedError {
    case notSaved

    var errorDescription: String? {
        L("The Keychain didn't save this. Try again.")
    }
}
