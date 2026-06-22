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
    var writeEnabled: Bool
    var defaultReadLimit: Int

    init(
        configuredGuildIds: [String] = [],
        readableChannelIds: [String] = [],
        writableChannelIds: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50
    ) {
        self.configuredGuildIds = Self.normalizedIds(configuredGuildIds)
        self.readableChannelIds = Self.normalizedIds(readableChannelIds)
        self.writableChannelIds = Self.normalizedIds(writableChannelIds)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
    }

    var normalized: DiscordConnectionConfiguration {
        DiscordConnectionConfiguration(
            configuredGuildIds: configuredGuildIds,
            readableChannelIds: readableChannelIds,
            writableChannelIds: writableChannelIds,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit
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
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "discord.json"

    static func load() -> DiscordConnectionConfiguration {
        let url = configurationFileURL()
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

    static func save(_ configuration: DiscordConnectionConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.normalized).write(to: url, options: [.atomic])
    }

    static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return OsaurusPaths.config().appendingPathComponent(fileName)
    }
}

enum DiscordCredentialStore {
    static let pluginId = "osaurus.discord"
    static let botTokenKey = "bot_token"

    @discardableResult
    static func saveBotToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ToolSecretsKeychain.saveSecret(
            trimmed,
            id: botTokenKey,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    static func botToken() -> String? {
        ToolSecretsKeychain.getSecret(
            id: botTokenKey,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    static func hasBotToken() -> Bool {
        ToolSecretsKeychain.hasSecret(
            id: botTokenKey,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    @discardableResult
    static func deleteBotToken() -> Bool {
        ToolSecretsKeychain.deleteSecret(
            id: botTokenKey,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }
}

protocol DiscordCredentialStorage: Sendable {
    func saveBotToken(_ token: String) -> Bool
    func botToken() -> String?
    func hasBotToken() -> Bool
    func deleteBotToken() -> Bool
}

struct KeychainDiscordCredentialStorage: DiscordCredentialStorage {
    func saveBotToken(_ token: String) -> Bool {
        DiscordCredentialStore.saveBotToken(token)
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
