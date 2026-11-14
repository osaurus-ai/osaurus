//
//  DiscordConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native Discord connection.
//

import Foundation

struct DiscordConnectionConfiguration: Codable, Equatable, Sendable {
    var configuredGuildIds: [String]
    var readableChannelIds: [String]
    var writableChannelIds: [String]
    var senderAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int

    init(
        configuredGuildIds: [String] = [],
        readableChannelIds: [String] = [],
        writableChannelIds: [String] = [],
        senderAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50
    ) {
        self.configuredGuildIds = Self.normalizedIds(configuredGuildIds)
        self.readableChannelIds = Self.normalizedIds(readableChannelIds)
        self.writableChannelIds = Self.normalizedIds(writableChannelIds)
        self.senderAllowlist = Self.normalizedIds(senderAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
    }

    var normalized: DiscordConnectionConfiguration {
        DiscordConnectionConfiguration(
            configuredGuildIds: configuredGuildIds,
            readableChannelIds: readableChannelIds,
            writableChannelIds: writableChannelIds,
            senderAllowlist: senderAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case configuredGuildIds
        case readableChannelIds
        case writableChannelIds
        case senderAllowlist
        case writeEnabled
        case defaultReadLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configuredGuildIds: try container.decodeIfPresent([String].self, forKey: .configuredGuildIds) ?? [],
            readableChannelIds: try container.decodeIfPresent([String].self, forKey: .readableChannelIds) ?? [],
            writableChannelIds: try container.decodeIfPresent([String].self, forKey: .writableChannelIds) ?? [],
            senderAllowlist: try container.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            writeEnabled: try container.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            defaultReadLimit: try container.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 50
        )
    }

    func canRead(channelId: String) -> Bool {
        readableChannelIds.contains(Self.normalizedId(channelId))
    }

    func canWrite(channelId: String) -> Bool {
        writeEnabled && writableChannelIds.contains(Self.normalizedId(channelId))
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidSnowflake(_ id: String) -> Bool {
        let trimmed = normalizedId(id)
        guard (5 ... 32).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

enum DiscordConnectionConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL? {
        didSet { cache.reset() }
    }

    /// In-memory copy of each bot's last loaded/saved configuration. See
    /// `ConnectionConfigurationCache` (Sentry APPLE-MACOS-3C5).
    private static let cache = ConnectionConfigurationCache<DiscordConnectionConfiguration>()

    /// Drop the in-memory copies so the next `load()` reads from disk.
    static func resetCache() {
        cache.reset()
    }

    /// Each bot has its own file: `discord.json` for the primary one,
    /// `<connection id>.json` for the others.
    static func load(
        connectionId: String = AgentChannelConnection.nativeDiscordConnectionId
    ) -> DiscordConnectionConfiguration {
        let url = configurationFileURL(connectionId: connectionId)
        return cache.value(for: url) { loadFromDisk(at: url) }
    }

    private static func loadFromDisk(at url: URL) -> DiscordConnectionConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DiscordConnectionConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(DiscordConnectionConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[Discord] Failed to load Discord configuration: \(error.localizedDescription)")
            return DiscordConnectionConfiguration()
        }
    }

    static func save(
        _ configuration: DiscordConnectionConfiguration,
        connectionId: String = AgentChannelConnection.nativeDiscordConnectionId
    ) throws {
        let url = configurationFileURL(connectionId: connectionId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let normalized = configuration.normalized
        let data = try encoder.encode(normalized)
        try LegacyInboundDispatchCarryOver.platformFile(data, replacing: url).write(to: url, options: [.atomic])
        cache.store(normalized, for: url)
        NotificationCenter.default.post(name: .channelAccountSettingsChanged, object: connectionId)
    }

    static func delete(connectionId: String) {
        guard connectionId != AgentChannelConnection.nativeDiscordConnectionId else { return }
        let url = configurationFileURL(connectionId: connectionId)
        try? FileManager.default.removeItem(at: url)
        cache.remove(for: url)
        NotificationCenter.default.post(name: .channelAccountSettingsChanged, object: connectionId)
    }

    static func configurationFileURL(
        connectionId: String = AgentChannelConnection.nativeDiscordConnectionId
    ) -> URL {
        (overrideDirectory ?? OsaurusPaths.config())
            .appendingPathComponent("\(connectionId).json", isDirectory: false)
    }
}

enum DiscordCredentialStore {
    static let pluginId = "osaurus.discord"
    static let botTokenKey = "bot_token"

    @discardableResult
    static func saveBotToken(_ token: String) -> Bool {
        saveBotTokenOutcome(token).isSuccess
    }

    static func saveBotTokenOutcome(_ token: String) -> CredentialWriteOutcome {
        ChannelCredentials.save(token, slot: ChannelCredentialSlots.discordBotToken)
    }

    static func botToken() -> String? {
        ChannelCredentials.value(ChannelCredentialSlots.discordBotToken, legacyPluginId: pluginId, legacyKey: botTokenKey)
    }

    static func hasBotToken() -> Bool {
        ChannelCredentials.has(ChannelCredentialSlots.discordBotToken, legacyPluginId: pluginId, legacyKey: botTokenKey)
    }

    @discardableResult
    static func deleteBotToken() -> Bool {
        ChannelCredentials.delete(
            ChannelCredentialSlots.discordBotToken, legacyPluginId: pluginId, legacyKey: botTokenKey)
    }
}

protocol DiscordCredentialStorage: Sendable {
    func saveBotToken(_ token: String) -> Bool
    func botToken() -> String?
    func hasBotToken() -> Bool
    func deleteBotToken() -> Bool
    func saveBotTokenOutcome(_ token: String) -> CredentialWriteOutcome
}

extension DiscordCredentialStorage {
    // Bool-only stores (test doubles) fall back to an undetailed outcome; the
    // Keychain-backed store overrides this with the real failure reason.
    func saveBotTokenOutcome(_ token: String) -> CredentialWriteOutcome {
        saveBotToken(token) ? .success : .keychainFailure("the save failed")
    }
}

struct KeychainDiscordCredentialStorage: DiscordCredentialStorage {
    func saveBotToken(_ token: String) -> Bool {
        DiscordCredentialStore.saveBotToken(token)
    }

    func saveBotTokenOutcome(_ token: String) -> CredentialWriteOutcome {
        DiscordCredentialStore.saveBotTokenOutcome(token)
    }

    func botToken() -> String? {
        DiscordCredentialStore.botToken()
    }

    func hasBotToken() -> Bool {
        DiscordCredentialStore.hasBotToken()
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        DiscordCredentialStore.deleteBotToken()
    }
}

enum DiscordSecurity {
    static func redact(_ text: String, token: String?) -> String {
        guard let token, token.count >= SecretScrubber.minimumValueLength else {
            return text
        }
        return text.replacingOccurrences(of: token, with: "[REDACTED:DISCORD_BOT_TOKEN]")
    }
}
