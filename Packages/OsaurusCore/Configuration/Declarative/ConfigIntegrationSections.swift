//
//  ConfigIntegrationSections.swift
//  osaurus
//
//  Wave 3c — integration sections of the declarative document: user slash
//  commands, knowledge collection registry, and channel routing. Channel
//  credentials (bot tokens, signing secrets) are Keychain-only and never
//  appear here; custom HTTP channel connections, outbound bindings, and
//  per-room dispatch routes stay in Settings.
//

import Foundation

// MARK: - Slash commands

/// One user-defined template slash command (`~/.osaurus/slash-commands/`).
/// Built-in action commands (/clear, /model, ...), skill-derived entries,
/// and plugin-imported commands are not manageable here.
public struct CommandEntry: Codable, Equatable, Sendable {
    /// Invoke as /name. Match key (case-insensitive).
    public var name: String
    public var description: String?
    /// SF Symbol name shown in the popup.
    public var icon: String?
    /// The prompt text inserted by the command. Required to create.
    public var template: String?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, description, icon, template
    }
}

// MARK: - Knowledge collections

/// One knowledge collection registration (`~/.osaurus/knowledge/collections/`).
/// The registry entry is configuration; the documents inside `folder_path`
/// are content and are never written by apply. Git-cloned collections are
/// created in Settings (interactive clone).
public struct KnowledgeCollectionEntry: Codable, Equatable, Sendable {
    /// Match key (case-insensitive).
    public var name: String
    public var summary: String?
    /// Existing directory holding the collection's documents; ~ expands.
    /// Immutable after create (recreate to move a collection).
    public var folderPath: String?
    public var enabled: Bool?
    /// Glob filters over files inside the folder. Replaces the lists.
    public var includeGlobs: [String]?
    public var excludeGlobs: [String]?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, summary
        case folderPath = "folder_path"
        case enabled
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
    }
}

// MARK: - Channels

/// Channels: the global write kill switch plus, per platform, what it
/// receives (allowlists), who answers (`routing`) and what it may send
/// (`write_*`, `posting`). n8n and custom HTTP connections carry their
/// routing under `connections`.
public struct ChannelsSection: Codable, Equatable, Sendable {
    /// Global kill switch over every channel send. Re-enabling is HIGH RISK.
    public var writeEnabled: Bool?
    public var discord: ChannelPlatformSection?
    public var slack: ChannelPlatformSection?
    public var telegram: ChannelPlatformSection?
    public var imessage: ChannelPlatformSection?
    public var whatsapp: ChannelPlatformSection?
    /// Mail accounts are added in Settings; rooms are `<account id>/<mailbox>`
    /// and senders are addresses or `@domain`.
    public var email: ChannelPlatformSection?
    /// Routing for n8n / custom HTTP connections (created in Settings).
    public var connections: [ChannelConnectionEntry]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case writeEnabled = "write_enabled"
        case discord, slack, telegram, imessage, whatsapp, email, connections
    }
}

/// Routing for one n8n / custom HTTP connection, matched by `connection`
/// (its name or id).
public struct ChannelConnectionEntry: Codable, Equatable, Sendable {
    public var connection: String
    public var routing: [ChannelRoutingRuleEntry]?

    public init(connection: String) {
        self.connection = connection
    }
}

/// The shared non-secret policy slice of one platform's connection config.
/// Provider ids (guilds, channels, chats, senders) are account-specific but
/// not secret. Platform extras (polling, attachments, advanced actions)
/// stay in Settings.
public struct ChannelPlatformSection: Equatable, Sendable {
    /// Letting agents SEND on this platform is HIGH RISK.
    public var writeEnabled: Bool?
    /// 1...100 messages per read.
    public var defaultReadLimit: Int?
    /// Discord guild ids / Slack team ids. Replaces the list.
    /// Not accepted for telegram/imessage/whatsapp.
    public var spaceAllowlist: [String]?
    /// Room/channel/chat ids agents may read. Replaces the list.
    public var readAllowlist: [String]?
    /// Room/channel/chat ids agents may write to. Replaces the list.
    public var writeAllowlist: [String]?
    /// Sender ids/handles whose messages are processed. Replaces the list.
    public var senderAllowlist: [String]?
    /// Legacy input only (`inbound_*`, `require_mention`, `continue_threads`,
    /// `auto_reply_enabled`): translated into the platform's default
    /// `events:` entry before planning and never exported.
    public var inboundEnabled: Bool?
    public var inboundAgent: ConfigField<String> = .absent
    public var requireMention: Bool?
    public var continueThreads: Bool?
    public var autoReplyEnabled: Bool?
    /// Write-only secret reference (env:VAR or keychain:service/account)
    /// for the platform bot token (discord, slack, telegram). Resolved at
    /// apply, stored in the Keychain, never exported.
    public var botTokenRef: String?
    /// Write-only secret reference for the Slack app-level (Socket Mode)
    /// token. Slack only.
    public var appTokenRef: String?
    /// Who answers messages here: one rule per channel automation.
    public var routing: [ChannelRoutingRuleEntry]?
    /// Which agents may post here on their own, and how.
    public var posting: [ChannelPostingEntry]?
    /// Set on an `accounts` entry: the account's connection id, e.g.
    /// `discord-<id>`, `slack-<team>` or `email-<mail account id>`.
    public var id: String?
    /// The platform's other accounts (extra bots, workspaces, mail
    /// accounts), each with the same policy and routing fields. Accounts
    /// with tokens are added in Settings; only Email accounts can be added
    /// here, for mail accounts that already exist.
    public var accounts: [ChannelPlatformSection]?

    public init() {}

    /// Any key that changes the platform's connection policy (as opposed to
    /// `routing` / `posting`, which live in automations and bindings).
    var hasPolicyKeys: Bool {
        writeEnabled != nil || defaultReadLimit != nil || spaceAllowlist != nil || readAllowlist != nil
            || writeAllowlist != nil || senderAllowlist != nil || botTokenRef != nil || appTokenRef != nil
    }
}

extension ChannelPlatformSection: Codable {
    enum CodingKeys: String, CodingKey {
        case writeEnabled = "write_enabled"
        case defaultReadLimit = "default_read_limit"
        case spaceAllowlist = "space_allowlist"
        case readAllowlist = "read_allowlist"
        case writeAllowlist = "write_allowlist"
        case senderAllowlist = "sender_allowlist"
        case inboundEnabled = "inbound_enabled"
        case inboundAgent = "inbound_agent"
        case requireMention = "require_mention"
        case continueThreads = "continue_threads"
        case autoReplyEnabled = "auto_reply_enabled"
        case botTokenRef = "bot_token_ref"
        case appTokenRef = "app_token_ref"
        case routing, posting, id, accounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writeEnabled = try c.decodeIfPresent(Bool.self, forKey: .writeEnabled)
        defaultReadLimit = try c.decodeIfPresent(Int.self, forKey: .defaultReadLimit)
        spaceAllowlist = try c.decodeIfPresent([String].self, forKey: .spaceAllowlist)
        readAllowlist = try c.decodeIfPresent([String].self, forKey: .readAllowlist)
        writeAllowlist = try c.decodeIfPresent([String].self, forKey: .writeAllowlist)
        senderAllowlist = try c.decodeIfPresent([String].self, forKey: .senderAllowlist)
        inboundEnabled = try c.decodeIfPresent(Bool.self, forKey: .inboundEnabled)
        inboundAgent = try c.configField(String.self, forKey: .inboundAgent)
        requireMention = try c.decodeIfPresent(Bool.self, forKey: .requireMention)
        continueThreads = try c.decodeIfPresent(Bool.self, forKey: .continueThreads)
        autoReplyEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReplyEnabled)
        botTokenRef = try c.decodeIfPresent(String.self, forKey: .botTokenRef)
        appTokenRef = try c.decodeIfPresent(String.self, forKey: .appTokenRef)
        routing = try c.decodeIfPresent([ChannelRoutingRuleEntry].self, forKey: .routing)
        posting = try c.decodeIfPresent([ChannelPostingEntry].self, forKey: .posting)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        accounts = try c.decodeIfPresent([ChannelPlatformSection].self, forKey: .accounts)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(writeEnabled, forKey: .writeEnabled)
        try c.encodeIfPresent(defaultReadLimit, forKey: .defaultReadLimit)
        try c.encodeIfPresent(spaceAllowlist, forKey: .spaceAllowlist)
        try c.encodeIfPresent(readAllowlist, forKey: .readAllowlist)
        try c.encodeIfPresent(writeAllowlist, forKey: .writeAllowlist)
        try c.encodeIfPresent(senderAllowlist, forKey: .senderAllowlist)
        try c.encodeIfPresent(inboundEnabled, forKey: .inboundEnabled)
        try c.encode(configField: inboundAgent, forKey: .inboundAgent)
        try c.encodeIfPresent(requireMention, forKey: .requireMention)
        try c.encodeIfPresent(continueThreads, forKey: .continueThreads)
        try c.encodeIfPresent(autoReplyEnabled, forKey: .autoReplyEnabled)
        try c.encodeIfPresent(botTokenRef, forKey: .botTokenRef)
        try c.encodeIfPresent(appTokenRef, forKey: .appTokenRef)
        try c.encodeIfPresent(routing, forKey: .routing)
        try c.encodeIfPresent(posting, forKey: .posting)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(accounts, forKey: .accounts)
    }
}

/// The native platforms, in canonical document order, with the
/// accessors the exporter/planner/applier iterate.
enum ConfigChannelPlatform: String, CaseIterable {
    case discord, slack, telegram, imessage, whatsapp, email

    /// Platforms whose config carries a space (guild/team) allowlist.
    var hasSpaceAllowlist: Bool {
        switch self {
        case .discord, .slack: return true
        case .telegram, .imessage, .whatsapp, .email: return false
        }
    }

    /// Email replies in every watched mailbox once sending is on, so it
    /// has no separate write list.
    var hasWriteAllowlist: Bool { self != .email }

    /// Platforms where agents may post on their own (not only reply).
    var supportsPosting: Bool { self != .email }

    /// Platforms whose credential is a single bot token that `bot_token_ref`
    /// can store. iMessage needs no token; WhatsApp links interactively;
    /// Email uses the mail accounts' own sign-in.
    var supportsBotTokenRef: Bool {
        switch self {
        case .discord, .slack, .telegram: return true
        case .imessage, .whatsapp, .email: return false
        }
    }

    /// Slack additionally uses an app-level (Socket Mode) token.
    var supportsAppTokenRef: Bool { self == .slack }

    /// Store a bot token resolved from a secret reference. Same Keychain
    /// slots the Settings panes write.
    func saveBotToken(_ token: String) -> Bool {
        switch self {
        case .discord: return DiscordCredentialStore.saveBotToken(token)
        case .slack: return SlackCredentialStore.saveBotToken(token)
        case .telegram: return TelegramCredentialStore.saveBotToken(token)
        case .imessage, .whatsapp, .email: return false
        }
    }

    func saveAppToken(_ token: String) -> Bool {
        guard self == .slack else { return false }
        return SlackCredentialStore.saveAppToken(token)
    }

    func section(in channels: ChannelsSection) -> ChannelPlatformSection? {
        switch self {
        case .discord: return channels.discord
        case .slack: return channels.slack
        case .telegram: return channels.telegram
        case .imessage: return channels.imessage
        case .whatsapp: return channels.whatsapp
        case .email: return channels.email
        }
    }

    func setSection(_ section: ChannelPlatformSection?, in channels: inout ChannelsSection) {
        switch self {
        case .discord: channels.discord = section
        case .slack: channels.slack = section
        case .telegram: channels.telegram = section
        case .imessage: channels.imessage = section
        case .whatsapp: channels.whatsapp = section
        case .email: channels.email = section
        }
    }
}

/// One account a `channels` document edits: the platform section itself
/// (the primary account) or one of its `accounts` entries.
struct ConfigChannelTarget {
    let platform: ConfigChannelPlatform
    let connectionId: String
    let section: ChannelPlatformSection
    /// Document path, e.g. `channels.slack` or `channels.slack.accounts[slack-t123]`.
    let path: String
    let isPrimary: Bool

    /// Plan / apply target name: `slack` or `slack slack-t123`.
    var label: String { isPrimary ? platform.rawValue : "\(platform.rawValue) \(connectionId)" }
}

extension ConfigChannelPlatform {
    /// The primary section and every `accounts` entry with an id.
    func targets(in channels: ChannelsSection) -> [ConfigChannelTarget] {
        guard let section = section(in: channels) else { return [] }
        let base = "channels.\(rawValue)"
        var out = [
            ConfigChannelTarget(
                platform: self, connectionId: primaryConnectionId, section: section, path: base, isPrimary: true)
        ]
        for account in section.accounts ?? [] {
            guard let raw = account.id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            let id = AgentChannelConnection.normalizedId(raw).lowercased()
            guard id != primaryConnectionId else { continue }
            out.append(
                ConfigChannelTarget(
                    platform: self, connectionId: id, section: account, path: "\(base).accounts[\(raw)]",
                    isPrimary: false))
        }
        return out
    }

    static func targets(in channels: ChannelsSection?) -> [ConfigChannelTarget] {
        guard let channels else { return [] }
        return allCases.flatMap { $0.targets(in: channels) }
    }
}
