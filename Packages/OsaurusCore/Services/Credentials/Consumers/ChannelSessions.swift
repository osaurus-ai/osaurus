//
//  ChannelSessions.swift
//  osaurus
//
//  Bot logins of one channel kind as sign-in sessions. The primary Discord
//  or Telegram session is the bot token saved in Channels; every other
//  session keeps its own token in the Keychain
//  (`<kind>.session.<sessionId>.bot_token`) and is a channel connection of
//  its own (`ChannelAccounts`), with its own settings and listener. An
//  agent assigned a session posts through that bot's connection.
//
//  Slack's sessions are its workspaces (`reference` is the team id). A
//  Slack channel belongs to one workspace, so agents don't pick one.
//

import Foundation

enum ChannelSessions {
    private static let keychainService = "ai.osaurus.channels"

    /// Channel kinds whose bot logins an agent can pick.
    static let botKinds = ChannelAccounts.botKinds

    /// Kinds with a token saved in Channels (their primary session).
    static func signedInKinds() -> [AgentChannelKind] {
        [.discord, .telegram, .slack].filter { primaryToken($0) != nil }
    }

    private static func account(_ kind: AgentChannelKind, session: UUID) -> String {
        "\(kind.rawValue).session.\(session.uuidString).bot_token"
    }

    private static func primaryToken(_ kind: AgentChannelKind) -> String? {
        switch kind {
        case .discord: DiscordCredentialStore.botToken()
        case .telegram: TelegramCredentialStore.botToken()
        case .slack: SlackCredentialStore.botToken()
        default: nil
        }
    }

    /// The bot token of a session; nil session is the primary one.
    static func botToken(_ kind: AgentChannelKind, session: SignInSession?) -> String? {
        if kind == .slack, let teamId = session?.reference {
            return SlackCredentialStore.botToken(teamId: teamId)
        }
        guard let id = session?.keychainSession else { return primaryToken(kind) }
        return botToken(kind, sessionId: id)
    }

    /// An extra bot's token, by its session id.
    static func botToken(_ kind: AgentChannelKind, sessionId: UUID) -> String? {
        SessionKeychainItems.read(service: keychainService, account: account(kind, session: sessionId))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func saveBotToken(_ token: String, kind: AgentChannelKind, session: SignInSession) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, kind != .slack else { return false }
        guard let id = session.keychainSession else {
            switch kind {
            case .discord: return DiscordCredentialStore.saveBotToken(trimmed)
            case .telegram: return TelegramCredentialStore.saveBotToken(trimmed)
            default: return false
            }
        }
        return saveBotToken(trimmed, kind: kind, sessionId: id)
    }

    @discardableResult
    static func saveBotToken(_ token: String, kind: AgentChannelKind, sessionId: UUID) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        defer { invalidateAvailability(kind) }
        return SessionKeychainItems.write(
            service: keychainService, account: account(kind, session: sessionId), data: Data(trimmed.utf8))
    }

    @discardableResult
    static func deleteBotToken(_ kind: AgentChannelKind, session: SignInSession) -> Bool {
        if kind == .slack, let teamId = session.reference {
            return SlackCredentialStore.deleteBotToken(teamId: teamId)
        }
        guard let id = session.keychainSession else {
            switch kind {
            case .discord: return DiscordCredentialStore.deleteBotToken()
            case .telegram: return TelegramCredentialStore.deleteBotToken()
            case .slack: return SlackCredentialStore.deleteBotToken()
            default: return false
            }
        }
        return deleteBotToken(kind, sessionId: id)
    }

    @discardableResult
    static func deleteBotToken(_ kind: AgentChannelKind, sessionId: UUID) -> Bool {
        defer { invalidateAvailability(kind) }
        return SessionKeychainItems.delete(service: keychainService, account: account(kind, session: sessionId))
    }

    private static func invalidateAvailability(_ kind: AgentChannelKind) {
        guard let provider = AgentChannelCredentialAvailability.Provider(rawValue: kind.rawValue) else { return }
        AgentChannelCredentialAvailability.shared.invalidate(provider)
    }

    /// The bot token the agent posts with: its assigned session's, else
    /// the default session's, else the token saved in Channels.
    static func botToken(_ kind: AgentChannelKind, agentId: UUID?) -> String? {
        botToken(kind, session: SignInSessionResolver.session(for: .channel(kind), agentId: agentId))
    }

    /// The connection an agent's proactive post to `connectionId` goes out
    /// on. A post to a channel's primary bot goes through the bot the agent
    /// uses instead (its assigned session, else the default), so that bot's
    /// own write allowlist applies. A post addressed to a specific extra bot
    /// stays on it. nil when nothing changes.
    static func postingConnectionId(for connectionId: String, agentId: UUID) -> String? {
        guard let account = ChannelAccounts.account(connectionId: connectionId), account.isPrimary,
            botKinds.contains(account.kind),
            let session = SignInSessionResolver.session(
                for: .channel(account.kind), agentId: SignInSessionResolver.sessionAgent(agentId)),
            let target = ChannelAccounts.connectionId(botSession: session), target != account.connectionId
        else { return nil }
        return target
    }
}

/// An extra bot's token, kept under its sign-in session.
struct ChannelSessionCredentialStorage: DiscordCredentialStorage, TelegramCredentialStorage {
    let kind: AgentChannelKind
    let sessionId: UUID

    func saveBotToken(_ token: String) -> Bool {
        ChannelSessions.saveBotToken(token, kind: kind, sessionId: sessionId)
    }

    func saveBotTokenOutcome(_ token: String) -> CredentialWriteOutcome {
        saveBotToken(token) ? .success : .keychainFailure("the save failed")
    }

    func botToken() -> String? {
        ChannelSessions.botToken(kind, sessionId: sessionId)
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        ChannelSessions.deleteBotToken(kind, sessionId: sessionId)
    }
}
