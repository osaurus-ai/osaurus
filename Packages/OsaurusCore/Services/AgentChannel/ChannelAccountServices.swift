//
//  ChannelAccountServices.swift
//  osaurus
//
//  One service instance per channel account. The primary account is the
//  shared instance; every extra bot or workspace gets its own, keyed by
//  connection id, reading its own settings file and token.
//

import Foundation
import os

enum ChannelAccountServices {
    private struct Instances: @unchecked Sendable {
        var discord: [String: DiscordConnectionService] = [:]
        var telegram: [String: TelegramConnectionService] = [:]
        var slack: [String: SlackConnectionService] = [:]
    }

    private static let instances = OSAllocatedUnfairLock(initialState: Instances())

    static func discord(_ connectionId: String) -> DiscordConnectionService? {
        let id = normalized(connectionId)
        if id == DiscordConnectionService.nativeConnectionId { return .shared }
        guard let sessionId = sessionId(id, kind: .discord) else { return nil }
        return instances.withLock { cache in
            if let existing = cache.discord[id] { return existing }
            let service = DiscordConnectionService(
                connectionId: id,
                client: DiscordAPIClient(),
                credentialStore: ChannelSessionCredentialStorage(kind: .discord, sessionId: sessionId),
                messageStore: AgentChannelMessageStore.shared)
            cache.discord[id] = service
            return service
        }
    }

    static func telegram(_ connectionId: String) -> TelegramConnectionService? {
        let id = normalized(connectionId)
        if id == TelegramConnectionService.nativeConnectionId { return .shared }
        guard let sessionId = sessionId(id, kind: .telegram) else { return nil }
        return instances.withLock { cache in
            if let existing = cache.telegram[id] { return existing }
            let service = TelegramConnectionService(
                connectionId: id,
                client: TelegramAPIClient(),
                credentialStore: ChannelSessionCredentialStorage(kind: .telegram, sessionId: sessionId),
                messageStore: AgentChannelMessageStore.shared)
            cache.telegram[id] = service
            return service
        }
    }

    static func slack(_ connectionId: String) -> SlackConnectionService? {
        let id = normalized(connectionId)
        if id == AgentChannelConnection.nativeSlackConnectionId { return .shared }
        let prefix = ChannelAccounts.extraPrefix(.slack)
        guard id.hasPrefix(prefix), id.count > prefix.count else { return nil }
        if let existing = instances.withLock({ $0.slack[id] }) { return existing }
        let teamId =
            SlackConnectionConfigurationStore.load(connectionId: id).configuredTeamIds.first
            ?? String(id.dropFirst(prefix.count)).uppercased()
        return instances.withLock { cache in
            if let existing = cache.slack[id] { return existing }
            let service = SlackConnectionService(
                connectionId: id,
                client: SlackAPIClient(),
                credentialStore: WorkspaceSlackCredentialStorage(teamId: teamId),
                messageStore: AgentChannelMessageStore.shared)
            cache.slack[id] = service
            return service
        }
    }

    /// Drops a removed account's instance.
    static func forget(_ connectionId: String) {
        let id = normalized(connectionId)
        instances.withLock { cache in
            cache.discord[id] = nil
            cache.telegram[id] = nil
            cache.slack[id] = nil
        }
    }

    /// The sign-in session an extra bot's id names (`discord-<session>`).
    static func sessionId(_ connectionId: String, kind: AgentChannelKind) -> UUID? {
        let prefix = ChannelAccounts.extraPrefix(kind)
        guard connectionId.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(connectionId.dropFirst(prefix.count)))
    }

    private static func normalized(_ connectionId: String) -> String {
        AgentChannelConnection.normalizedId(connectionId).lowercased()
    }
}
