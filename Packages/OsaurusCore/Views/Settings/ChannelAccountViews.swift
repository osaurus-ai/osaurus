//
//  ChannelAccountViews.swift
//  osaurus
//
//  A channel's accounts: another Discord or Telegram bot, another Slack
//  workspace, another Email account. Each one is its own connection with
//  its own settings, listener and triggers, added and edited through the
//  channel's own setup sheet.
//

import SwiftUI

extension ChannelAccounts {
    /// The add button on a channel's group in Channels.
    static func addTitle(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .slack: return L("Add Workspace")
        case .email: return L("Add Account")
        default: return L("Add Bot")
        }
    }

    /// The add button's tooltip.
    static func addHelp(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .slack: return L("Connect another Slack workspace with its own rooms and agent")
        case .email: return L("Connect another mail account with its own mailboxes and agent")
        default: return L("Connect another \(kind.displayName) bot with its own rooms and agent")
        }
    }

    /// The Add Channel picker's line for a channel that is already connected.
    static func addAnotherTagline(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .slack: return L("Connected — adds another workspace with its own channels and agent")
        case .email: return L("Connected — adds another mail account with its own mailboxes and agent")
        default: return L("Connected — adds another bot with its own rooms and agent")
        }
    }

    /// The remove row's title on an extra account's Connect step.
    static func removeTitle(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .slack: return L("Remove this workspace")
        case .email: return L("Remove this account")
        default: return L("Remove this bot")
        }
    }

    /// Settings-search anchor for the add button.
    static func addAnchorId(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .discord: return "agentChannels.discord.addAccount"
        case .telegram: return "agentChannels.telegram.addAccount"
        case .slack: return "agentChannels.slack.addAccount"
        default: return "agentChannels.email.addAccount"
        }
    }

    /// The new-account sheet's title.
    static func newTitle(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .slack: return L("New Slack Workspace")
        case .email: return L("New Email Account")
        case .telegram: return L("New Telegram Bot")
        default: return L("New Discord Bot")
        }
    }
}

// MARK: - Creating

/// Creates the account behind each new-account sheet. Every step that
/// fails rolls back what it saved, so a bad token never leaves a
/// half-added account.
@MainActor
enum ChannelAccountCreation {
    enum Failure: LocalizedError {
        case notSaved
        case missingToken
        case missingMailAccount
        case mailAccountInUse
        case workspaceAlreadyAdded(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .notSaved: return L("The Keychain didn't save the token. Try again.")
            case .missingToken: return L("Paste the token first.")
            case .missingMailAccount: return L("Choose the mail account")
            case .mailAccountInUse: return L("Another Email account already watches this mail account.")
            case .workspaceAlreadyAdded(let name): return L("\(name) is already connected.")
            case .unsupported: return L("This channel has one account.")
            }
        }
    }

    /// A Discord or Telegram bot as a new sign-in session, checked against
    /// the provider before it is kept and named after the bot.
    static func addBot(kind: AgentChannelKind, token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Failure.missingToken }
        let store = SignInSessionStore.shared
        store.ensurePrimary(for: .channel(kind))
        let session = store.add(service: .channel(kind), name: kind.displayName)
        guard ChannelSessions.saveBotToken(token, kind: kind, sessionId: session.id),
            let connectionId = ChannelAccounts.connectionId(botSession: session)
        else {
            store.remove(session.id)
            throw Failure.notSaved
        }
        do {
            var name: String?
            switch kind {
            case .discord:
                if let discovery = try await ChannelAccountServices.discord(connectionId)?.discoverConfigurationOptions() {
                    name = ChannelAccountNaming.botName(discovery.bot)
                }
            case .telegram:
                if let discovery = try await ChannelAccountServices.telegram(connectionId)?.discoverConfigurationOptions()
                {
                    name = ChannelAccountNaming.botName(discovery.bot)
                }
            default:
                break
            }
            ChannelAccountNaming.adopt(name, connectionId: connectionId)
        } catch {
            ChannelSessions.deleteBotToken(kind, sessionId: session.id)
            ChannelAccountServices.forget(connectionId)
            store.remove(session.id)
            throw error
        }
        NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
        return connectionId
    }

    /// A Slack workspace as `slack-<team>`, named after the workspace.
    static func addWorkspace(botToken: String, appToken: String) async throws -> String {
        let botToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !botToken.isEmpty else { throw Failure.missingToken }
        let discovery = try await SlackConnectionService.shared.discoverConfigurationOptions(botToken: botToken)
        let teamId = discovery.identity.teamId
        let connectionId = ChannelAccounts.connectionId(slackTeamId: teamId)
        if SlackConnectionService.shared.configuration().configuredTeamIds.contains(teamId)
            || ChannelAccounts.account(connectionId: connectionId) != nil
        {
            throw Failure.workspaceAlreadyAdded(discovery.identity.team ?? teamId)
        }
        try SlackConnectionService.addWorkspace(discovery: discovery, botToken: botToken, appToken: appToken)
        await SignInSessionSync.run()
        return connectionId
    }

    /// An Email account reading `mailAccountId`. The first one takes the
    /// channel's own id.
    static func addEmail(name: String, mailAccountId: String) throws -> String {
        var configuration = EmailChannelConfigurationStore.load()
        guard configuration.account(connectionId: mailAccountId) == nil else { throw Failure.mailAccountInUse }
        let primary = AgentChannelConnection.nativeEmailConnectionId
        let connectionId =
            configuration.account(channelConnectionId: primary) == nil
            ? primary : ChannelAccounts.connectionId(emailAccount: mailAccountId)
        configuration.accounts.append(
            EmailChannelAccount(connectionId: mailAccountId, channelConnectionId: connectionId, name: name))
        try EmailChannelService.shared.saveConfiguration(configuration)
        return connectionId
    }
}

// MARK: - Name

/// "Name" at the top of an account's Connect step. Filled in from the bot
/// or workspace when it connects; saved as the user types.
struct ChannelAccountNameField: View {
    let connectionId: String
    let kind: AgentChannelKind

    @State private var name = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        SettingsFieldRow(
            label: "Name",
            hint: L("Shown in Channels, routing rules and history."),
            anchorId: "agentChannels.accountName",
            verbatimHint: true
        ) {
            SettingsTextField(placeholder: placeholder, text: $name)
        }
        .onAppear(perform: load)
        .onChange(of: connectionId) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: .signInSessionsDidChange).receive(on: DispatchQueue.main)) {
            _ in
            if saveTask == nil { load() }
        }
        .onChange(of: name) { _, value in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if value != storedName { ChannelAccountNaming.rename(connectionId: connectionId, to: value) }
                saveTask = nil
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if name != storedName { ChannelAccountNaming.rename(connectionId: connectionId, to: name) }
        }
    }

    private var placeholder: String {
        switch kind {
        case .slack: return L("e.g. Acme")
        case .email: return L("e.g. Work mail")
        default: return L("e.g. Support bot")
        }
    }

    private var storedName: String {
        guard let account = ChannelAccounts.account(connectionId: connectionId) else { return "" }
        return ChannelAccountNaming.isAutomatic(account.name, kind: kind) ? "" : account.name
    }

    private func load() {
        name = storedName
    }
}

// MARK: - Remove

/// The bottom of an extra account's Connect step: remove it, after a
/// confirmation that names the triggers that go with it.
struct ChannelAccountRemoveSection: View {
    @Environment(\.theme) private var theme

    let connectionId: String
    let kind: AgentChannelKind
    let onRemoved: () -> Void

    @State private var confirming = false

    var body: some View {
        if !ChannelAccounts.isPrimary(connectionId), ChannelAccounts.account(connectionId: connectionId) != nil {
            HStack(alignment: .center, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ChannelAccounts.removeTitle(kind))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "Its settings, token and listener go away. Messages it already received stay in history.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: theme.space.s8)
                SettingsButton(.secondary, "Remove…", size: .compact) { confirming = true }
                    .settingsLandingAnchor("agentChannels.removeAccount")
            }
            .padding(.top, theme.space.s12)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.border.subtle).frame(height: 1)
            }
            .themedAlert(
                L("Remove \(ChannelAccounts.displayName(connectionId: connectionId) ?? connectionId)?"),
                isPresented: $confirming,
                message: Self.message(connectionId: connectionId),
                buttons: [
                    .destructive(L("Remove")) {
                        confirming = false
                        ChannelAccountRemoval.removeAccount(connectionId: connectionId)
                        onRemoved()
                    },
                    .cancel(L("Cancel")) { confirming = false },
                ])
        }
    }

    @MainActor
    static func message(connectionId: String) -> String {
        let base = L("Its settings, token and listener are removed. Messages it already received stay in history.")
        let triggers = ChannelAccountRemoval.triggerNames(connectionId: connectionId)
        guard !triggers.isEmpty else { return base }
        return base + " " + L("These triggers are deleted too: \(triggers.joined(separator: ", ")).")
    }
}
