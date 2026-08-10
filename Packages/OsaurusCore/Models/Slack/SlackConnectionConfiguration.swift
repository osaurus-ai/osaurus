//
//  SlackConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native Slack connection.
//

import Foundation
import CryptoKit

struct SlackWorkspaceAccountConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: String { teamId }
    var teamId: String
    var teamName: String?
    var readableChannelIds: [String]
    var writableChannelIds: [String]
    var senderAllowlist: [String]
    var botUserId: String?
    var botId: String?
    var apiAppId: String?

    init(
        teamId: String,
        teamName: String? = nil,
        readableChannelIds: [String] = [],
        writableChannelIds: [String] = [],
        senderAllowlist: [String] = [],
        botUserId: String? = nil,
        botId: String? = nil,
        apiAppId: String? = nil
    ) {
        self.teamId = SlackConnectionConfiguration.normalizedId(teamId)
        self.teamName = SlackConnectionConfiguration.normalizedOptionalId(teamName)
        self.readableChannelIds = SlackConnectionConfiguration.normalizedIds(readableChannelIds)
        self.writableChannelIds = SlackConnectionConfiguration.normalizedIds(writableChannelIds)
        self.senderAllowlist = SlackConnectionConfiguration.normalizedIds(senderAllowlist)
        self.botUserId = SlackConnectionConfiguration.normalizedOptionalId(botUserId)
        self.botId = SlackConnectionConfiguration.normalizedOptionalId(botId)
        self.apiAppId = SlackConnectionConfiguration.normalizedOptionalId(apiAppId)
    }
}

struct SlackConnectionConfiguration: Codable, Equatable, Sendable {
    var configuredTeamIds: [String]
    var readableChannelIds: [String]
    var writableChannelIds: [String]
    var senderAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var allowBroadcastMentions: Bool
    var botUserId: String?
    var botId: String?
    var apiAppId: String?
    var inboundDispatch: AgentChannelInboundDispatchConfiguration
    var workspaceAccounts: [SlackWorkspaceAccountConfiguration]

    init(
        configuredTeamIds: [String] = [],
        readableChannelIds: [String] = [],
        writableChannelIds: [String] = [],
        senderAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        allowBroadcastMentions: Bool = false,
        botUserId: String? = nil,
        botId: String? = nil,
        apiAppId: String? = nil,
        inboundDispatch: AgentChannelInboundDispatchConfiguration = AgentChannelInboundDispatchConfiguration(),
        workspaceAccounts: [SlackWorkspaceAccountConfiguration] = []
    ) {
        self.configuredTeamIds = Self.normalizedIds(configuredTeamIds)
        self.readableChannelIds = Self.normalizedIds(readableChannelIds)
        self.writableChannelIds = Self.normalizedIds(writableChannelIds)
        self.senderAllowlist = Self.normalizedIds(senderAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.allowBroadcastMentions = allowBroadcastMentions
        self.botUserId = Self.normalizedOptionalId(botUserId)
        self.botId = Self.normalizedOptionalId(botId)
        self.apiAppId = Self.normalizedOptionalId(apiAppId)
        self.inboundDispatch = inboundDispatch
        var seenTeams = Set<String>()
        self.workspaceAccounts = workspaceAccounts.filter {
            !$0.teamId.isEmpty && seenTeams.insert($0.teamId).inserted
        }
    }

    var normalized: SlackConnectionConfiguration {
        SlackConnectionConfiguration(
            configuredTeamIds: configuredTeamIds,
            readableChannelIds: readableChannelIds,
            writableChannelIds: writableChannelIds,
            senderAllowlist: senderAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            allowBroadcastMentions: allowBroadcastMentions,
            botUserId: botUserId,
            botId: botId,
            apiAppId: apiAppId,
            inboundDispatch: inboundDispatch,
            workspaceAccounts: workspaceAccounts
        )
    }

    func canRead(channelId: String) -> Bool {
        let channelId = Self.normalizedId(channelId)
        return readableChannelIds.contains(channelId)
            || workspaceAccounts.contains { $0.readableChannelIds.contains(channelId) }
    }

    func canWrite(channelId: String) -> Bool {
        let channelId = Self.normalizedId(channelId)
        return writeEnabled
            && (writableChannelIds.contains(channelId)
                || workspaceAccounts.contains { $0.writableChannelIds.contains(channelId) })
    }

    func canUseTeam(teamId: String) -> Bool {
        let normalized = Self.normalizedId(teamId)
        return configuredTeamIds.isEmpty
            || configuredTeamIds.contains(normalized)
            || workspaceAccounts.contains { $0.teamId == normalized }
    }

    func canUseSender(senderId: String?) -> Bool {
        guard let normalized = Self.normalizedOptionalId(senderId) else {
            return false
        }
        return senderAllowlist.contains(normalized)
            || workspaceAccounts.contains { $0.senderAllowlist.contains(normalized) }
    }

    enum CodingKeys: String, CodingKey {
        case configuredTeamIds
        case readableChannelIds
        case writableChannelIds
        case senderAllowlist
        case writeEnabled
        case defaultReadLimit
        case allowBroadcastMentions
        case botUserId
        case botId
        case apiAppId
        case inboundDispatch
        case workspaceAccounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configuredTeamIds: try container.decodeIfPresent([String].self, forKey: .configuredTeamIds) ?? [],
            readableChannelIds: try container.decodeIfPresent([String].self, forKey: .readableChannelIds) ?? [],
            writableChannelIds: try container.decodeIfPresent([String].self, forKey: .writableChannelIds) ?? [],
            senderAllowlist: try container.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            writeEnabled: try container.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            defaultReadLimit: try container.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 50,
            allowBroadcastMentions: try container.decodeIfPresent(
                Bool.self,
                forKey: .allowBroadcastMentions
            ) ?? false,
            botUserId: try container.decodeIfPresent(String.self, forKey: .botUserId),
            botId: try container.decodeIfPresent(String.self, forKey: .botId),
            apiAppId: try container.decodeIfPresent(String.self, forKey: .apiAppId),
            inboundDispatch: try container.decodeIfPresent(
                AgentChannelInboundDispatchConfiguration.self,
                forKey: .inboundDispatch
            ) ?? AgentChannelInboundDispatchConfiguration(),
            workspaceAccounts: try container.decodeIfPresent(
                [SlackWorkspaceAccountConfiguration].self,
                forKey: .workspaceAccounts
            ) ?? []
        )
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

    static func normalizedOptionalId(_ id: String?) -> String? {
        let normalized = normalizedId(id ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    static func isValidSlackId(_ id: String) -> Bool {
        let trimmed = normalizedId(id)
        guard (2 ... 64).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
        }
    }

    static func isValidSlackId(_ id: String, allowedPrefixes: Set<Character>) -> Bool {
        let trimmed = normalizedId(id)
        return isValidSlackId(trimmed)
            && (trimmed.first.map { allowedPrefixes.contains($0) } ?? false)
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
    static let appTokenKey = "app_token"

    static func accountSecretKey(_ base: String, teamId: String) -> String {
        "\(base).workspace.\(SlackConnectionConfiguration.normalizedId(teamId))"
    }

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

    @discardableResult
    static func saveAppToken(_ token: String) -> Bool {
        saveSecret(token, id: appTokenKey)
    }

    static func appToken() -> String? {
        secret(id: appTokenKey)
    }

    static func hasAppToken() -> Bool {
        hasSecret(id: appTokenKey)
    }

    @discardableResult
    static func deleteAppToken() -> Bool {
        deleteSecret(id: appTokenKey)
    }

    static func saveBotToken(_ token: String, teamId: String) -> Bool {
        saveSecret(token, id: accountSecretKey(botTokenKey, teamId: teamId))
    }

    static func botToken(teamId: String) -> String? {
        secret(id: accountSecretKey(botTokenKey, teamId: teamId))
    }

    static func hasBotToken(teamId: String) -> Bool {
        hasSecret(id: accountSecretKey(botTokenKey, teamId: teamId))
    }

    static func deleteBotToken(teamId: String) -> Bool {
        deleteSecret(id: accountSecretKey(botTokenKey, teamId: teamId))
    }

    static func saveAppToken(_ token: String, teamId: String) -> Bool {
        saveSecret(token, id: accountSecretKey(appTokenKey, teamId: teamId))
    }

    static func appToken(teamId: String) -> String? {
        secret(id: accountSecretKey(appTokenKey, teamId: teamId))
    }

    static func deleteAppToken(teamId: String) -> Bool {
        deleteSecret(id: accountSecretKey(appTokenKey, teamId: teamId))
    }

    private static func saveSecret(_ value: String, id: String) -> Bool {
        saveSecretOutcome(value, id: id).isSuccess
    }

    static func saveSecretOutcome(_ value: String, id: String) -> SecretSaveOutcome {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyValue }
        let outcome = ToolSecretsKeychain.saveSecretOutcome(
            trimmed,
            id: id,
            for: pluginId,
            agentId: Agent.defaultId
        )
        return outcome == .success ? .success : .keychainFailure(outcome)
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
    func saveAppToken(_ token: String) -> Bool
    func appToken() -> String?
    func hasAppToken() -> Bool
    func deleteAppToken() -> Bool
    func saveBotToken(_ token: String, teamId: String) -> Bool
    func botToken(teamId: String) -> String?
    func hasBotToken(teamId: String) -> Bool
    func deleteBotToken(teamId: String) -> Bool
    func saveAppToken(_ token: String, teamId: String) -> Bool
    func appToken(teamId: String) -> String?
    func deleteAppToken(teamId: String) -> Bool
    func saveBotTokenOutcome(_ token: String) -> SecretSaveOutcome
    func saveSigningSecretOutcome(_ secret: String) -> SecretSaveOutcome
    func saveAppTokenOutcome(_ token: String) -> SecretSaveOutcome
}

extension SlackCredentialStorage {
    // Bool-only stores (test doubles) fall back to an undetailed outcome; the
    // Keychain-backed store overrides these with the real failure reason.
    func saveBotTokenOutcome(_ token: String) -> SecretSaveOutcome {
        saveBotToken(token) ? .success : .unknownFailure
    }

    func saveSigningSecretOutcome(_ secret: String) -> SecretSaveOutcome {
        saveSigningSecret(secret) ? .success : .unknownFailure
    }

    func saveAppTokenOutcome(_ token: String) -> SecretSaveOutcome {
        saveAppToken(token) ? .success : .unknownFailure
    }
    func saveBotToken(_: String, teamId _: String) -> Bool { false }
    func botToken(teamId _: String) -> String? { nil }
    func hasBotToken(teamId _: String) -> Bool { false }
    func deleteBotToken(teamId _: String) -> Bool { false }
    func saveAppToken(_: String, teamId _: String) -> Bool { false }
    func appToken(teamId _: String) -> String? { nil }
    func deleteAppToken(teamId _: String) -> Bool { false }
}

struct KeychainSlackCredentialStorage: SlackCredentialStorage {
    func saveBotToken(_ token: String) -> Bool {
        SlackCredentialStore.saveBotToken(token)
    }

    func saveBotTokenOutcome(_ token: String) -> SecretSaveOutcome {
        SlackCredentialStore.saveSecretOutcome(token, id: SlackCredentialStore.botTokenKey)
    }

    func saveSigningSecretOutcome(_ secret: String) -> SecretSaveOutcome {
        SlackCredentialStore.saveSecretOutcome(secret, id: SlackCredentialStore.signingSecretKey)
    }

    func saveAppTokenOutcome(_ token: String) -> SecretSaveOutcome {
        SlackCredentialStore.saveSecretOutcome(token, id: SlackCredentialStore.appTokenKey)
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

    func saveAppToken(_ token: String) -> Bool {
        SlackCredentialStore.saveAppToken(token)
    }

    func appToken() -> String? {
        SlackCredentialStore.appToken()
    }

    func hasAppToken() -> Bool {
        SlackCredentialStore.hasAppToken()
    }

    @discardableResult
    func deleteAppToken() -> Bool {
        SlackCredentialStore.deleteAppToken()
    }

    func saveBotToken(_ token: String, teamId: String) -> Bool {
        SlackCredentialStore.saveBotToken(token, teamId: teamId)
    }

    func botToken(teamId: String) -> String? {
        SlackCredentialStore.botToken(teamId: teamId)
    }

    func hasBotToken(teamId: String) -> Bool {
        SlackCredentialStore.hasBotToken(teamId: teamId)
    }

    func deleteBotToken(teamId: String) -> Bool {
        SlackCredentialStore.deleteBotToken(teamId: teamId)
    }

    func saveAppToken(_ token: String, teamId: String) -> Bool {
        SlackCredentialStore.saveAppToken(token, teamId: teamId)
    }

    func appToken(teamId: String) -> String? {
        SlackCredentialStore.appToken(teamId: teamId)
    }

    func deleteAppToken(teamId: String) -> Bool {
        SlackCredentialStore.deleteAppToken(teamId: teamId)
    }
}

enum SlackSecurity {
    static func redact(
        _ text: String,
        token: String?,
        signingSecret: String? = nil,
        appToken: String? = nil
    ) -> String {
        var redacted = redactValue(text, value: token, replacement: "[REDACTED:SLACK_BOT_TOKEN]")
        redacted = redactValue(redacted, value: signingSecret, replacement: "[REDACTED:SLACK_SIGNING_SECRET]")
        redacted = redactValue(redacted, value: appToken, replacement: "[REDACTED:SLACK_APP_TOKEN]")
        return redacted
    }

    private static func redactValue(_ text: String, value: String?, replacement: String) -> String {
        guard let value, value.count >= SecretScrubber.minimumValueLength else {
            return text
        }
        return text.replacingOccurrences(of: value, with: replacement)
    }
}

enum SlackSignatureVerifier {
    static func isAuthorized(
        signingSecret: String,
        timestamp: String,
        body: Data,
        signature: String,
        now: Date = Date(),
        tolerance: TimeInterval = 300
    ) -> Bool {
        let trimmedSecret = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTimestamp = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSignature = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedSecret.isEmpty,
              let timestampSeconds = TimeInterval(trimmedTimestamp),
              abs(now.timeIntervalSince1970 - timestampSeconds) <= tolerance,
              trimmedSignature.hasPrefix("v0=")
        else {
            return false
        }

        var base = Data("v0:\(trimmedTimestamp):".utf8)
        base.append(body)
        let key = SymmetricKey(data: Data(trimmedSecret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: base, using: key)
        let expected = "v0=" + digest.map { String(format: "%02x", $0) }.joined()
        return constantTimeEquals(trimmedSignature, expected)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}
