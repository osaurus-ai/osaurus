//
//  DiscordConnectionService.swift
//  osaurus
//
//  Policy and diagnostics layer for the native Discord tools.
//

import Foundation

struct DiscordConfiguredGuildDiagnostic: Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let reason: String?

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "name": name,
            "status": status,
        ]
        if let reason {
            result["reason"] = reason
        }
        return result
    }
}

struct DiscordConnectionDiagnostics: Equatable, Sendable {
    let tokenSaved: Bool
    let bot: DiscordBotIdentity?
    let configuredGuilds: [DiscordConfiguredGuildDiagnostic]
    let readableChannelIds: [String]
    let writableChannelIds: [String]
    let writeEnabled: Bool
    let status: String
    let failures: [String]

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "token_saved": tokenSaved,
            "configured_guilds": configuredGuilds.map(\.dictionary),
            "readable_channel_ids": readableChannelIds,
            "writable_channel_ids": writableChannelIds,
            "write_enabled": writeEnabled,
            "status": status,
            "failures": failures,
        ]
        if let bot {
            result["bot"] = [
                "id": bot.id,
                "username": bot.username,
                "global_name": bot.globalName ?? "",
                "is_bot": bot.bot,
            ]
        }
        return result
    }
}

enum DiscordConnectionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidId(field: String)
    case guildNotConfigured(String)
    case channelNotReadable(String)
    case channelNotWritable(String)
    case writeDisabled
    case sendConfirmationRequired
    case messageTooLong
    case emptyMessage
    case configurationSaveFailed(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Discord is not configured. Add a bot token in Settings and allowlist at least one server/channel."
        case .invalidId(let field):
            return "`\(field)` must be a numeric Discord ID."
        case .guildNotConfigured(let guildId):
            return "Discord server `\(guildId)` is not allowlisted in settings."
        case .channelNotReadable(let channelId):
            return "Discord channel `\(channelId)` is not allowlisted for read access."
        case .channelNotWritable(let channelId):
            return "Discord channel `\(channelId)` is not allowlisted for write access."
        case .writeDisabled:
            return "Discord write access is disabled in settings."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus posts to Discord."
        case .messageTooLong:
            return "Discord messages must be 2000 characters or fewer."
        case .emptyMessage:
            return "Discord message content must not be empty."
        case .configurationSaveFailed(let message):
            return "Discord configuration could not be saved: \(message)"
        case .api(let message):
            return message
        }
    }
}

final class DiscordConnectionService: @unchecked Sendable {
    static let shared = DiscordConnectionService(
        client: DiscordAPIClient(),
        credentialStore: KeychainDiscordCredentialStorage(),
        messageStore: AgentChannelMessageStore.shared
    )

    private let client: DiscordAPIClientProtocol
    private let credentialStore: any DiscordCredentialStorage
    private let messageStore: AgentChannelMessageStore?
    private let recordMessageSnapshotsInline: Bool

    init(
        client: DiscordAPIClientProtocol,
        credentialStore: any DiscordCredentialStorage = KeychainDiscordCredentialStorage(),
        messageStore: AgentChannelMessageStore? = nil,
        recordMessageSnapshotsInline: Bool = false
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.messageStore = messageStore
        self.recordMessageSnapshotsInline = recordMessageSnapshotsInline
    }

    func configuration() -> DiscordConnectionConfiguration {
        DiscordConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: DiscordConnectionConfiguration) throws {
        do {
            try DiscordConnectionConfigurationStore.save(configuration)
        } catch {
            throw DiscordConnectionServiceError.configurationSaveFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func saveBotToken(_ token: String) throws -> Bool {
        let saved = credentialStore.saveBotToken(token)
        if !saved {
            throw DiscordConnectionServiceError.configurationSaveFailed(
                "The token was empty or Keychain storage was unavailable."
            )
        }
        return saved
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        credentialStore.deleteBotToken()
    }

    func hasBotToken() -> Bool {
        credentialStore.hasBotToken()
    }

    func diagnostics() async -> DiscordConnectionDiagnostics {
        let config = configuration()
        guard let token = credentialStore.botToken() else {
            return DiscordConnectionDiagnostics(
                tokenSaved: false,
                bot: nil,
                configuredGuilds: [],
                readableChannelIds: config.readableChannelIds,
                writableChannelIds: config.writableChannelIds,
                writeEnabled: config.writeEnabled,
                status: "not_configured",
                failures: ["No Discord bot token is saved."]
            )
        }

        var failures: [String] = []
        let bot: DiscordBotIdentity?
        do {
            bot = try await client.currentUser(token: token)
        } catch {
            bot = nil
            failures.append(redacted(error, token: token))
        }

        var guildRows: [DiscordConfiguredGuildDiagnostic] = []
        for guildId in config.configuredGuildIds {
            do {
                let guild = try await client.guild(id: guildId, token: token)
                guildRows.append(
                    DiscordConfiguredGuildDiagnostic(
                        id: guild.id,
                        name: guild.name,
                        status: "accessible",
                        reason: nil
                    )
                )
            } catch {
                guildRows.append(
                    DiscordConfiguredGuildDiagnostic(
                        id: guildId,
                        name: "",
                        status: "unavailable",
                        reason: redacted(error, token: token)
                    )
                )
            }
        }

        let status: String
        if bot == nil {
            status = "token_invalid_or_unavailable"
        } else if config.configuredGuildIds.isEmpty || config.readableChannelIds.isEmpty {
            status = "connected_needs_allowlist"
        } else if config.writeEnabled && config.writableChannelIds.isEmpty {
            status = "connected_read_only_write_needs_channels"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        return DiscordConnectionDiagnostics(
            tokenSaved: true,
            bot: bot,
            configuredGuilds: guildRows,
            readableChannelIds: config.readableChannelIds,
            writableChannelIds: config.writableChannelIds,
            writeEnabled: config.writeEnabled,
            status: status,
            failures: failures
        )
    }

    func messageStoreDiagnostics() -> [String: Any] {
        [
            "enabled": messageStore != nil,
            "open": messageStore?.isOpen ?? false,
            "database_path": OsaurusPaths.agentChannelMessagesDatabaseFile().path,
            "message_dedupe": "connection_id + room_id + provider_message_id",
            "event_dedupe": "connection_id + provider_event_id",
        ]
    }

    func listServers() async throws -> [[String: Any]] {
        let token = try requireToken()
        let config = configuration()
        guard !config.configuredGuildIds.isEmpty else {
            return []
        }

        var rows: [[String: Any]] = []
        for guildId in config.configuredGuildIds {
            do {
                let guild = try await client.guild(id: guildId, token: token)
                rows.append([
                    "id": guild.id,
                    "name": guild.name,
                    "configured": true,
                ])
            } catch {
                rows.append([
                    "id": guildId,
                    "name": "",
                    "configured": true,
                    "error": redacted(error, token: token),
                ])
            }
        }
        return rows
    }

    func listChannels(guildId: String) async throws -> [[String: Any]] {
        let token = try requireToken()
        let config = configuration()
        let normalizedGuildId = try requireSnowflake(guildId, field: "guild_id")
        guard config.configuredGuildIds.contains(normalizedGuildId) else {
            throw DiscordConnectionServiceError.guildNotConfigured(normalizedGuildId)
        }

        let channels = try await client.channels(guildId: normalizedGuildId, token: token)
        return channels.map { channel in
            [
                "id": channel.id,
                "name": channel.displayName,
                "type": channel.type,
                "guild_id": channel.guildId ?? normalizedGuildId,
                "parent_id": channel.parentId ?? "",
                "read_allowed": config.canRead(channelId: channel.id),
                "write_allowed": config.canWrite(channelId: channel.id),
            ]
        }
    }

    func readChannel(channelId: String, limit: Int?) async throws -> [String: Any] {
        let token = try requireToken()
        let config = configuration()
        let normalizedChannelId = try requireReadableChannel(channelId, config: config)
        let safeLimit = DiscordConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        let messages = try await client.messages(
            channelId: normalizedChannelId,
            token: token,
            limit: safeLimit
        )
        recordMessages(messages, channelId: normalizedChannelId, direction: .inbound)
        return [
            "kind": "discord_recent_messages",
            "channel_id": normalizedChannelId,
            "limit": safeLimit,
            "partial": true,
            "messages": messages.map(Self.messageDictionary),
        ]
    }

    func readThread(threadId: String, limit: Int?) async throws -> [String: Any] {
        let payload = try await readChannel(channelId: threadId, limit: limit)
        var result = payload
        result["kind"] = "discord_thread_messages"
        result["thread_id"] = DiscordConnectionConfiguration.normalizedId(threadId)
        return result
    }

    func findRecentMessages(
        query: String,
        channelIds: [String]?,
        limitPerChannel: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw DiscordConnectionServiceError.emptyMessage
        }

        let config = configuration()
        let candidateChannels = DiscordConnectionConfiguration.normalizedIds(
            channelIds ?? config.readableChannelIds
        )
        let allowedChannels = candidateChannels.filter { config.canRead(channelId: $0) }
        guard !allowedChannels.isEmpty else {
            throw DiscordConnectionServiceError.channelNotReadable(candidateChannels.first ?? "")
        }

        let token = try requireToken()
        let safeLimit = DiscordConnectionConfiguration.clampReadLimit(limitPerChannel ?? config.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        let needle = trimmedQuery.lowercased()
        var matches: [[String: Any]] = []

        for channelId in allowedChannels {
            let messages = try await client.messages(channelId: channelId, token: token, limit: safeLimit)
            recordMessages(messages, channelId: channelId, direction: .inbound)
            for message in messages {
                let haystack = "\(message.content) \(message.author.displayName) \(message.author.username)"
                    .lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append(Self.messageDictionary(message))
                if matches.count >= safeMaxMatches { break }
            }
            if matches.count >= safeMaxMatches { break }
        }

        return [
            "kind": "discord_recent_message_search",
            "query": trimmedQuery,
            "searched_channel_ids": allowedChannels,
            "limit_per_channel": safeLimit,
            "max_matches": safeMaxMatches,
            "match_count": matches.count,
            "partial": true,
            "messages": matches,
        ]
    }

    func draftMessage(channelId: String, content: String) throws -> [String: Any] {
        let config = configuration()
        let normalizedChannelId = try requireWritableChannel(channelId, config: config)
        let trimmedContent = try validateMessageContent(content)
        return [
            "kind": "discord_message_draft",
            "channel_id": normalizedChannelId,
            "content": trimmedContent,
            "requires_send_confirmation": true,
        ]
    }

    func sendMessage(
        channelId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else {
            throw DiscordConnectionServiceError.sendConfirmationRequired
        }
        let token = try requireToken()
        let config = configuration()
        let normalizedChannelId = try requireWritableChannel(channelId, config: config)
        let trimmedContent = try validateMessageContent(content)
        let message = try await client.sendMessage(
            channelId: normalizedChannelId,
            content: trimmedContent,
            token: token
        )
        recordMessages([message], channelId: normalizedChannelId, direction: .outbound)
        return [
            "kind": "discord_message_sent",
            "channel_id": normalizedChannelId,
            "message": Self.messageDictionary(message),
        ]
    }

    func replyToThread(
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        var result = try await sendMessage(
            channelId: threadId,
            content: content,
            confirmSend: confirmSend
        )
        result["kind"] = "discord_thread_reply_sent"
        result["thread_id"] = DiscordConnectionConfiguration.normalizedId(threadId)
        return result
    }

    private func requireToken() throws -> String {
        guard let token = credentialStore.botToken() else {
            throw DiscordConnectionServiceError.notConfigured
        }
        return token
    }

    private func requireSnowflake(_ id: String, field: String) throws -> String {
        let normalized = DiscordConnectionConfiguration.normalizedId(id)
        guard DiscordConnectionConfiguration.isValidSnowflake(normalized) else {
            throw DiscordConnectionServiceError.invalidId(field: field)
        }
        return normalized
    }

    private func requireReadableChannel(
        _ channelId: String,
        config: DiscordConnectionConfiguration
    ) throws -> String {
        let normalized = try requireSnowflake(channelId, field: "channel_id")
        guard config.canRead(channelId: normalized) else {
            throw DiscordConnectionServiceError.channelNotReadable(normalized)
        }
        return normalized
    }

    private func requireWritableChannel(
        _ channelId: String,
        config: DiscordConnectionConfiguration
    ) throws -> String {
        let normalized = try requireSnowflake(channelId, field: "channel_id")
        guard config.writeEnabled else {
            throw DiscordConnectionServiceError.writeDisabled
        }
        guard config.canWrite(channelId: normalized) else {
            throw DiscordConnectionServiceError.channelNotWritable(normalized)
        }
        return normalized
    }

    private func validateMessageContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DiscordConnectionServiceError.emptyMessage
        }
        guard trimmed.utf16.count <= 2000 else {
            throw DiscordConnectionServiceError.messageTooLong
        }
        return trimmed
    }

    private func redacted(_ error: Error, token: String) -> String {
        DiscordSecurity.redact(error.localizedDescription, token: token)
    }

    private func recordMessages(
        _ messages: [DiscordMessage],
        channelId: String,
        direction: AgentChannelStoredMessageDirection
    ) {
        guard let messageStore, !messages.isEmpty else { return }
        let rows = messages.map { message in
            Self.storedMessage(
                message,
                channelId: channelId,
                direction: direction
            )
        }
        if recordMessageSnapshotsInline {
            Self.persistMessages(rows, messageStore: messageStore)
        } else {
            Task.detached(priority: .utility) {
                Self.persistMessages(rows, messageStore: messageStore)
            }
        }
    }

    private static func persistMessages(
        _ rows: [AgentChannelStoredMessage],
        messageStore: AgentChannelMessageStore
    ) {
        do {
            try messageStore.openIfNeeded()
            _ = try messageStore.recordMessages(rows)
        } catch {
            NSLog("[Discord] Failed to record Agent Channel messages: \(error.localizedDescription)")
        }
    }

    private static func storedMessage(
        _ message: DiscordMessage,
        channelId: String,
        direction: AgentChannelStoredMessageDirection
    ) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: "discord",
            roomId: channelId,
            providerMessageId: message.id,
            direction: direction,
            authorId: message.author.id,
            authorName: message.author.displayName,
            content: message.content,
            payloadJSON: encodedPayload(message),
            providerTimestamp: message.timestamp
        )
    }

    private static func encodedPayload(_ message: DiscordMessage) -> String {
        guard let data = try? JSONEncoder().encode(message),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func messageDictionary(_ message: DiscordMessage) -> [String: Any] {
        [
            "id": message.id,
            "channel_id": message.channelId,
            "content": message.content,
            "timestamp": message.timestamp,
            "author": [
                "id": message.author.id,
                "username": message.author.username,
                "display_name": message.author.displayName,
                "is_bot": message.author.bot,
            ],
            "attachments": message.attachments.map { attachment in
                [
                    "id": attachment.id,
                    "filename": attachment.filename,
                    "url": attachment.url ?? "",
                    "content_type": attachment.contentType ?? "",
                    "size": attachment.size ?? 0,
                ]
            },
        ]
    }
}
