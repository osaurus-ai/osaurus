//
//  ChannelAccountRemoval.swift
//  osaurus
//
//  Removing an extra channel account takes what belonged to it: its
//  settings file and token, its listener, and the triggers that answered
//  on it. Bindings that posted through it are disabled, not deleted, so the
//  operator sees what stopped. History stays in the message store.
//

import Foundation

@MainActor
enum ChannelAccountRemoval {
    /// Removes the account and the sign-in session it is listed under.
    static func removeAccount(connectionId: String) {
        guard let account = ChannelAccounts.account(connectionId: connectionId), !account.isPrimary else { return }
        let store = SignInSessionStore.shared
        let session =
            account.sessionId.flatMap { store.session(id: $0) }
            ?? (account.kind == .slack
                ? store.sessions(for: .channel(.slack)).first { $0.reference != nil && $0.reference == account.reference }
                : nil)
        if let session {
            SignInSessionActions.forget(session)
        } else {
            remove(connectionId: account.connectionId)
        }
    }

    /// The triggers removing the account deletes, by name.
    static func triggerNames(connectionId: String) -> [String] {
        guard let kind = ChannelAccounts.kind(of: connectionId) else { return [] }
        return EventManager.shared.events(kind: kind, connectionId: connectionId).map(\.name)
    }

    static func remove(connectionId rawId: String) {
        let connectionId = AgentChannelConnection.normalizedId(rawId).lowercased()
        guard !ChannelAccounts.isPrimary(connectionId),
            let kind = ChannelAccounts.multiAccountKinds.first(where: {
                connectionId.hasPrefix(ChannelAccounts.extraPrefix($0))
            })
        else { return }
        switch kind {
        case .discord:
            DiscordConnectionConfigurationStore.delete(connectionId: connectionId)
            if let sessionId = ChannelAccountServices.sessionId(connectionId, kind: kind) {
                ChannelSessions.deleteBotToken(.discord, sessionId: sessionId)
            }
        case .telegram:
            TelegramConnectionConfigurationStore.delete(connectionId: connectionId)
            if let sessionId = ChannelAccountServices.sessionId(connectionId, kind: kind) {
                ChannelSessions.deleteBotToken(.telegram, sessionId: sessionId)
            }
        case .slack:
            let teamId =
                SlackConnectionConfigurationStore.load(connectionId: connectionId).configuredTeamIds.first
            if let teamId { SlackConnectionService.removeWorkspace(teamId: teamId) }
            SlackConnectionConfigurationStore.delete(connectionId: connectionId)
        case .email:
            var configuration = EmailChannelConfigurationStore.load()
            configuration.accounts.removeAll { $0.channelConnectionId == connectionId }
            try? EmailChannelConfigurationStore.save(configuration)
        default:
            return
        }
        for event in EventManager.shared.events(kind: kind, connectionId: connectionId) {
            EventManager.shared.delete(id: event.id)
        }
        try? AgentChannelConnectionManager.shared.disableBindings(connectionId: connectionId)
        ChannelAccountServices.forget(connectionId)
        NotificationCenter.default.post(name: .channelAccountSettingsChanged, object: connectionId)
    }
}
