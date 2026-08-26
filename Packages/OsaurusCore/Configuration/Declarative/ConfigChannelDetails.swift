//
//  ConfigChannelDetails.swift
//  osaurus
//
//  Wave 3c — one uniform view over the five native channel platform
//  configurations for the declarative exporter / planner / applier.
//  Only the shared non-secret policy slice is bridged; platform extras
//  (polling, attachments, receipts, advanced actions) and per-room
//  dispatch routes are Settings-only and pass through untouched.
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
    var inbound: AgentChannelInboundDispatchConfiguration
}

/// The desired mutation derived from a `ChannelPlatformSection`; absent
/// fields stay untouched. `inboundAgentId` is pre-resolved by the applier.
struct ConfigChannelMutation {
    var writeEnabled: Bool?
    var defaultReadLimit: Int?
    var spaceAllowlist: [String]?
    var readAllowlist: [String]?
    var writeAllowlist: [String]?
    var senderAllowlist: [String]?
    var inboundEnabled: Bool?
    /// .absent leaves the target agent alone; .null clears it.
    var inboundAgentId: ConfigField<UUID> = .absent
    var requireMention: Bool?
    var continueThreads: Bool?
    var autoReplyEnabled: Bool?

    func applied(to inbound: AgentChannelInboundDispatchConfiguration)
        -> AgentChannelInboundDispatchConfiguration
    {
        var out = inbound
        if let v = inboundEnabled { out.enabled = v }
        switch inboundAgentId {
        case .absent: break
        case .null: out.targetAgentId = nil
        case .value(let id): out.targetAgentId = id
        }
        if let v = requireMention { out.requireMention = v }
        if let v = continueThreads { out.continueThreads = v }
        if let v = autoReplyEnabled { out.autoReplyEnabled = v }
        return out
    }
}

extension ConfigChannelPlatform {

    func snapshot() -> ConfigChannelSnapshot {
        switch self {
        case .discord:
            let c = DiscordConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: c.configuredGuildIds, readAllowlist: c.readableChannelIds,
                writeAllowlist: c.writableChannelIds, senderAllowlist: c.senderAllowlist,
                inbound: c.inboundDispatch)
        case .slack:
            let c = SlackConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: c.configuredTeamIds, readAllowlist: c.readableChannelIds,
                writeAllowlist: c.writableChannelIds, senderAllowlist: c.senderAllowlist,
                inbound: c.inboundDispatch)
        case .telegram:
            let c = TelegramConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist,
                inbound: c.inboundDispatch)
        case .imessage:
            let c = IMessageConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist,
                inbound: c.inboundDispatch)
        case .whatsapp:
            let c = WhatsAppConnectionConfigurationStore.load()
            return ConfigChannelSnapshot(
                writeEnabled: c.writeEnabled, defaultReadLimit: c.defaultReadLimit,
                spaceAllowlist: nil, readAllowlist: c.readableChatIds,
                writeAllowlist: c.writableChatIds, senderAllowlist: c.senderAllowlist,
                inbound: c.inboundDispatch)
        }
    }

    func apply(_ m: ConfigChannelMutation) throws {
        switch self {
        case .discord:
            var c = DiscordConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.spaceAllowlist { c.configuredGuildIds = v }
            if let v = m.readAllowlist { c.readableChannelIds = v }
            if let v = m.writeAllowlist { c.writableChannelIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            c.inboundDispatch = m.applied(to: c.inboundDispatch)
            try DiscordConnectionConfigurationStore.save(c.normalized)
        case .slack:
            var c = SlackConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.spaceAllowlist { c.configuredTeamIds = v }
            if let v = m.readAllowlist { c.readableChannelIds = v }
            if let v = m.writeAllowlist { c.writableChannelIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            c.inboundDispatch = m.applied(to: c.inboundDispatch)
            try SlackConnectionConfigurationStore.save(c.normalized)
        case .telegram:
            var c = TelegramConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            c.inboundDispatch = m.applied(to: c.inboundDispatch)
            try TelegramConnectionConfigurationStore.save(c.normalized)
        case .imessage:
            var c = IMessageConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            c.inboundDispatch = m.applied(to: c.inboundDispatch)
            try IMessageConnectionConfigurationStore.save(c.normalized)
        case .whatsapp:
            var c = WhatsAppConnectionConfigurationStore.load()
            if let v = m.writeEnabled { c.writeEnabled = v }
            if let v = m.defaultReadLimit { c.defaultReadLimit = v }
            if let v = m.readAllowlist { c.readableChatIds = v }
            if let v = m.writeAllowlist { c.writableChatIds = v }
            if let v = m.senderAllowlist { c.senderAllowlist = v }
            c.inboundDispatch = m.applied(to: c.inboundDispatch)
            try WhatsAppConnectionConfigurationStore.save(c.normalized)
        }
    }

    /// Restart the platform's receive transport so a policy change takes
    /// effect without a relaunch (same call the Settings panes make).
    func refreshRuntime() async {
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
        }
    }
}
