//
//  ConfigChannelDetails.swift
//  osaurus
//
//  Wave 3c — one uniform view over the native channel platform
//  configurations for the declarative exporter / planner / applier.
//  Only the shared non-secret policy slice is bridged; platform extras
//  (polling, attachments, receipts, advanced actions) are Settings-only
//  and pass through untouched. Which agent or workflow a message runs is
//  an event (`events:` section), not channel config.
//

import Foundation

/// The bridged slice of one platform's connection configuration.
struct ConfigChannelSnapshot {
    var writeEnabled: Bool
    var defaultReadLimit: Int
    /// nil for platforms without a guild/team allowlist.
    var spaceAllowlist: [String]?
    var readAllowlist: [String]
    var writeAllowlist: [String]
    var senderAllowlist: [String]
}

/// The desired mutation derived from a `ChannelPlatformSection`; absent
/// fields stay untouched.
struct ConfigChannelMutation {
    var writeEnabled: Bool?
    var defaultReadLimit: Int?
    var spaceAllowlist: [String]?
    var readAllowlist: [String]?
    var writeAllowlist: [String]?
    var senderAllowlist: [String]?
}

extension ConfigChannelPlatform {

    var kind: AgentChannelKind { AgentChannelKind(rawValue: rawValue) ?? .discord }

    /// The connection `channels.<platform>` edits: the primary account.
    var primaryConnectionId: String { ChannelAccounts.primaryConnectionId(kind) ?? rawValue }

    func snapshot(connectionId: String? = nil) -> ConfigChannelSnapshot {
        let id = connectionId ?? primaryConnectionId
        switch self {
        case .discord:
            let c = DiscordConnectionConfigurationStore.load(connectionId: id)
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: c.configuredGuildIds, readAllowlist: c.readableChannelIds,
                writeAllowlist: c.writableChannelIds, senderAllowlist: c.senderAllowlist)
        case .slack:
            let c = SlackConnectionConfigurationStore.load(connectionId: id)
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: c.configuredTeamIds, readAllowlist: c.readableChannelIds,
                writeAllowlist: c.writableChannelIds, senderAllowlist: c.senderAllowlist)
        case .telegram:
            let c = TelegramConnectionConfigurationStore.load(connectionId: id)
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist)
        case .imessage:
            let c = IMessageConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist)
        case .whatsapp:
            let c = WhatsAppConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist)
        case .email:
            let c = EmailChannelConfigurationStore.load().account(channelConnectionId: id)
            let rooms = c?.roomIds ?? []
            return ConfigChannelSnapshot(
                writeEnabled: c?.writeEnabled ?? false, defaultReadLimit: c?.defaultReadLimit ?? 25,
                spaceAllowlist: nil, readAllowlist: rooms,
                writeAllowlist: c?.writeEnabled == true ? rooms : [], senderAllowlist: c?.senderAllowlist ?? [])
        }
    }

    @MainActor
    func apply(_ m: ConfigChannelMutation, connectionId: String? = nil) throws {
        let id = connectionId ?? primaryConnectionId
        switch self {
        case .discord:
            var c = DiscordConnectionConfigurationStore.load(connectionId: id)
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.spaceAllowlist { c.configuredGuildIds = v }
            if let v = m.readAllowlist { c.readableChannelIds = v }
            if let v = m.writeAllowlist { c.writableChannelIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            try DiscordConnectionConfigurationStore.save(c.normalized, connectionId: id)
        case .slack:
            var c = SlackConnectionConfigurationStore.load(connectionId: id)
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.spaceAllowlist { c.configuredTeamIds = v }
            if let v = m.readAllowlist { c.readableChannelIds = v }
            if let v = m.writeAllowlist { c.writableChannelIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            try SlackConnectionConfigurationStore.save(c.normalized, connectionId: id)
        case .telegram:
            var c = TelegramConnectionConfigurationStore.load(connectionId: id)
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            try TelegramConnectionConfigurationStore.save(c.normalized, connectionId: id)
        case .imessage:
            var c = IMessageConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            try IMessageConnectionConfigurationStore.save(c.normalized)
        case .whatsapp:
            var c = WhatsAppConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            try WhatsAppConnectionConfigurationStore.save(c.normalized)
        case .email:
            var c = EmailChannelConfigurationStore.load()
            if c.account(channelConnectionId: id) == nil,
                let source = ConfigChannelAccounts.mailSourceId(forEmailConnectionId: id),
                c.account(connectionId: source) == nil
            {
                c.accounts.append(EmailChannelAccount(connectionId: source, channelConnectionId: id))
            }
            if let v = m.readAllowlist { c.accounts = Self.emailAccounts(rooms: v, for: id, keeping: c) }
            c = c.normalized
            guard let index = c.accounts.firstIndex(where: { $0.channelConnectionId == id }) else {
                try EmailChannelConfigurationStore.save(c)
                return
            }
            if let v = m.writeEnabled { c.accounts[index].writeEnabled = v }
            if let v = m.defaultReadLimit {
                c.accounts[index].defaultReadLimit = EmailChannelConfiguration.clampReadLimit(v)
            }
            if let v = m.senderAllowlist {
                c.accounts[index].senderAllowlist = EmailChannelConfiguration.normalizedSenders(v)
            }
            try EmailChannelConfigurationStore.save(c)
        }
    }

    /// Applies `<account id>/<mailbox>` rooms to the Email account that is
    /// `channelConnectionId`: its mailboxes become the rooms naming its mail
    /// account. A room naming a mail account that isn't watched yet adds it
    /// (as the primary when none claims `email`); other accounts keep theirs.
    static func emailAccounts(
        rooms: [String], for channelConnectionId: String, keeping current: EmailChannelConfiguration
    ) -> [EmailChannelAccount] {
        var order: [String] = []
        var mailboxes: [String: [String]] = [:]
        for room in rooms {
            guard let route = EmailChannelConfiguration.parseRoomId(room) else { continue }
            if mailboxes[route.connectionId] == nil { order.append(route.connectionId) }
            mailboxes[route.connectionId, default: []].append(route.mailbox)
        }
        var accounts = current.accounts
        if let target = current.account(channelConnectionId: channelConnectionId),
            let index = accounts.firstIndex(where: { $0.connectionId == target.connectionId })
        {
            accounts[index].mailboxes = ChannelMessageSourceConfig.normalizedRooms(
                mailboxes[target.connectionId] ?? [])
        }
        for id in order where !accounts.contains(where: { $0.connectionId == id }) {
            let claimsTarget = current.account(channelConnectionId: channelConnectionId) == nil
                && !accounts.contains(where: { $0.channelConnectionId == channelConnectionId })
            accounts.append(
                EmailChannelAccount(
                    connectionId: id, channelConnectionId: claimsTarget ? channelConnectionId : "",
                    mailboxes: mailboxes[id] ?? []))
        }
        return accounts
    }

    /// Restart the platform's receive transport so a policy change takes
    /// effect without a relaunch (same call the Settings panes make).
    func refreshRuntime() async {
        await AgentChannelTransportSupervisor.shared.refreshAccountRuntimes()
        switch self {
        case .discord:
            await AgentChannelTransportSupervisor.shared.refreshDiscordRuntime()
        case .slack:
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
        case .telegram:
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
        case .imessage:
            await AgentChannelTransportSupervisor.shared.refreshIMessageRuntime()
        case .whatsapp:
            await AgentChannelTransportSupervisor.shared.refreshWhatsAppRuntime()
        case .email:
            await AgentChannelTransportSupervisor.shared.refreshEmailRuntime()
        }
    }
}
