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
    let senderAllowlist: [String]
    let writeEnabled: Bool
    let inboundDispatchEnabled: Bool
    let inboundDispatchIssue: String?
    let status: String
    let failures: [String]
    let warnings: [String]

    init(
        tokenSaved: Bool,
        bot: DiscordBotIdentity?,
        configuredGuilds: [DiscordConfiguredGuildDiagnostic],
        readableChannelIds: [String],
        writableChannelIds: [String],
        senderAllowlist: [String] = [],
        writeEnabled: Bool,
        inboundDispatchEnabled: Bool = false,
        inboundDispatchIssue: String? = nil,
        status: String,
        failures: [String],
        warnings: [String] = []
    ) {
        self.tokenSaved = tokenSaved
        self.bot = bot
        self.configuredGuilds = configuredGuilds
        self.readableChannelIds = readableChannelIds
        self.writableChannelIds = writableChannelIds
        self.senderAllowlist = senderAllowlist
        self.writeEnabled = writeEnabled
        self.inboundDispatchEnabled = inboundDispatchEnabled
        self.inboundDispatchIssue = inboundDispatchIssue
        self.status = status
        self.failures = failures
        self.warnings = warnings
    }

    /// True only when the polling receive path has every prerequisite it
    /// needs for Discord messages to reach the local Agent Channel inbox.
    var receiveReady: Bool {
        tokenSaved
            && bot != nil
            && !readableChannelIds.isEmpty
            && !senderAllowlist.isEmpty
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "token_saved": tokenSaved,
            "configured_guilds": configuredGuilds.map(\.dictionary),
            "readable_channel_ids": readableChannelIds,
            "writable_channel_ids": writableChannelIds,
            "sender_allowlist": senderAllowlist,
            "write_enabled": writeEnabled,
            "inbound_dispatch_enabled": inboundDispatchEnabled,
            "receive_ready": receiveReady,
            "status": status,
            "failures": failures,
        ]
        if let inboundDispatchIssue {
            result["inbound_dispatch_issue"] = inboundDispatchIssue
        }
        if !warnings.isEmpty {
            result["warnings"] = warnings
        }
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

struct DiscordConnectionDiscovery: Equatable, Sendable {
    let bot: DiscordBotIdentity
    let guilds: [DiscordGuild]
    let channelsByGuildId: [String: [DiscordChannel]]
    let membersByGuildId: [String: [DiscordGuildMember]]
    let warnings: [String]
}

struct DiscordReceiveBatchResult: Equatable, Sendable {
    let received: Int
    let stored: Int
    let dispatchAttempted: Int
    let dispatchSuppressed: Int
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
            return "Discord content is too long, even after splitting into multiple messages."
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
    static let nativeConnectionId = "discord"
    static let shared = DiscordConnectionService(
        client: DiscordAPIClient(),
        credentialStore: KeychainDiscordCredentialStorage(),
        messageStore: AgentChannelMessageStore.shared
    )

    private let client: DiscordAPIClientProtocol
    private let credentialStore: any DiscordCredentialStorage
    private let messageStore: AgentChannelMessageStore?
    private let recordMessageSnapshotsInline: Bool
    private let activityCenter: AgentChannelInboundActivityCenter
    private let inboundAgentAvailability: @Sendable (UUID) async -> Bool
    private let runningInstanceCount: @Sendable () -> Int
    private let channelGuildCacheLock = NSLock()
    private var channelGuildCache: (updatedAt: Date, values: [String: String])?

    init(
        client: DiscordAPIClientProtocol,
        credentialStore: any DiscordCredentialStorage = KeychainDiscordCredentialStorage(),
        messageStore: AgentChannelMessageStore? = nil,
        recordMessageSnapshotsInline: Bool = false,
        activityCenter: AgentChannelInboundActivityCenter = .shared,
        inboundAgentAvailability: @escaping @Sendable (UUID) async -> Bool = { agentId in
            await MainActor.run {
                AgentManager.shared.agent(for: agentId).map { !$0.isBuiltIn } ?? false
            }
        },
        runningInstanceCount: @escaping @Sendable () -> Int = {
            OsaurusRunningInstanceInspector.runningInstanceCount()
        }
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.messageStore = messageStore
        self.recordMessageSnapshotsInline = recordMessageSnapshotsInline
        self.activityCenter = activityCenter
        self.inboundAgentAvailability = inboundAgentAvailability
        self.runningInstanceCount = runningInstanceCount
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
        AgentChannelCredentialAvailability.shared.invalidate(.discord)
        return saved
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        defer { AgentChannelCredentialAvailability.shared.invalidate(.discord) }
        return credentialStore.deleteBotToken()
    }

    func hasBotToken() -> Bool {
        credentialStore.hasBotToken()
    }

    // MARK: - Off-main credential access
    //
    // SecItem calls can block for seconds under securityd contention, so UI
    // flows await these instead of the synchronous accessors above.

    func saveBotTokenOffMain(_ token: String) async throws {
        let store = credentialStore
        let saved = await Keychain.perform { store.saveBotToken(token) }
        AgentChannelCredentialAvailability.shared.invalidate(.discord)
        if !saved {
            throw DiscordConnectionServiceError.configurationSaveFailed(
                "The token was empty or Keychain storage was unavailable."
            )
        }
    }

    @discardableResult
    func deleteBotTokenOffMain() async -> Bool {
        let store = credentialStore
        defer { AgentChannelCredentialAvailability.shared.invalidate(.discord) }
        return await Keychain.perform { store.deleteBotToken() }
    }

    func hasBotTokenOffMain() async -> Bool {
        let store = credentialStore
        return await Keychain.perform { store.hasBotToken() }
    }

    func discoverConfigurationOptions() async throws -> DiscordConnectionDiscovery {
        let token = try requireToken()
        do {
            async let botRequest = client.currentUser(token: token)
            async let guildRequest = client.guilds(token: token)
            let (bot, guilds) = try await (botRequest, guildRequest)
            var channelsByGuildId: [String: [DiscordChannel]] = [:]
            var membersByGuildId: [String: [DiscordGuildMember]] = [:]
            var warnings: [String] = []
            for guild in guilds {
                do {
                    channelsByGuildId[guild.id] = try await client.channels(guildId: guild.id, token: token)
                        .filter { Self.isSelectableChannelType($0.type) }
                } catch {
                    warnings.append("\(guild.name): \(redacted(error, token: token))")
                }
                do {
                    membersByGuildId[guild.id] = try await client.members(guildId: guild.id, token: token)
                        .filter { !$0.user.bot }
                        .sorted {
                            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                        }
                } catch {
                    warnings.append(
                        "\(guild.name): members could not be loaded. Enable the Server Members Intent or enter sender IDs manually."
                    )
                }
            }
            return DiscordConnectionDiscovery(
                bot: bot,
                guilds: guilds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                channelsByGuildId: channelsByGuildId,
                membersByGuildId: membersByGuildId,
                warnings: warnings
            )
        } catch {
            throw DiscordConnectionServiceError.api(redacted(error, token: token))
        }
    }

    func pollInboundMessages() async throws -> DiscordReceiveBatchResult {
        guard let messageStore else { return DiscordReceiveBatchResult(received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0) }
        let token = try requireToken()
        let config = configuration()
        guard !config.readableChannelIds.isEmpty, !config.senderAllowlist.isEmpty else {
            return DiscordReceiveBatchResult(received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0)
        }
        try messageStore.openIfNeeded()
        let bot = try await client.currentUser(token: token)
        let channelGuildIds = await channelGuildMap(token: token, config: config)
        var received = 0
        var stored = 0
        var dispatchAttempted = 0
        var dispatchSuppressed = 0

        for channelId in config.readableChannelIds {
            let cursor = try messageStore.cursor(connectionId: Self.nativeConnectionId, roomId: channelId)
            let messages = try await client.messages(
                channelId: channelId,
                token: token,
                limit: cursor == nil ? 1 : 100,
                after: cursor
            )
            let ordered = messages.sorted { Self.snowflakeLessThan($0.id, $1.id) }
            if cursor == nil {
                if let newest = ordered.last {
                    try messageStore.upsertCursor(
                        connectionId: Self.nativeConnectionId,
                        roomId: channelId,
                        cursor: newest.id
                    )
                }
                continue
            }
            for message in ordered {
                received += 1
                let providerEventId = "discord:\(message.id)"
                await activityCenter.record(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: providerEventId,
                    stage: .received
                )
                let authorizationService = AgentChannelConnectionService(
                    discordService: self,
                    slackService: .shared,
                    telegramService: .shared
                )
                let authorization = try authorizationService.authorizeInboundMessage(
                    AgentChannelInboundMessageAuthorizationRequest(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: providerEventId,
                        providerMessageId: message.id,
                        spaceId: channelGuildIds[channelId],
                        roomId: channelId,
                        senderId: message.author.id,
                        isBotMessage: message.author.bot,
                        isSelfMessage: message.author.id == bot.id
                    ),
                    messageStore: messageStore
                )
                let storedMessage = Self.storedMessage(
                    message,
                    channelId: channelId,
                    direction: .inbound
                )
                let result = try messageStore.recordReceiveEvent(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: providerEventId,
                    authorization: authorization,
                    message: storedMessage,
                    cursor: message.id
                )
                try messageStore.upsertCursor(
                    connectionId: Self.nativeConnectionId,
                    roomId: channelId,
                    cursor: message.id
                )
                if result.messageInserted { stored += 1 }
                if result.disposition != .accepted {
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: providerEventId,
                        stage: .rejected,
                        reason: result.authorizationReason
                    )
                } else {
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: providerEventId,
                        stage: .stored
                    )
                }
                guard result.shouldDispatch else {
                    dispatchSuppressed += 1
                    continue
                }
                let relay = await relayInboundMessage(message, botId: bot.id, config: config)
                dispatchAttempted += relay.dispatchAttempted
                dispatchSuppressed += relay.dispatchSuppressed
                switch relay {
                case .dispatched(let agentId, let rule):
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: providerEventId,
                        stage: .dispatched,
                        reason: await AgentChannelInboundActivityPresentation.dispatchReason(
                            agentId: agentId,
                            rule: rule
                        )
                    )
                case .suppressed(let reason):
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: providerEventId,
                        stage: .dispatchSuppressed,
                        reason: reason
                    )
                }
            }
        }
        return DiscordReceiveBatchResult(
            received: received,
            stored: stored,
            dispatchAttempted: dispatchAttempted,
            dispatchSuppressed: dispatchSuppressed
        )
    }

    private func relayInboundMessage(
        _ message: DiscordMessage,
        botId: String,
        config: DiscordConnectionConfiguration
    ) async -> AgentChannelInboundRelaySubmission {
        let settings = config.inboundDispatch
        guard settings.isConfigured else {
            return .suppressed("inbound_dispatch_not_configured")
        }
        let mentionsBot = message.content.contains("<@\(botId)>")
            || message.content.contains("<@!\(botId)>")
        if settings.requireMention, !mentionsBot {
            let continuing = settings.continueThreads && hasOutboundMessage(in: message.channelId)
            guard continuing else { return .suppressed("mention_required") }
        }
        let content = message.content
            .replacingOccurrences(of: "<@\(botId)>", with: "")
            .replacingOccurrences(of: "<@!\(botId)>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var responder: AgentChannelInboundReplyHandler?
        if settings.autoReplyEnabled {
            responder = { [weak self] response in
                guard let self else { return }
                _ = try await self.sendMessage(
                    channelId: message.channelId,
                    content: response,
                    confirmSend: true
                )
            }
        }
        return await AgentChannelInboundRelay.shared.submit(
            AgentChannelInboundRelayRequest(
                identity: ChannelIdentity(
                    kind: .discord,
                    installationId: config.configuredGuildIds.first ?? Self.nativeConnectionId,
                    groupId: message.channelId,
                    sender: ChannelSenderMetadata(senderId: message.author.id)
                ),
                connectionId: Self.nativeConnectionId,
                providerEventId: "discord:\(message.id)",
                providerRoute: AgentChannelProviderRoute(
                    conversationId: message.channelId,
                    displayName: "Discord \(message.channelId)"
                ),
                content: content,
                attachments: Self.storedMessage(
                    message,
                    channelId: message.channelId,
                    direction: .inbound
                ).attachments,
                settings: settings,
                sourceLabel: "Discord channel \(message.channelId), sender \(message.author.id)",
                reply: responder
            )
        )
    }

    private func channelGuildMap(
        token: String,
        config: DiscordConnectionConfiguration
    ) async -> [String: String] {
        if let cached = channelGuildCacheLock.withLock({ channelGuildCache }),
           Date().timeIntervalSince(cached.updatedAt) < 300 {
            return cached.values
        }
        var values: [String: String] = [:]
        for guildId in config.configuredGuildIds {
            guard let channels = try? await client.channels(guildId: guildId, token: token) else { continue }
            for channel in channels {
                values[channel.id] = guildId
            }
        }
        channelGuildCacheLock.withLock {
            channelGuildCache = (Date(), values)
        }
        return values
    }

    private func hasOutboundMessage(in channelId: String) -> Bool {
        guard let messageStore else { return false }
        do {
            try messageStore.openIfNeeded()
            return try messageStore.recentMessages(
                connectionId: Self.nativeConnectionId,
                roomId: channelId,
                limit: 200
            ).contains { $0.direction == .outbound }
        } catch {
            return false
        }
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
                senderAllowlist: config.senderAllowlist,
                writeEnabled: config.writeEnabled,
                inboundDispatchEnabled: config.inboundDispatch.enabled,
                status: "not_configured",
                failures: ["No Discord bot token is saved."]
            )
        }

        var failures: [String] = []
        var warnings: [String] = []
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

        var inboundDispatchIssue: String?
        if config.inboundDispatch.enabled {
            let referencedAgents = config.inboundDispatch.referencedAgentIds
            if referencedAgents.isEmpty {
                inboundDispatchIssue = "inbound_agent_not_selected"
                failures.append(
                    "Inbound dispatch is enabled but no agent is selected for incoming Discord messages."
                )
            } else {
                for agentId in referencedAgents where await !inboundAgentAvailability(agentId) {
                    inboundDispatchIssue = "inbound_agent_unavailable"
                    failures.append(
                        "Inbound dispatch is enabled but a routed agent no longer exists. Update the routing rules in Discord settings."
                    )
                    break
                }
            }
            if config.senderAllowlist.isEmpty {
                failures.append(
                    "Inbound dispatch is enabled but no authorized Discord senders are allowlisted, so nothing will be received."
                )
            }
        }

        if let duplicateWarning = OsaurusRunningInstanceInspector.duplicateInstanceWarning(
            instanceCount: runningInstanceCount()
        ) {
            warnings.append(duplicateWarning)
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
            senderAllowlist: config.senderAllowlist,
            writeEnabled: config.writeEnabled,
            inboundDispatchEnabled: config.inboundDispatch.enabled,
            inboundDispatchIssue: inboundDispatchIssue,
            status: status,
            failures: failures,
            warnings: warnings
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
        let chunks = AgentChannelMessageFormatter.discordChunks(trimmedContent)
        guard !chunks.isEmpty else { throw DiscordConnectionServiceError.emptyMessage }
        guard chunks.count <= AgentChannelMessageFormatter.maxChunksPerSend else {
            throw DiscordConnectionServiceError.messageTooLong
        }
        var messages: [DiscordMessage] = []
        for chunk in chunks {
            messages.append(
                try await client.sendMessage(
                    channelId: normalizedChannelId,
                    content: chunk,
                    token: token
                )
            )
        }
        recordMessages(messages, channelId: normalizedChannelId, direction: .outbound)
        var result: [String: Any] = [
            "kind": "discord_message_sent",
            "channel_id": normalizedChannelId,
            "message": Self.messageDictionary(messages[0]),
        ]
        if messages.count > 1 {
            result["chunk_count"] = messages.count
        }
        return result
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

    func editMessage(
        channelId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw DiscordConnectionServiceError.sendConfirmationRequired }
        let token = try requireToken()
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let messageId = try requireSnowflake(messageId, field: "message_id")
        let content = try validateMessageContent(content)
        // Edits must stay a single native message: reject content whose
        // rendered form would need chunking.
        let chunks = AgentChannelMessageFormatter.discordChunks(content)
        guard chunks.count == 1, let rendered = chunks.first else {
            throw DiscordConnectionServiceError.messageTooLong
        }
        let message = try await client.updateMessage(
            channelId: channelId,
            messageId: messageId,
            content: rendered,
            token: token
        )
        recordMessages([message], channelId: channelId, direction: .outbound)
        return [
            "kind": "discord_message_edited",
            "channel_id": channelId,
            "message_id": messageId,
            "message": Self.messageDictionary(message),
        ]
    }

    func deleteMessage(
        channelId: String,
        messageId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw DiscordConnectionServiceError.sendConfirmationRequired }
        let token = try requireToken()
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let messageId = try requireSnowflake(messageId, field: "message_id")
        try await client.deleteMessage(channelId: channelId, messageId: messageId, token: token)
        return [
            "kind": "discord_message_deleted",
            "channel_id": channelId,
            "message_id": messageId,
            "delivery_status": "deleted",
        ]
    }

    func setReaction(
        channelId: String,
        messageId: String,
        reaction: String,
        adding: Bool,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw DiscordConnectionServiceError.sendConfirmationRequired }
        let token = try requireToken()
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let messageId = try requireSnowflake(messageId, field: "message_id")
        guard let reaction = AgentChannelReactionNormalizer.discordReaction(reaction) else {
            throw DiscordConnectionServiceError.invalidId(field: "reaction")
        }
        if adding {
            try await client.addReaction(
                channelId: channelId,
                messageId: messageId,
                reaction: reaction,
                token: token
            )
        } else {
            try await client.removeReaction(
                channelId: channelId,
                messageId: messageId,
                reaction: reaction,
                token: token
            )
        }
        return [
            "kind": adding ? "discord_reaction_added" : "discord_reaction_removed",
            "channel_id": channelId,
            "message_id": messageId,
            "reaction": reaction,
            "delivery_status": adding ? "added" : "removed",
        ]
    }

    func sendTyping(channelId: String, confirmSend: Bool) async throws -> [String: Any] {
        guard confirmSend else { throw DiscordConnectionServiceError.sendConfirmationRequired }
        let token = try requireToken()
        let channelId = try requireWritableChannel(channelId, config: configuration())
        try await client.sendTyping(channelId: channelId, token: token)
        return [
            "kind": "discord_typing_sent",
            "channel_id": channelId,
            "delivery_status": "sent",
        ]
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
        // Long sends are split into up to `maxChunksPerSend` native messages
        // of 2,000 UTF-16 units each; cap the raw input accordingly.
        let maxInput = AgentChannelMessageFormatter.discordChunkLimit
            * AgentChannelMessageFormatter.maxChunksPerSend
        guard trimmed.utf16.count <= maxInput else {
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
            attachments: message.attachments.map { attachment in
                AgentChannelStoredAttachment(
                    providerId: attachment.id,
                    kind: Self.attachmentKind(contentType: attachment.contentType),
                    filename: attachment.filename,
                    contentType: attachment.contentType,
                    sizeBytes: attachment.size,
                    remoteURL: attachment.url
                )
            },
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

    private static func attachmentKind(contentType: String?) -> AgentChannelStoredAttachmentKind {
        let contentType = contentType?.lowercased() ?? ""
        if contentType.hasPrefix("image/") { return .image }
        if contentType.hasPrefix("audio/") { return .audio }
        if contentType.hasPrefix("video/") { return .video }
        return .file
    }

    private static func isSelectableChannelType(_ type: Int) -> Bool {
        // Guild text, announcement, announcement thread, public/private thread, forum, and media.
        [0, 5, 10, 11, 12, 15, 16].contains(type)
    }

    private static func snowflakeLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
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
