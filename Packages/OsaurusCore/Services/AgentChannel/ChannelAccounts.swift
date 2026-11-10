//
//  ChannelAccounts.swift
//  osaurus
//
//  Every account of a native channel is its own channel connection: each
//  Discord or Telegram bot, each Slack workspace, each Email account. The
//  primary account keeps the channel's original id (`discord`, `slack`,
//  `email`, ...), so history, cursors, triggers and bindings made before
//  there were several keep working. Others get `<kind>-<id>`.
//
//  Nothing here is stored. Bots are their sign-in sessions, Slack
//  workspaces their `slack-<team>.json` settings files, and Email accounts
//  the entries of `email.json`.
//

import Foundation

extension Notification.Name {
    /// A Discord, Telegram or Slack account's settings file was saved or
    /// removed; the object is its connection id.
    static let channelAccountSettingsChanged = Notification.Name("ai.osaurus.channelAccountSettingsChanged")
}

struct ChannelAccount: Equatable, Sendable, Identifiable {
    let kind: AgentChannelKind
    let connectionId: String
    /// The account's own name ("Support bot", "Acme", "Work mail"); the
    /// channel's name for the primary bot or workspace.
    let name: String
    let isPrimary: Bool
    /// The sign-in session holding a bot's token.
    let sessionId: UUID?
    /// A Slack workspace's team id, or an Email account's mail account id.
    let reference: String?

    var id: String { connectionId }

    /// "Discord · Support bot", or "Discord" while the account has no name
    /// of its own yet.
    var displayName: String {
        name.isEmpty || name == kind.displayName ? kind.displayName : "\(kind.displayName) · \(name)"
    }
}

enum ChannelAccounts {
    /// Kinds that can hold more than one account.
    static let multiAccountKinds: [AgentChannelKind] = [.discord, .telegram, .slack, .email]

    /// Kinds whose extra accounts are bots signed in with a token.
    static let botKinds: [AgentChannelKind] = [.discord, .telegram]

    /// The original id of a native channel: its primary account.
    static func primaryConnectionId(_ kind: AgentChannelKind) -> String? {
        ChannelMessageSourceConfig.nativeConnectionId(for: kind)
    }

    // MARK: - Ids

    static func connectionId(botSession session: SignInSession) -> String? {
        guard case .channel(let kind) = session.service, botKinds.contains(kind) else { return nil }
        if session.isPrimary { return primaryConnectionId(kind) }
        return "\(kind.rawValue)-\(session.id.uuidString.lowercased())"
    }

    static func connectionId(slackTeamId teamId: String) -> String {
        "slack-\(SlackConnectionConfiguration.normalizedId(teamId).lowercased())"
    }

    static func connectionId(emailAccount sourceConnectionId: String) -> String {
        "email-\(sourceConnectionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// The prefix every extra account id of the kind starts with.
    static func extraPrefix(_ kind: AgentChannelKind) -> String { "\(kind.rawValue)-" }

    // MARK: - Lookup

    static func all() -> [ChannelAccount] {
        multiAccountKinds.flatMap(accounts(kind:))
    }

    /// The kind's accounts, the primary one first. Single-account kinds
    /// (iMessage, WhatsApp) have just their primary.
    static func accounts(kind: AgentChannelKind) -> [ChannelAccount] {
        guard let primaryId = primaryConnectionId(kind) else { return [] }
        switch kind {
        case .discord, .telegram:
            let sessions = SignInSessionResolver.state.sessions(for: .channel(kind))
            let primarySession = sessions.first(where: \.isPrimary)
            let primary = ChannelAccount(
                kind: kind, connectionId: primaryId,
                name: primarySession.map { ChannelAccountNaming.isAutomatic($0.name, kind: kind) ? kind.displayName : $0.name }
                    ?? kind.displayName,
                isPrimary: true, sessionId: primarySession?.id, reference: nil)
            return [primary]
                + sessions.filter { !$0.isPrimary }.compactMap { session in
                    connectionId(botSession: session).map {
                        ChannelAccount(
                            kind: kind, connectionId: $0, name: session.name, isPrimary: false,
                            sessionId: session.id, reference: nil)
                    }
                }
        case .slack:
            let primaryConfig = SlackConnectionConfigurationStore.load(connectionId: primaryId)
            let primary = ChannelAccount(
                kind: .slack, connectionId: primaryId, name: primaryConfig.workspaceName ?? kind.displayName,
                isPrimary: true, sessionId: nil, reference: primaryConfig.configuredTeamIds.first)
            return [primary]
                + SlackConnectionConfigurationStore.accountConnectionIds().compactMap { id in
                    let config = SlackConnectionConfigurationStore.load(connectionId: id)
                    guard let teamId = config.configuredTeamIds.first else { return nil }
                    return ChannelAccount(
                        kind: .slack, connectionId: id, name: config.workspaceName ?? teamId, isPrimary: false,
                        sessionId: nil, reference: teamId)
                }
        case .email:
            let accounts = EmailChannelConfigurationStore.load().accounts.map { account in
                ChannelAccount(
                    kind: .email, connectionId: account.channelConnectionId,
                    name: account.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    isPrimary: account.channelConnectionId == primaryId, sessionId: nil,
                    reference: account.connectionId)
            }
            guard accounts.contains(where: \.isPrimary) else {
                let placeholder = ChannelAccount(
                    kind: .email, connectionId: primaryId, name: kind.displayName, isPrimary: true, sessionId: nil,
                    reference: nil)
                return [placeholder] + accounts
            }
            return accounts.sorted { $0.isPrimary && !$1.isPrimary }
        case .imessage, .whatsapp:
            return [
                ChannelAccount(
                    kind: kind, connectionId: primaryId, name: kind.displayName, isPrimary: true, sessionId: nil,
                    reference: nil)
            ]
        case .n8n, .customHTTP:
            return []
        }
    }

    static func account(connectionId: String) -> ChannelAccount? {
        let id = AgentChannelConnection.normalizedId(connectionId).lowercased()
        guard let kind = candidateKind(id) else { return nil }
        return accounts(kind: kind).first { $0.connectionId == id }
    }

    /// The native kind an id belongs to, when it is a channel account.
    static func kind(of connectionId: String) -> AgentChannelKind? {
        account(connectionId: connectionId)?.kind
    }

    static func isNative(_ connectionId: String) -> Bool {
        account(connectionId: connectionId) != nil
    }

    static func isPrimary(_ connectionId: String) -> Bool {
        let id = AgentChannelConnection.normalizedId(connectionId).lowercased()
        return AgentChannelKind.allCases.contains { primaryConnectionId($0) == id }
    }

    /// The account's display name, or nil for ids that aren't accounts.
    static func displayName(connectionId: String) -> String? {
        account(connectionId: connectionId)?.displayName
    }

    /// Whether a custom connection may use the id: native ids and the
    /// prefixes of extra accounts are taken.
    static func isReserved(_ connectionId: String) -> Bool {
        let id = AgentChannelConnection.normalizedId(connectionId).lowercased()
        return AgentChannelKind.allCases.contains { kind in
            guard let primary = primaryConnectionId(kind) else { return false }
            return id == primary || (multiAccountKinds.contains(kind) && id.hasPrefix(extraPrefix(kind)))
        }
    }

    private static func candidateKind(_ id: String) -> AgentChannelKind? {
        AgentChannelKind.allCases.first { kind in
            guard let primary = primaryConnectionId(kind) else { return false }
            return id == primary || (multiAccountKinds.contains(kind) && id.hasPrefix(extraPrefix(kind)))
        }
    }
}

/// An account's name: what the user typed, or else what the provider calls
/// the bot or workspace. Bots keep it on their sign-in session, Slack
/// workspaces in their settings file, Email accounts in `email.json`.
enum ChannelAccountNaming {
    /// Names Osaurus gave before the account had one of its own.
    static func isAutomatic(_ name: String, kind: AgentChannelKind) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == kind.displayName || trimmed == "Main" || trimmed == L("Main")
    }

    /// The bot's own name: its display name, or its username.
    static func botName(_ bot: DiscordBotIdentity) -> String {
        let global = bot.globalName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return global.isEmpty ? bot.username : global
    }

    static func botName(_ bot: TelegramUser) -> String {
        let first = bot.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? (bot.username ?? "") : first
    }

    @MainActor
    static func rename(connectionId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = ChannelAccounts.account(connectionId: connectionId) else { return }
        switch account.kind {
        case .discord, .telegram:
            let store = SignInSessionStore.shared
            let sessionId = account.sessionId ?? store.ensurePrimary(for: .channel(account.kind)).id
            store.rename(sessionId, to: trimmed.isEmpty ? account.kind.displayName : trimmed)
            NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
        case .slack:
            var config = SlackConnectionConfigurationStore.load(connectionId: account.connectionId)
            config.workspaceName = trimmed.isEmpty ? nil : trimmed
            try? SlackConnectionConfigurationStore.save(config, connectionId: account.connectionId)
            if let session = SignInSessionStore.shared.sessions(for: .channel(.slack))
                .first(where: { $0.reference != nil && $0.reference == account.reference }), !trimmed.isEmpty
            {
                SignInSessionStore.shared.rename(session.id, to: trimmed)
            }
        case .email:
            var configuration = EmailChannelConfigurationStore.load()
            guard let index = configuration.accounts.firstIndex(where: { $0.channelConnectionId == account.connectionId })
            else { return }
            configuration.accounts[index].name = trimmed
            try? EmailChannelService.shared.saveConfiguration(configuration)
        default:
            return
        }
    }

    /// Names the account after what the provider calls it, unless the user
    /// already named it.
    @MainActor
    static func adopt(_ discovered: String?, connectionId: String) {
        guard let discovered = discovered?.trimmingCharacters(in: .whitespacesAndNewlines), !discovered.isEmpty,
            let account = ChannelAccounts.account(connectionId: connectionId),
            isAutomatic(account.name, kind: account.kind)
        else { return }
        rename(connectionId: connectionId, to: discovered)
    }
}
