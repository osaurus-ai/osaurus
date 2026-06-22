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
    let identity: SlackAuthIdentity?
    let configuredTeams: [SlackConfiguredTeamDiagnostic]
    let readableChannelIds: [String]
    let writableChannelIds: [String]
    let writeEnabled: Bool
    let allowBroadcastMentions: Bool
    let status: String
    let failures: [String]

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "bot_token_saved": botTokenSaved,
            "signing_secret_saved": signingSecretSaved,
            "configured_teams": configuredTeams.map(\.dictionary),
            "readable_channel_ids": readableChannelIds,
            "writable_channel_ids": writableChannelIds,
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
        case .api(let message):
            return message
        }
    }
}

final class SlackConnectionService: @unchecked Sendable {
    static let shared = SlackConnectionService(
        client: SlackAPIClient(),
        credentialStore: KeychainSlackCredentialStorage()
    )

    private let client: SlackAPIClientProtocol
    private let credentialStore: any SlackCredentialStorage

    init(
        client: SlackAPIClientProtocol,
        credentialStore: any SlackCredentialStorage = KeychainSlackCredentialStorage()
    ) {
        self.client = client
        self.credentialStore = credentialStore
    }

    func configuration() -> SlackConnectionConfiguration {
        SlackConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: SlackConnectionConfiguration) throws {
        do {
            try SlackConnectionConfigurationStore.save(configuration)
        } catch {
            throw SlackConnectionServiceError.configurationSaveFailed(error.localizedDescription)
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

    func diagnostics() async -> SlackConnectionDiagnostics {
        let config = configuration()
        guard let token = credentialStore.botToken() else {
            return SlackConnectionDiagnostics(
                botTokenSaved: false,
                signingSecretSaved: credentialStore.hasSigningSecret(),
                identity: nil,
                configuredTeams: [],
                readableChannelIds: config.readableChannelIds,
                writableChannelIds: config.writableChannelIds,
                writeEnabled: config.writeEnabled,
                allowBroadcastMentions: config.allowBroadcastMentions,
                status: "not_configured",
                failures: ["No Slack bot token is saved."]
            )
        }
        let signingSecret = credentialStore.signingSecret()

        let identity: SlackAuthIdentity?
        var failures: [String] = []
        do {
            identity = try await client.authTest(token: token)
        } catch {
            identity = nil
            failures.append(redacted(error, token: token, signingSecret: signingSecret))
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

        let status: String
        if identity == nil {
            status = "token_invalid_or_unavailable"
        } else if let identity, !config.canUseTeam(teamId: identity.teamId) {
            status = "connected_team_not_allowlisted"
        } else if config.readableChannelIds.isEmpty && config.writableChannelIds.isEmpty {
            status = "connected_needs_allowlist"
        } else if config.writeEnabled && config.writableChannelIds.isEmpty {
            status = "connected_read_only_write_needs_channels"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        return SlackConnectionDiagnostics(
            botTokenSaved: true,
            signingSecretSaved: signingSecret != nil,
            identity: identity,
            configuredTeams: teamRows,
            readableChannelIds: config.readableChannelIds,
            writableChannelIds: config.writableChannelIds,
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
        guard identity.teamId == normalizedTeamId else {
            throw SlackConnectionServiceError.teamNotConfigured(normalizedTeamId)
        }

        let channels = try await client.conversations(token: token, limit: 100)
        return channels.map { channel in
            [
                "id": channel.id,
                "name": channel.displayName,
                "type": channel.kind,
                "team_id": normalizedTeamId,
                "is_private": channel.isPrivate ?? false,
                "is_member": channel.isMember ?? false,
                "read_allowed": config.canRead(channelId: channel.id),
                "write_allowed": config.canWrite(channelId: channel.id),
            ]
        }
    }

    func readChannel(channelId: String, limit: Int?) async throws -> [String: Any] {
        let token = try requireToken()
        let config = configuration()
        let normalizedChannelId = try requireReadableChannel(channelId, config: config)
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        let messages = try await client.messages(
            channelId: normalizedChannelId,
            token: token,
            limit: safeLimit
        )
        return [
            "kind": "slack_recent_messages",
            "channel_id": normalizedChannelId,
            "limit": safeLimit,
            "partial": true,
            "messages": messages.map { Self.messageDictionary($0, channelId: normalizedChannelId) },
        ]
    }

    func readThread(threadId: String, limit: Int?) async throws -> [String: Any] {
        let token = try requireToken()
        let config = configuration()
        let parsed = try parseThreadId(threadId)
        let normalizedChannelId = try requireReadableChannel(parsed.channelId, config: config)
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        let messages = try await client.threadMessages(
            channelId: normalizedChannelId,
            threadTs: parsed.threadTs,
            token: token,
            limit: safeLimit
        )
        return [
            "kind": "slack_thread_messages",
            "channel_id": normalizedChannelId,
            "thread_id": "\(normalizedChannelId):\(parsed.threadTs)",
            "thread_ts": parsed.threadTs,
            "limit": safeLimit,
            "partial": true,
            "messages": messages.map { Self.messageDictionary($0, channelId: normalizedChannelId) },
        ]
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
            let messages = try await client.messages(channelId: channelId, token: token, limit: safeLimit)
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
        let message = try await client.sendMessage(
            channelId: normalizedChannelId,
            content: trimmedContent,
            threadTs: nil,
            token: token
        )
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
        let message = try await client.sendMessage(
            channelId: normalizedChannelId,
            content: trimmedContent,
            threadTs: parsed.threadTs,
            token: token
        )
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

    private func redacted(_ error: Error, token: String, signingSecret: String?) -> String {
        SlackSecurity.redact(error.localizedDescription, token: token, signingSecret: signingSecret)
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
