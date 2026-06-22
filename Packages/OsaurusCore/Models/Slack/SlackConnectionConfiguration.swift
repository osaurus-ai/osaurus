//
//  SlackConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native Slack connection.
//

import Foundation

struct SlackConnectionConfiguration: Codable, Equatable, Sendable {
    var configuredTeamIds: [String]
    var readableChannelIds: [String]
    var writableChannelIds: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var allowBroadcastMentions: Bool

    init(
        configuredTeamIds: [String] = [],
        readableChannelIds: [String] = [],
        writableChannelIds: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        allowBroadcastMentions: Bool = false
    ) {
        self.configuredTeamIds = Self.normalizedIds(configuredTeamIds)
        self.readableChannelIds = Self.normalizedIds(readableChannelIds)
        self.writableChannelIds = Self.normalizedIds(writableChannelIds)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.allowBroadcastMentions = allowBroadcastMentions
    }

    var normalized: SlackConnectionConfiguration {
        SlackConnectionConfiguration(
            configuredTeamIds: configuredTeamIds,
            readableChannelIds: readableChannelIds,
            writableChannelIds: writableChannelIds,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            allowBroadcastMentions: allowBroadcastMentions
        )
    }

    func canRead(channelId: String) -> Bool {
        readableChannelIds.contains(Self.normalizedId(channelId))
    }

    func canWrite(channelId: String) -> Bool {
        writeEnabled && writableChannelIds.contains(Self.normalizedId(channelId))
    }

    func canUseTeam(teamId: String) -> Bool {
        let normalized = Self.normalizedId(teamId)
        return configuredTeamIds.isEmpty || configuredTeamIds.contains(normalized)
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map(normalizedId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidSlackId(_ id: String) -> Bool {
        let trimmed = normalizedId(id)
        guard (2 ... 64).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
        }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

enum SlackConnectionConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "slack.json"

    static func load() -> SlackConnectionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SlackConnectionConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(SlackConnectionConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[Slack] Failed to load Slack configuration: \(error.localizedDescription)")
            return SlackConnectionConfiguration()
        }
    }

    static func save(_ configuration: SlackConnectionConfiguration) throws {
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

enum SlackCredentialStore {
    static let pluginId = "osaurus.slack"
    static let botTokenKey = "bot_token"
    static let signingSecretKey = "signing_secret"

    @discardableResult
    static func saveBotToken(_ token: String) -> Bool {
        saveSecret(token, id: botTokenKey)
    }

    static func botToken() -> String? {
        secret(id: botTokenKey)
    }

    static func hasBotToken() -> Bool {
        hasSecret(id: botTokenKey)
    }

    @discardableResult
    static func deleteBotToken() -> Bool {
        deleteSecret(id: botTokenKey)
    }

    @discardableResult
    static func saveSigningSecret(_ secret: String) -> Bool {
        saveSecret(secret, id: signingSecretKey)
    }

    static func signingSecret() -> String? {
        secret(id: signingSecretKey)
    }

    static func hasSigningSecret() -> Bool {
        hasSecret(id: signingSecretKey)
    }

    @discardableResult
    static func deleteSigningSecret() -> Bool {
        deleteSecret(id: signingSecretKey)
    }

    private static func saveSecret(_ value: String, id: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ToolSecretsKeychain.saveSecret(
            trimmed,
            id: id,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    private static func secret(id: String) -> String? {
        ToolSecretsKeychain.getSecret(
            id: id,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    private static func hasSecret(id: String) -> Bool {
        ToolSecretsKeychain.hasSecret(
            id: id,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }

    @discardableResult
    private static func deleteSecret(id: String) -> Bool {
        ToolSecretsKeychain.deleteSecret(
            id: id,
            for: pluginId,
            agentId: Agent.defaultId
        )
    }
}

protocol SlackCredentialStorage: Sendable {
    func saveBotToken(_ token: String) -> Bool
    func botToken() -> String?
    func hasBotToken() -> Bool
    func deleteBotToken() -> Bool
    func saveSigningSecret(_ secret: String) -> Bool
    func signingSecret() -> String?
    func hasSigningSecret() -> Bool
    func deleteSigningSecret() -> Bool
}

struct KeychainSlackCredentialStorage: SlackCredentialStorage {
    func saveBotToken(_ token: String) -> Bool {
        SlackCredentialStore.saveBotToken(token)
    }

    func botToken() -> String? {
        SlackCredentialStore.botToken()
    }

    func hasBotToken() -> Bool {
        SlackCredentialStore.hasBotToken()
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        SlackCredentialStore.deleteBotToken()
    }

    func saveSigningSecret(_ secret: String) -> Bool {
        SlackCredentialStore.saveSigningSecret(secret)
    }

    func signingSecret() -> String? {
        SlackCredentialStore.signingSecret()
    }

    func hasSigningSecret() -> Bool {
        SlackCredentialStore.hasSigningSecret()
    }

    @discardableResult
    func deleteSigningSecret() -> Bool {
        SlackCredentialStore.deleteSigningSecret()
    }
}

enum SlackSecurity {
    static func redact(_ text: String, token: String?, signingSecret: String? = nil) -> String {
        var redacted = redactValue(text, value: token, replacement: "[REDACTED:SLACK_BOT_TOKEN]")
        redacted = redactValue(redacted, value: signingSecret, replacement: "[REDACTED:SLACK_SIGNING_SECRET]")
        return redacted
    }

    private static func redactValue(_ text: String, value: String?, replacement: String) -> String {
        guard let value, value.count >= SecretScrubber.minimumValueLength else {
            return text
        }
        return text.replacingOccurrences(of: value, with: replacement)
    }
}
