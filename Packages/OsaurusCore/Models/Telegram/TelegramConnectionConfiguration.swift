//
//  TelegramConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native Telegram connection.
//

import Foundation

struct TelegramConnectionConfiguration: Codable, Equatable, Sendable {
    var readableChatIds: [String]
    var writableChatIds: [String]
    var senderAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var ignoreSelfMessages: Bool
    var ignoreBotMessages: Bool
    var receiveStorageEnabled: Bool
    var longPollingEnabled: Bool
    var longPollingLimit: Int
    var longPollingTimeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case readableChatIds
        case writableChatIds
        case senderAllowlist
        case writeEnabled
        case defaultReadLimit
        case ignoreSelfMessages
        case ignoreBotMessages
        case receiveStorageEnabled
        case longPollingEnabled
        case longPollingLimit
        case longPollingTimeoutSeconds
    }

    init(
        readableChatIds: [String] = [],
        writableChatIds: [String] = [],
        senderAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        ignoreSelfMessages: Bool = true,
        ignoreBotMessages: Bool = true,
        receiveStorageEnabled: Bool = true,
        longPollingEnabled: Bool = false,
        longPollingLimit: Int = 100,
        longPollingTimeoutSeconds: Int = 20
    ) {
        self.readableChatIds = Self.normalizedIds(readableChatIds)
        self.writableChatIds = Self.normalizedIds(writableChatIds)
        self.senderAllowlist = Self.normalizedIds(senderAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.ignoreSelfMessages = ignoreSelfMessages
        self.ignoreBotMessages = ignoreBotMessages
        self.receiveStorageEnabled = receiveStorageEnabled
        self.longPollingEnabled = longPollingEnabled
        self.longPollingLimit = Self.clampLongPollingLimit(longPollingLimit)
        self.longPollingTimeoutSeconds = Self.clampLongPollingTimeoutSeconds(longPollingTimeoutSeconds)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            readableChatIds: try container.decodeIfPresent([String].self, forKey: .readableChatIds) ?? [],
            writableChatIds: try container.decodeIfPresent([String].self, forKey: .writableChatIds) ?? [],
            senderAllowlist: try container.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            writeEnabled: try container.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            defaultReadLimit: try container.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 50,
            ignoreSelfMessages: try container.decodeIfPresent(Bool.self, forKey: .ignoreSelfMessages) ?? true,
            ignoreBotMessages: try container.decodeIfPresent(Bool.self, forKey: .ignoreBotMessages) ?? true,
            receiveStorageEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .receiveStorageEnabled
            ) ?? true,
            longPollingEnabled: try container.decodeIfPresent(Bool.self, forKey: .longPollingEnabled) ?? false,
            longPollingLimit: try container.decodeIfPresent(Int.self, forKey: .longPollingLimit) ?? 100,
            longPollingTimeoutSeconds: try container.decodeIfPresent(
                Int.self,
                forKey: .longPollingTimeoutSeconds
            ) ?? 20
        )
    }

    var normalized: TelegramConnectionConfiguration {
        TelegramConnectionConfiguration(
            readableChatIds: readableChatIds,
            writableChatIds: writableChatIds,
            senderAllowlist: senderAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            ignoreSelfMessages: ignoreSelfMessages,
            ignoreBotMessages: ignoreBotMessages,
            receiveStorageEnabled: receiveStorageEnabled,
            longPollingEnabled: longPollingEnabled,
            longPollingLimit: longPollingLimit,
            longPollingTimeoutSeconds: longPollingTimeoutSeconds
        )
    }

    func canRead(chatId: String) -> Bool {
        readableChatIds.contains(Self.normalizedChatId(chatId))
    }

    func readableRoomId(for chat: TelegramChat) -> String? {
        let stableId = chat.stableId
        if canRead(chatId: stableId) {
            return stableId
        }
        if let username = chat.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            let handle = Self.normalizedChatId("@\(username)")
            if canRead(chatId: handle) {
                return handle
            }
        }
        return nil
    }

    func canWrite(chatId: String) -> Bool {
        writeEnabled && writableChatIds.contains(Self.normalizedChatId(chatId))
    }

    var configuredChatIds: [String] {
        Self.normalizedIds(readableChatIds + writableChatIds)
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedChatId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedChatId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            return trimmed.lowercased()
        }
        return trimmed
    }

    static func isValidChatId(_ id: String) -> Bool {
        let trimmed = normalizedChatId(id)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("@") {
            let username = String(trimmed.dropFirst())
            guard (5 ... 32).contains(username.count) else { return false }
            return username.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        guard (1 ... 32).contains(digits.count) else { return false }
        return digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    static func clampLongPollingLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    static func clampLongPollingTimeoutSeconds(_ value: Int) -> Int {
        min(max(value, 1), 50)
    }
}

enum TelegramConnectionConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "telegram.json"

    static func load() -> TelegramConnectionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TelegramConnectionConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(TelegramConnectionConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[Telegram] Failed to load Telegram configuration: \(error.localizedDescription)")
            return TelegramConnectionConfiguration()
        }
    }

    static func save(_ configuration: TelegramConnectionConfiguration) throws {
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

enum TelegramCredentialStore {
    static let pluginId = "osaurus.telegram"
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

protocol TelegramCredentialStorage: Sendable {
    func saveBotToken(_ token: String) -> Bool
    func botToken() -> String?
    func hasBotToken() -> Bool
    func deleteBotToken() -> Bool
}

struct KeychainTelegramCredentialStorage: TelegramCredentialStorage {
    func saveBotToken(_ token: String) -> Bool {
        TelegramCredentialStore.saveBotToken(token)
    }

    func botToken() -> String? {
        TelegramCredentialStore.botToken()
    }

    func hasBotToken() -> Bool {
        TelegramCredentialStore.hasBotToken()
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        TelegramCredentialStore.deleteBotToken()
    }
}

enum TelegramSecurity {
    static func redact(_ text: String, token: String?) -> String {
        guard let token, token.count >= SecretScrubber.minimumValueLength else {
            return text
        }
        return text.replacingOccurrences(of: token, with: "[REDACTED:TELEGRAM_BOT_TOKEN]")
    }
}
