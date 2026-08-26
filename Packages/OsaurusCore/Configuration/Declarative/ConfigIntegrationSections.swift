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

/// Channel routing policy: the global write kill switch plus the non-secret
/// per-platform slices (allowlists, write/read policy, inbound dispatch).
public struct ChannelsSection: Codable, Equatable, Sendable {
    /// Global kill switch over every channel send. Re-enabling is HIGH RISK.
    public var writeEnabled: Bool?
    public var discord: ChannelPlatformSection?
    public var slack: ChannelPlatformSection?
    public var telegram: ChannelPlatformSection?
    public var imessage: ChannelPlatformSection?
    public var whatsapp: ChannelPlatformSection?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case writeEnabled = "write_enabled"
        case discord, slack, telegram, imessage, whatsapp
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
    /// Inbound dispatch: route incoming messages to an agent.
    public var inboundEnabled: Bool?
    /// CUSTOM agent name receiving unrouted inbound messages (channel
    /// dispatch never targets the Default agent); explicit null clears it.
    /// Per-room routes stay in Settings.
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

    public init() {}
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
    }
}

/// The five native platforms, in canonical document order, with the
/// accessors the exporter/planner/applier iterate.
enum ConfigChannelPlatform: String, CaseIterable {
    case discord, slack, telegram, imessage, whatsapp

    /// Platforms whose config carries a space (guild/team) allowlist.
    var hasSpaceAllowlist: Bool {
        switch self {
        case .discord, .slack: return true
        case .telegram, .imessage, .whatsapp: return false
        }
    }

    /// Platforms whose credential is a single bot token that `bot_token_ref`
    /// can store. iMessage needs no token; WhatsApp links interactively.
    var supportsBotTokenRef: Bool {
        switch self {
        case .discord, .slack, .telegram: return true
        case .imessage, .whatsapp: return false
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
        case .imessage, .whatsapp: return false
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
        }
    }

    func setSection(_ section: ChannelPlatformSection?, in channels: inout ChannelsSection) {
        switch self {
        case .discord: channels.discord = section
        case .slack: channels.slack = section
        case .telegram: channels.telegram = section
        case .imessage: channels.imessage = section
        case .whatsapp: channels.whatsapp = section
        }
    }
}
