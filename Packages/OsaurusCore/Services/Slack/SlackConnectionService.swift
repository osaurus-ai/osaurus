//
//  SlackConnectionService.swift
//  osaurus
//
//  Policy and diagnostics layer for the native Slack Agent Channel adapter.
//

import Foundation

struct SlackConfiguredTeamDiagnostic: Equatable, Sendable {
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

struct SlackConnectionDiagnostics: Equatable, Sendable {
    let botTokenSaved: Bool
    let signingSecretSaved: Bool
    let appTokenSaved: Bool
    let identity: SlackAuthIdentity?
    let configuredTeams: [SlackConfiguredTeamDiagnostic]
    let readableChannelIds: [String]
    let writableChannelIds: [String]
    let senderAllowlist: [String]
    let writeEnabled: Bool
    let allowBroadcastMentions: Bool
    let status: String
    let failures: [String]

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "bot_token_saved": botTokenSaved,
            "signing_secret_saved": signingSecretSaved,
            "app_token_saved": appTokenSaved,
            "configured_teams": configuredTeams.map(\.dictionary),
            "readable_channel_ids": readableChannelIds,
            "writable_channel_ids": writableChannelIds,
            "sender_allowlist": senderAllowlist,
            "write_enabled": writeEnabled,
            "allow_broadcast_mentions": allowBroadcastMentions,
            "status": status,
            "failures": failures,
        ]
        if let identity {
            result["bot"] = [
                "bot_id": identity.botId ?? "",
                "team": identity.team ?? "",
                "team_id": identity.teamId,
                "user": identity.user ?? "",
                "user_id": identity.userId ?? "",
            ]
        }
        return result
    }
}

struct SlackEventEnvelope: Codable, Equatable, Sendable {
    let token: String?
    let teamId: String?
    let apiAppId: String?
    let event: SlackEventMessage?
    let type: String?
    let eventId: String?
    let eventTime: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case teamId = "team_id"
        case apiAppId = "api_app_id"
        case event
        case type
        case eventId = "event_id"
        case eventTime = "event_time"
    }
}

struct SlackEventMessage: Codable, Equatable, Sendable {
    let type: String?
    let subtype: String?
    let channel: String?
    let user: String?
    let botId: String?
    let text: String?
    let ts: String?
    let threadTs: String?
    let channelType: String?

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case channel
        case user
        case botId = "bot_id"
        case text
        case ts
        case threadTs = "thread_ts"
        case channelType = "channel_type"
    }
}

struct SlackNormalizedInboundMessage: Equatable, Sendable {
    let connectionId: String
    let providerEventId: String
    let teamId: String?
    let roomId: String
    let providerMessageId: String
    let threadId: String
    let threadTs: String
    let authorId: String?
    let content: String
    let isThreadReply: Bool
    let isMention: Bool
    let mentionedUserIds: [String]
    let payloadJSON: String

    var storedMessage: AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: roomId,
            providerMessageId: providerMessageId,
            direction: .inbound,
            threadId: threadId,
            authorId: authorId,
            authorName: nil,
            content: content,
            payloadJSON: payloadJSON,
            providerTimestamp: providerMessageId
        )
    }
}

enum SlackConnectionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidId(field: String)
    case teamNotConfigured(String)
    case channelNotReadable(String)
    case channelNotWritable(String)
    case writeDisabled
    case sendConfirmationRequired
    case messageTooLong
    case emptyMessage
    case broadcastMentionDenied
    case invalidThreadId(String)
    case configurationSaveFailed(String)
    case signingSecretNotConfigured
    case signatureVerificationFailed
    case invalidInboundPayload
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Slack is not configured. Add a bot token and allowlist at least one channel."
        case .invalidId(let field):
            return "`\(field)` must be a Slack ID."
        case .teamNotConfigured(let teamId):
            return "Slack workspace `\(teamId)` is not allowlisted in settings."
        case .channelNotReadable(let channelId):
            return "Slack channel `\(channelId)` is not allowlisted for read access."
        case .channelNotWritable(let channelId):
            return "Slack channel `\(channelId)` is not allowlisted for write access."
        case .writeDisabled:
            return "Slack write access is disabled in settings."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus posts to Slack."
        case .messageTooLong:
            return "Slack messages must be 40000 characters or fewer."
        case .emptyMessage:
            return "Slack message content must not be empty."
        case .broadcastMentionDenied:
            return "Slack broadcast mentions are disabled for this connection."
        case .invalidThreadId(let threadId):
            return "Slack thread id `\(threadId)` must use `channel_id:thread_ts`."
        case .configurationSaveFailed(let message):
            return "Slack configuration could not be saved: \(message)"
        case .signingSecretNotConfigured:
            return "Slack signing secret is not configured."
        case .signatureVerificationFailed:
            return "Slack request signature could not be verified."
        case .invalidInboundPayload:
            return "Slack inbound event payload could not be decoded."
        case .api(let message):
            return message
        }
    }
}

final class SlackConnectionService: @unchecked Sendable {
    static let shared = SlackConnectionService(
        client: SlackAPIClient(),
        credentialStore: KeychainSlackCredentialStorage(),
        messageStore: AgentChannelMessageStore.shared
    )

    /// Page caps for cursor-following so one tool call cannot fan out into an
    /// unbounded number of Slack API requests.
    static let maxConversationListPages = 5
    static let maxMessagePages = 5

    private let client: SlackAPIClientProtocol
    private let credentialStore: any SlackCredentialStorage
    private let messageStore: AgentChannelMessageStore?
    private let recordMessageSnapshotsInline: Bool

    init(
        client: SlackAPIClientProtocol,
        credentialStore: any SlackCredentialStorage = KeychainSlackCredentialStorage(),
        messageStore: AgentChannelMessageStore? = nil,
        recordMessageSnapshotsInline: Bool = false
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.messageStore = messageStore
        self.recordMessageSnapshotsInline = recordMessageSnapshotsInline
    }

    func configuration() -> SlackConnectionConfiguration {
        SlackConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: SlackConnectionConfiguration) throws {
        do {
            var merged = configuration.normalized
            let current = SlackConnectionConfigurationStore.load()
            if merged.botUserId == nil {
                merged.botUserId = current.botUserId
            }
            if merged.botId == nil {
                merged.botId = current.botId
            }
            if merged.apiAppId == nil {
                merged.apiAppId = current.apiAppId
            }
            try SlackConnectionConfigurationStore.save(merged)
        } catch {
            throw SlackConnectionServiceError.configurationSaveFailed(error.localizedDescription)
        }
    }

    private func persistIdentity(_ identity: SlackAuthIdentity) {
        var config = configuration()
        guard config.botUserId != identity.userId || config.botId != identity.botId else {
            return
        }
        config.botUserId = identity.userId
        config.botId = identity.botId
        do {
            try SlackConnectionConfigurationStore.save(config)
        } catch {
            NSLog("[Slack] Failed to persist bot identity: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveBotToken(_ token: String) throws -> Bool {
        let saved = credentialStore.saveBotToken(token)
        if !saved {
            throw SlackConnectionServiceError.configurationSaveFailed(
                "The bot token was empty or Keychain storage was unavailable."
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

    @discardableResult
    func saveSigningSecret(_ secret: String) throws -> Bool {
        let saved = credentialStore.saveSigningSecret(secret)
        if !saved {
            throw SlackConnectionServiceError.configurationSaveFailed(
                "The signing secret was empty or Keychain storage was unavailable."
            )
        }
        return saved
    }

    @discardableResult
    func deleteSigningSecret() -> Bool {
        credentialStore.deleteSigningSecret()
    }

    func hasSigningSecret() -> Bool {
        credentialStore.hasSigningSecret()
    }

    @discardableResult
    func saveAppToken(_ token: String) throws -> Bool {
        let saved = credentialStore.saveAppToken(token)
        if !saved {
            throw SlackConnectionServiceError.configurationSaveFailed(
                "The app-level token was empty or Keychain storage was unavailable."
            )
        }
        return saved
    }

    @discardableResult
    func deleteAppToken() -> Bool {
        credentialStore.deleteAppToken()
    }

    func hasAppToken() -> Bool {
        credentialStore.hasAppToken()
    }

    func socketModeAppToken() -> String? {
        credentialStore.appToken()
    }

    @discardableResult
    func ensureBotIdentity() async throws -> SlackAuthIdentity? {
        let config = configuration()
        guard config.botUserId == nil && config.botId == nil else { return nil }
        let token = try requireToken()
        do {
            let identity = try await client.authTest(token: token)
            persistIdentity(identity)
            return identity
        } catch {
            throw SlackConnectionServiceError.api(redacted(
                error,
                token: token,
                signingSecret: credentialStore.signingSecret(),
                appToken: credentialStore.appToken()
            ))
        }
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

    func diagnostics() async -> SlackConnectionDiagnostics {
        let config = configuration()
        guard let token = credentialStore.botToken() else {
            return SlackConnectionDiagnostics(
                botTokenSaved: false,
                signingSecretSaved: credentialStore.hasSigningSecret(),
                appTokenSaved: credentialStore.hasAppToken(),
                identity: nil,
                configuredTeams: [],
                readableChannelIds: config.readableChannelIds,
                writableChannelIds: config.writableChannelIds,
                senderAllowlist: config.senderAllowlist,
                writeEnabled: config.writeEnabled,
                allowBroadcastMentions: config.allowBroadcastMentions,
                status: "not_configured",
                failures: ["No Slack bot token is saved."]
            )
        }
        let signingSecret = credentialStore.signingSecret()
        let appToken = credentialStore.appToken()

        let identity: SlackAuthIdentity?
        var failures: [String] = []
        do {
            identity = try await client.authTest(token: token)
            if let identity {
                persistIdentity(identity)
            }
        } catch {
            identity = nil
            failures.append(redacted(error, token: token, signingSecret: signingSecret, appToken: appToken))
        }

        var teamRows: [SlackConfiguredTeamDiagnostic] = []
        if let identity {
            let allowed = config.canUseTeam(teamId: identity.teamId)
            teamRows.append(SlackConfiguredTeamDiagnostic(
                id: identity.teamId,
                name: identity.team ?? "",
                status: allowed ? "accessible" : "not_allowlisted",
                reason: allowed ? nil : "Workspace is not in configuredTeamIds."
            ))
        }
        for teamId in config.configuredTeamIds where teamRows.allSatisfy({ $0.id != teamId }) {
            teamRows.append(SlackConfiguredTeamDiagnostic(
                id: teamId,
                name: "",
                status: "configured_not_current_token_team",
                reason: "The saved bot token did not authenticate as this workspace."
            ))
        }

        let receiveCredentialSaved = signingSecret != nil || appToken != nil
        let receiveNeedsSenderAllowlist = receiveCredentialSaved
            && !config.readableChannelIds.isEmpty
            && config.senderAllowlist.isEmpty

        let status: String
        if identity == nil {
            status = "token_invalid_or_unavailable"
        } else if let identity, !config.canUseTeam(teamId: identity.teamId) {
            status = "connected_team_not_allowlisted"
        } else if config.readableChannelIds.isEmpty && config.writableChannelIds.isEmpty {
            status = "connected_needs_allowlist"
        } else if receiveNeedsSenderAllowlist {
            status = "connected_receive_needs_sender_allowlist"
        } else if config.writeEnabled && config.writableChannelIds.isEmpty {
            status = "connected_read_only_write_needs_channels"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        if receiveNeedsSenderAllowlist {
            failures.append(
                "Slack receive is configured with readable channels but no authorized sender IDs; inbound events will be denied before storage or dispatch."
            )
        }

        return SlackConnectionDiagnostics(
            botTokenSaved: true,
            signingSecretSaved: signingSecret != nil,
            appTokenSaved: appToken != nil,
            identity: identity,
            configuredTeams: teamRows,
            readableChannelIds: config.readableChannelIds,
            writableChannelIds: config.writableChannelIds,
            senderAllowlist: config.senderAllowlist,
            writeEnabled: config.writeEnabled,
            allowBroadcastMentions: config.allowBroadcastMentions,
            status: status,
            failures: failures
        )
    }

    func listWorkspaces() async throws -> [[String: Any]] {
        let token = try requireToken()
        let config = configuration()
        let identity = try await client.authTest(token: token)
        persistIdentity(identity)
        guard config.canUseTeam(teamId: identity.teamId) else {
            throw SlackConnectionServiceError.teamNotConfigured(identity.teamId)
        }
        return [[
            "id": identity.teamId,
            "name": identity.team ?? identity.teamId,
            "configured": config.configuredTeamIds.isEmpty || config.configuredTeamIds.contains(identity.teamId),
        ]]
    }

    func listChannels(teamId: String) async throws -> [[String: Any]] {
        let token = try requireToken()
        let config = configuration()
        let normalizedTeamId = try requireSlackId(teamId, field: "team_id")
        guard config.canUseTeam(teamId: normalizedTeamId) else {
            throw SlackConnectionServiceError.teamNotConfigured(normalizedTeamId)
        }
        let identity = try await client.authTest(token: token)
        persistIdentity(identity)
        guard identity.teamId == normalizedTeamId else {
            throw SlackConnectionServiceError.teamNotConfigured(normalizedTeamId)
        }

        var channels: [SlackConversation] = []
        var cursor: String?
        var truncated = false
        for page in 0 ..< Self.maxConversationListPages {
            let result = try await client.conversations(token: token, limit: 100, cursor: cursor)
            channels.append(contentsOf: result.conversations)
            guard let nextCursor = result.nextCursor else {
                truncated = false
                break
            }
            cursor = nextCursor
            truncated = page == Self.maxConversationListPages - 1
        }
        var rows: [[String: Any]] = channels.map { channel in
            [
                "id": channel.id,
                "name": channel.displayName,
                "type": channel.kind,
                "team_id": normalizedTeamId,
                "is_private": channel.isPrivate,
                "is_member": channel.isMember,
                "read_allowed": config.canRead(channelId: channel.id),
                "write_allowed": config.canWrite(channelId: channel.id),
            ]
        }
        if truncated {
            rows.append([
                "id": "pagination_notice",
                "name":
                    "Slack returned more conversations than the \(Self.maxConversationListPages * 100)-row cap; the list is truncated.",
                "type": "notice",
                "team_id": normalizedTeamId,
                "is_private": false,
                "is_member": false,
                "read_allowed": false,
                "write_allowed": false,
            ])
        }
        return rows
    }

    func readChannel(channelId: String, limit: Int?) async throws -> [String: Any] {
        let token = try requireToken()
        let config = configuration()
        let normalizedChannelId = try requireReadableChannel(channelId, config: config)
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        let page = try await collectMessagePages(limit: safeLimit) { pageLimit, cursor in
            try await client.messages(
                channelId: normalizedChannelId,
                token: token,
                limit: pageLimit,
                cursor: cursor
            )
        }
        recordMessages(page.messages, channelId: normalizedChannelId, direction: .inbound)
        var payload: [String: Any] = [
            "kind": "slack_recent_messages",
            "channel_id": normalizedChannelId,
            "limit": safeLimit,
            "partial": page.hasMore,
            "messages": page.messages.map { Self.messageDictionary($0, channelId: normalizedChannelId) },
        ]
        if let nextCursor = page.nextCursor {
            payload["next_cursor"] = nextCursor
        }
        return payload
    }

    func readThread(threadId: String, limit: Int?) async throws -> [String: Any] {
        let token = try requireToken()
        let config = configuration()
        let parsed = try parseThreadId(threadId)
        let normalizedChannelId = try requireReadableChannel(parsed.channelId, config: config)
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        let page = try await collectMessagePages(limit: safeLimit) { pageLimit, cursor in
            try await client.threadMessages(
                channelId: normalizedChannelId,
                threadTs: parsed.threadTs,
                token: token,
                limit: pageLimit,
                cursor: cursor
            )
        }
        recordMessages(page.messages, channelId: normalizedChannelId, direction: .inbound)
        var payload: [String: Any] = [
            "kind": "slack_thread_messages",
            "channel_id": normalizedChannelId,
            "thread_id": "\(normalizedChannelId):\(parsed.threadTs)",
            "thread_ts": parsed.threadTs,
            "limit": safeLimit,
            "partial": page.hasMore,
            "messages": page.messages.map { Self.messageDictionary($0, channelId: normalizedChannelId) },
        ]
        if let nextCursor = page.nextCursor {
            payload["next_cursor"] = nextCursor
        }
        return payload
    }

    /// Follows Slack cursors until `limit` messages are collected, the pages run
    /// out, or the page cap is hit. Slack can return fewer rows than requested
    /// per page even when more exist, so a single call is not enough.
    private func collectMessagePages(
        limit: Int,
        fetch: (Int, String?) async throws -> SlackMessagePage
    ) async rethrows -> SlackMessagePage {
        var collected: [SlackMessage] = []
        var requestCursor: String?
        var continuationCursor: String?
        var hasMore = false
        for _ in 0 ..< Self.maxMessagePages {
            let remaining = limit - collected.count
            guard remaining > 0 else { break }
            let page = try await fetch(remaining, requestCursor)
            collected.append(contentsOf: page.messages)
            hasMore = page.hasMore
            continuationCursor = page.nextCursor
            guard let nextCursor = page.nextCursor, collected.count < limit else { break }
            requestCursor = nextCursor
        }
        let overflow = collected.count > limit
        if overflow {
            collected = Array(collected.prefix(limit))
        }
        return SlackMessagePage(
            messages: collected,
            hasMore: hasMore || overflow,
            nextCursor: continuationCursor
        )
    }

    func findRecentMessages(
        query: String,
        channelIds: [String]?,
        limitPerChannel: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SlackConnectionServiceError.emptyMessage
        }

        let config = configuration()
        let candidateChannels = SlackConnectionConfiguration.normalizedIds(
            channelIds ?? config.readableChannelIds
        )
        let allowedChannels = candidateChannels.filter { config.canRead(channelId: $0) }
        guard !allowedChannels.isEmpty else {
            throw SlackConnectionServiceError.channelNotReadable(candidateChannels.first ?? "")
        }

        let token = try requireToken()
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limitPerChannel ?? config.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        let needle = trimmedQuery.lowercased()
        var matches: [[String: Any]] = []

        for channelId in allowedChannels {
            let page = try await client.messages(
                channelId: channelId,
                token: token,
                limit: safeLimit,
                cursor: nil
            )
            let messages = page.messages
            recordMessages(messages, channelId: channelId, direction: .inbound)
            for message in messages {
                let haystack = "\(message.text ?? "") \(message.user ?? "") \(message.username ?? "")"
                    .lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append(Self.messageDictionary(message, channelId: channelId))
                if matches.count >= safeMaxMatches { break }
            }
            if matches.count >= safeMaxMatches { break }
        }

        return [
            "kind": "slack_recent_message_search",
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
        let trimmedContent = try validateMessageContent(content, config: config)
        return [
            "kind": "slack_message_draft",
            "channel_id": normalizedChannelId,
            "content": trimmedContent,
            "requires_send_confirmation": true,
            "mention_policy": mentionPolicyDictionary(config: config),
        ]
    }

    func sendMessage(
        channelId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else {
            throw SlackConnectionServiceError.sendConfirmationRequired
        }
        let token = try requireToken()
        let config = configuration()
        let normalizedChannelId = try requireWritableChannel(channelId, config: config)
        let trimmedContent = try validateMessageContent(content, config: config)
        let request = SlackOutboundMessageRequest(
            channelId: normalizedChannelId,
            content: trimmedContent,
            threadTs: nil
        )
        let message = try await client.sendMessage(request, token: token)
        recordMessages([message], channelId: normalizedChannelId, direction: .outbound)
        return [
            "kind": "slack_message_sent",
            "channel_id": normalizedChannelId,
            "message": Self.messageDictionary(message, channelId: normalizedChannelId),
            "mention_policy": mentionPolicyDictionary(config: config),
        ]
    }

    func replyToThread(
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else {
            throw SlackConnectionServiceError.sendConfirmationRequired
        }
        let token = try requireToken()
        let config = configuration()
        let parsed = try parseThreadId(threadId)
        let normalizedChannelId = try requireWritableChannel(parsed.channelId, config: config)
        let trimmedContent = try validateMessageContent(content, config: config)
        let request = SlackOutboundMessageRequest(
            channelId: normalizedChannelId,
            content: trimmedContent,
            threadTs: parsed.threadTs
        )
        let message = try await client.sendMessage(request, token: token)
        recordMessages([message], channelId: normalizedChannelId, direction: .outbound)
        return [
            "kind": "slack_thread_reply_sent",
            "channel_id": normalizedChannelId,
            "thread_id": "\(normalizedChannelId):\(parsed.threadTs)",
            "thread_ts": parsed.threadTs,
            "message": Self.messageDictionary(message, channelId: normalizedChannelId),
            "mention_policy": mentionPolicyDictionary(config: config),
        ]
    }

    private func requireToken() throws -> String {
        guard let token = credentialStore.botToken() else {
            throw SlackConnectionServiceError.notConfigured
        }
        return token
    }

    private func requireSlackId(_ id: String, field: String) throws -> String {
        let normalized = SlackConnectionConfiguration.normalizedId(id)
        guard SlackConnectionConfiguration.isValidSlackId(normalized) else {
            throw SlackConnectionServiceError.invalidId(field: field)
        }
        return normalized
    }

    private func requireReadableChannel(
        _ channelId: String,
        config: SlackConnectionConfiguration
    ) throws -> String {
        let normalized = try requireSlackId(channelId, field: "channel_id")
        guard config.canRead(channelId: normalized) else {
            throw SlackConnectionServiceError.channelNotReadable(normalized)
        }
        return normalized
    }

    private func requireWritableChannel(
        _ channelId: String,
        config: SlackConnectionConfiguration
    ) throws -> String {
        let normalized = try requireSlackId(channelId, field: "channel_id")
        guard config.writeEnabled else {
            throw SlackConnectionServiceError.writeDisabled
        }
        guard config.canWrite(channelId: normalized) else {
            throw SlackConnectionServiceError.channelNotWritable(normalized)
        }
        return normalized
    }

    private func validateMessageContent(
        _ content: String,
        config: SlackConnectionConfiguration
    ) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SlackConnectionServiceError.emptyMessage
        }
        guard trimmed.count <= 40_000 else {
            throw SlackConnectionServiceError.messageTooLong
        }
        if !config.allowBroadcastMentions && Self.containsBroadcastMention(trimmed) {
            throw SlackConnectionServiceError.broadcastMentionDenied
        }
        return trimmed
    }

    private func parseThreadId(_ threadId: String) throws -> (channelId: String, threadTs: String) {
        let normalized = SlackConnectionConfiguration.normalizedId(threadId)
        let parts = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              SlackConnectionConfiguration.isValidSlackId(String(parts[0])),
              Self.isValidThreadTimestamp(String(parts[1]))
        else {
            throw SlackConnectionServiceError.invalidThreadId(normalized)
        }
        return (String(parts[0]), String(parts[1]))
    }

    private func redacted(
        _ error: Error,
        token: String,
        signingSecret: String?,
        appToken: String?
    ) -> String {
        SlackSecurity.redact(
            error.localizedDescription,
            token: token,
            signingSecret: signingSecret,
            appToken: appToken
        )
    }

    /// Redacts saved credentials from arbitrary text before it reaches
    /// user-visible or model-visible surfaces (for example transport health).
    func redactSecrets(in text: String) -> String {
        SlackSecurity.redact(
            text,
            token: credentialStore.botToken(),
            signingSecret: credentialStore.signingSecret(),
            appToken: credentialStore.appToken()
        )
    }

    func normalizeInboundEvent(_ envelope: SlackEventEnvelope) -> SlackNormalizedInboundMessage? {
        normalizeInboundEvent(envelope, config: configuration())
    }

    func normalizeInboundEvent(
        _ envelope: SlackEventEnvelope,
        config: SlackConnectionConfiguration
    ) -> SlackNormalizedInboundMessage? {
        normalizeInboundEvent(envelope, config: config, enforceSenderAllowlist: true)
    }

    private func normalizeInboundEvent(
        _ envelope: SlackEventEnvelope,
        config: SlackConnectionConfiguration,
        enforceSenderAllowlist: Bool
    ) -> SlackNormalizedInboundMessage? {
        guard let providerEventId = envelope.eventId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerEventId.isEmpty,
              let event = envelope.event,
              ["message", "app_mention"].contains(event.type ?? ""),
              event.subtype == nil,
              let teamId = envelope.teamId.map(SlackConnectionConfiguration.normalizedId),
              SlackConnectionConfiguration.isValidSlackId(teamId),
              let channelId = event.channel.map(SlackConnectionConfiguration.normalizedId),
              SlackConnectionConfiguration.isValidSlackId(channelId),
              let messageTs = event.ts?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidThreadTimestamp(messageTs)
        else {
            return nil
        }
        guard config.canUseTeam(teamId: teamId),
              config.canRead(channelId: channelId),
              config.botUserId != nil || config.botId != nil
        else {
            return nil
        }

        guard !Self.isOwnMessage(event: event, config: config) else {
            return nil
        }

        let authorId = event.user ?? event.botId
        if enforceSenderAllowlist && !config.canUseSender(senderId: authorId) {
            return nil
        }

        let content = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadTs = event.threadTs.flatMap { candidate -> String? in
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.isValidThreadTimestamp(normalized) ? normalized : nil
        } ?? messageTs
        let mentionedUserIds = Self.mentionedUserIds(in: content)
        let mentionsBot = config.botUserId.map(mentionedUserIds.contains) ?? false
        return SlackNormalizedInboundMessage(
            connectionId: AgentChannelConnection.nativeSlackConnectionId,
            providerEventId: providerEventId,
            teamId: teamId,
            roomId: channelId,
            providerMessageId: messageTs,
            threadId: "\(channelId):\(threadTs)",
            threadTs: threadTs,
            authorId: authorId,
            content: content,
            isThreadReply: threadTs != messageTs,
            isMention: event.type == "app_mention" || mentionsBot,
            mentionedUserIds: mentionedUserIds,
            payloadJSON: Self.encodedInboundPayload(envelope)
        )
    }

    func recordVerifiedInboundEvent(
        body: Data,
        timestamp: String,
        signature: String,
        now: Date = Date()
    ) throws -> SlackNormalizedInboundMessage? {
        guard let signingSecret = credentialStore.signingSecret() else {
            throw SlackConnectionServiceError.signingSecretNotConfigured
        }
        guard SlackSignatureVerifier.isAuthorized(
            signingSecret: signingSecret,
            timestamp: timestamp,
            body: body,
            signature: signature,
            now: now
        ) else {
            throw SlackConnectionServiceError.signatureVerificationFailed
        }
        guard let envelope = try? JSONDecoder().decode(SlackEventEnvelope.self, from: body) else {
            throw SlackConnectionServiceError.invalidInboundPayload
        }
        return try recordInboundEvent(envelope)
    }

    func recordInboundEvent(_ envelope: SlackEventEnvelope) throws -> SlackNormalizedInboundMessage? {
        let config = configuration()
        guard let normalized = normalizeInboundEvent(
            envelope,
            config: config,
            enforceSenderAllowlist: messageStore == nil
        ) else { return nil }
        guard let messageStore else {
            return normalized
        }
        try messageStore.openIfNeeded()
        let authorizationService = AgentChannelConnectionService(
            discordService: .shared,
            slackService: self,
            telegramService: .shared
        )
        let authorization = try authorizationService.authorizeInboundMessage(
            AgentChannelInboundMessageAuthorizationRequest(
                connectionId: normalized.connectionId,
                providerEventId: normalized.providerEventId,
                providerMessageId: normalized.providerMessageId,
                spaceId: normalized.teamId,
                roomId: normalized.roomId,
                senderId: normalized.authorId,
                isBotMessage: envelope.event?.botId != nil,
                isSelfMessage: false
            ),
            messageStore: messageStore
        )
        _ = try messageStore.recordReceiveEvent(
            connectionId: normalized.connectionId,
            providerEventId: normalized.providerEventId,
            authorization: authorization,
            message: normalized.storedMessage
        )
        guard authorization.decision == .allow,
              try messageStore.markEventSeen(
                  connectionId: normalized.connectionId,
                  providerEventId: Self.inboundDispatchEventId(normalized)
              )
        else {
            return nil
        }
        return normalized
    }

    private static func inboundDispatchEventId(_ message: SlackNormalizedInboundMessage) -> String {
        "slack-dispatch:\(message.roomId):\(message.providerMessageId)"
    }

    private func recordMessages(
        _ messages: [SlackMessage],
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
            NSLog("[Slack] Failed to record Agent Channel messages: \(error.localizedDescription)")
        }
    }

    private static func storedMessage(
        _ message: SlackMessage,
        channelId: String,
        direction: AgentChannelStoredMessageDirection
    ) -> AgentChannelStoredMessage {
        let threadTs = message.threadTs ?? message.ts
        return AgentChannelStoredMessage(
            connectionId: AgentChannelConnection.nativeSlackConnectionId,
            roomId: channelId,
            providerMessageId: message.ts,
            direction: direction,
            threadId: "\(channelId):\(threadTs)",
            authorId: message.user ?? message.botId,
            authorName: message.username,
            content: message.text ?? "",
            payloadJSON: encodedPayload(message),
            providerTimestamp: message.ts
        )
    }

    private static func encodedPayload<Payload: Encodable>(_ payload: Payload) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func encodedInboundPayload(_ envelope: SlackEventEnvelope) -> String {
        encodedPayload(
            SlackEventEnvelope(
                token: nil,
                teamId: envelope.teamId,
                apiAppId: envelope.apiAppId,
                event: envelope.event,
                type: envelope.type,
                eventId: envelope.eventId,
                eventTime: envelope.eventTime
            )
        )
    }

    private func mentionPolicyDictionary(config: SlackConnectionConfiguration) -> [String: Any] {
        [
            "parse": "none",
            "link_names": false,
            "reply_broadcast": false,
            "allow_broadcast_mentions": config.allowBroadcastMentions,
        ]
    }

    private static func containsBroadcastMention(_ content: String) -> Bool {
        let lowered = content.lowercased()
        return lowered.contains("<!channel")
            || lowered.contains("<!here")
            || lowered.contains("<!everyone")
            || lowered.contains("<!subteam^")
    }

    private static func mentionedUserIds(in content: String) -> [String] {
        let pattern = #"<@([A-Z0-9][A-Z0-9.-]{1,63})(?:\|[^>]+)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        var seen = Set<String>()
        return regex.matches(in: content, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: content)
            else {
                return nil
            }
            let id = String(content[idRange])
            return seen.insert(id).inserted ? id : nil
        }
    }

    private static func isOwnMessage(
        event: SlackEventMessage,
        config: SlackConnectionConfiguration
    ) -> Bool {
        let userId = SlackConnectionConfiguration.normalizedOptionalId(event.user)
        let botId = SlackConnectionConfiguration.normalizedOptionalId(event.botId)
        return userId.map { $0 == config.botUserId } == true
            || botId.map { $0 == config.botId } == true
    }

    private static func isValidThreadTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static func messageDictionary(_ message: SlackMessage, channelId: String) -> [String: Any] {
        let threadTs = message.threadTs ?? message.ts
        return [
            "id": message.ts,
            "channel_id": channelId,
            "content": message.text ?? "",
            "timestamp": message.ts,
            "thread_id": "\(channelId):\(threadTs)",
            "thread_ts": threadTs,
            "author": [
                "id": message.user ?? message.botId ?? "",
                "username": message.username ?? "",
                "display_name": message.username ?? message.user ?? message.botId ?? "",
                "is_bot": message.botId != nil,
            ],
            "reply_count": message.replyCount ?? 0,
            "attachments": [] as [[String: Any]],
        ]
    }
}
