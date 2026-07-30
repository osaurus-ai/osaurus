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
    /// Socket Mode receive credential state, independent of bot API
    /// connectivity: `not_configured` (no app token), `ok` (Slack accepted
    /// the app token via `apps.connections.open`), `invalid` (Slack
    /// rejected it), or `unverified` (validation was skipped).
    let socketModeStatus: String
    /// True only when every native receive prerequisite holds: valid bot
    /// identity, accepted app token, readable channels, and authorized
    /// senders. A signing secret never contributes to this.
    let receiveReady: Bool
    let inboundDispatchEnabled: Bool
    /// Machine reason inbound dispatch cannot run (nil when dispatch is
    /// disabled or fully configured).
    let inboundDispatchIssue: String?
    /// Actionable environment warnings, e.g. multiple running Osaurus
    /// instances competing for Socket Mode envelopes.
    let warnings: [String]

    init(
        botTokenSaved: Bool,
        signingSecretSaved: Bool,
        appTokenSaved: Bool,
        identity: SlackAuthIdentity?,
        configuredTeams: [SlackConfiguredTeamDiagnostic],
        readableChannelIds: [String],
        writableChannelIds: [String],
        senderAllowlist: [String],
        writeEnabled: Bool,
        allowBroadcastMentions: Bool,
        status: String,
        failures: [String],
        socketModeStatus: String = "unverified",
        receiveReady: Bool = false,
        inboundDispatchEnabled: Bool = false,
        inboundDispatchIssue: String? = nil,
        warnings: [String] = []
    ) {
        self.botTokenSaved = botTokenSaved
        self.signingSecretSaved = signingSecretSaved
        self.appTokenSaved = appTokenSaved
        self.identity = identity
        self.configuredTeams = configuredTeams
        self.readableChannelIds = readableChannelIds
        self.writableChannelIds = writableChannelIds
        self.senderAllowlist = senderAllowlist
        self.writeEnabled = writeEnabled
        self.allowBroadcastMentions = allowBroadcastMentions
        self.status = status
        self.failures = failures
        self.socketModeStatus = socketModeStatus
        self.receiveReady = receiveReady
        self.inboundDispatchEnabled = inboundDispatchEnabled
        self.inboundDispatchIssue = inboundDispatchIssue
        self.warnings = warnings
    }

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
            "socket_mode_status": socketModeStatus,
            "receive_ready": receiveReady,
            "inbound_dispatch_enabled": inboundDispatchEnabled,
            "warnings": warnings,
        ]
        if let inboundDispatchIssue {
            result["inbound_dispatch_issue"] = inboundDispatchIssue
        }
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

struct SlackConnectionDiscovery: Equatable, Sendable {
    let identity: SlackAuthIdentity
    let conversations: [SlackConversation]
    let users: [SlackUser]
    let conversationsTruncated: Bool
    let usersTruncated: Bool
    let warnings: [String]
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
    let files: [SlackFile]

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
        case files
    }

    init(
        type: String?,
        subtype: String?,
        channel: String?,
        user: String?,
        botId: String?,
        text: String?,
        ts: String?,
        threadTs: String?,
        channelType: String?,
        files: [SlackFile] = []
    ) {
        self.type = type
        self.subtype = subtype
        self.channel = channel
        self.user = user
        self.botId = botId
        self.text = text
        self.ts = ts
        self.threadTs = threadTs
        self.channelType = channelType
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decodeIfPresent(String.self, forKey: .type),
            subtype: try container.decodeIfPresent(String.self, forKey: .subtype),
            channel: try container.decodeIfPresent(String.self, forKey: .channel),
            user: try container.decodeIfPresent(String.self, forKey: .user),
            botId: try container.decodeIfPresent(String.self, forKey: .botId),
            text: try container.decodeIfPresent(String.self, forKey: .text),
            ts: try container.decodeIfPresent(String.self, forKey: .ts),
            threadTs: try container.decodeIfPresent(String.self, forKey: .threadTs),
            channelType: try container.decodeIfPresent(String.self, forKey: .channelType),
            files: try container.decodeIfPresent([SlackFile].self, forKey: .files) ?? []
        )
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
    let attachments: [AgentChannelStoredAttachment]
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
            attachments: attachments,
            payloadJSON: payloadJSON,
            providerTimestamp: providerMessageId
        )
    }
}

/// Normalization result with a machine rejection reason for stage telemetry.
enum SlackInboundEventClassification: Equatable, Sendable {
    case message(SlackNormalizedInboundMessage)
    case rejected(reason: String)
}

/// Storage-layer outcome for one inbound envelope: either a verified message
/// ready for dispatch, or the machine reason it was refused.
enum SlackInboundEventOutcome: Equatable, Sendable {
    case accepted(SlackNormalizedInboundMessage)
    case rejected(reason: String)
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
    static let maxUserListPages = 5
    static let maxMessagePages = 5

    private let client: SlackAPIClientProtocol
    private let credentialStore: any SlackCredentialStorage
    private let messageStore: AgentChannelMessageStore?
    private let recordMessageSnapshotsInline: Bool
    private let inboundAgentAvailability: @Sendable (UUID) async -> Bool
    private let runningInstanceCount: @Sendable () -> Int

    init(
        client: SlackAPIClientProtocol,
        credentialStore: any SlackCredentialStorage = KeychainSlackCredentialStorage(),
        messageStore: AgentChannelMessageStore? = nil,
        recordMessageSnapshotsInline: Bool = false,
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
        self.inboundAgentAvailability = inboundAgentAvailability
        self.runningInstanceCount = runningInstanceCount
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
        AgentChannelCredentialAvailability.shared.invalidate(.slack)
        return saved
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        defer { AgentChannelCredentialAvailability.shared.invalidate(.slack) }
        return credentialStore.deleteBotToken()
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

    // MARK: - Off-main credential access
    //
    // SecItem calls can block for seconds under securityd contention, so UI
    // flows await these instead of the synchronous accessors above.

    struct CredentialPresence: Sendable {
        let botToken: Bool
        let signingSecret: Bool
        let appToken: Bool
    }

    func credentialPresenceOffMain() async -> CredentialPresence {
        let store = credentialStore
        return await Keychain.perform {
            CredentialPresence(
                botToken: store.hasBotToken(),
                signingSecret: store.hasSigningSecret(),
                appToken: store.hasAppToken()
            )
        }
    }

    /// Save any provided secrets in one keychain hop; nil means "no change".
    func saveCredentialsOffMain(
        botToken: String? = nil,
        signingSecret: String? = nil,
        appToken: String? = nil
    ) async throws {
        let store = credentialStore
        let failure: String? = await Keychain.perform {
            if let botToken, !store.saveBotToken(botToken) {
                return "The bot token was empty or Keychain storage was unavailable."
            }
            if let signingSecret, !store.saveSigningSecret(signingSecret) {
                return "The signing secret was empty or Keychain storage was unavailable."
            }
            if let appToken, !store.saveAppToken(appToken) {
                return "The app-level token was empty or Keychain storage was unavailable."
            }
            return nil
        }
        if botToken != nil {
            AgentChannelCredentialAvailability.shared.invalidate(.slack)
        }
        if let failure {
            throw SlackConnectionServiceError.configurationSaveFailed(failure)
        }
    }

    @discardableResult
    func deleteBotTokenOffMain() async -> Bool {
        let store = credentialStore
        defer { AgentChannelCredentialAvailability.shared.invalidate(.slack) }
        return await Keychain.perform { store.deleteBotToken() }
    }

    @discardableResult
    func deleteSigningSecretOffMain() async -> Bool {
        let store = credentialStore
        return await Keychain.perform { store.deleteSigningSecret() }
    }

    @discardableResult
    func deleteAppTokenOffMain() async -> Bool {
        let store = credentialStore
        return await Keychain.perform { store.deleteAppToken() }
    }

    func socketModeAppToken(teamId: String) -> String? {
        credentialStore.appToken(teamId: teamId)
    }

    func workspaceAccountIdsWithAppTokens() -> [String] {
        configuration().workspaceAccounts
            .map(\.teamId)
            .filter { credentialStore.appToken(teamId: $0) != nil }
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
        let duplicateWarning = OsaurusRunningInstanceInspector.duplicateInstanceWarning(
            instanceCount: runningInstanceCount()
        )
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
                failures: ["No Slack bot token is saved."],
                socketModeStatus: credentialStore.hasAppToken() ? "unverified" : "not_configured",
                inboundDispatchEnabled: config.inboundDispatch.enabled,
                warnings: [duplicateWarning].compactMap(\.self)
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

        // Receive readiness is separate from bot API connectivity: the app
        // token drives the Socket Mode transport and must be validated
        // through `apps.connections.open`, not inferred from being saved.
        let socketModeStatus: String
        if let appToken {
            do {
                _ = try await client.openSocketModeConnection(appToken: appToken)
                socketModeStatus = "ok"
            } catch {
                socketModeStatus = "invalid"
                failures.append(
                    "Slack rejected the Socket Mode app token. Generate an app-level token with the connections:write scope under Basic Information → App-Level Tokens. \(redacted(error, token: token, signingSecret: signingSecret, appToken: appToken))"
                )
            }
        } else {
            socketModeStatus = "not_configured"
        }

        var inboundDispatchIssue: String?
        if config.inboundDispatch.enabled {
            let referencedAgents = config.inboundDispatch.referencedAgentIds
            if referencedAgents.isEmpty {
                inboundDispatchIssue = "inbound_agent_not_selected"
                failures.append(
                    "Inbound dispatch is enabled but no agent is selected for incoming Slack messages."
                )
            } else {
                for agentId in referencedAgents where await !inboundAgentAvailability(agentId) {
                    inboundDispatchIssue = "inbound_agent_unavailable"
                    failures.append(
                        "Inbound dispatch is enabled but a routed agent no longer exists. Update the routing rules in Slack settings."
                    )
                    break
                }
            }
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
            if let account = config.workspaceAccounts.first(where: { $0.teamId == teamId }) {
                teamRows.append(SlackConfiguredTeamDiagnostic(
                    id: teamId,
                    name: account.teamName ?? "",
                    status: credentialStore.hasBotToken(teamId: teamId) ? "accessible" : "token_missing",
                    reason: credentialStore.hasBotToken(teamId: teamId)
                        ? nil : "The workspace bot token is missing."
                ))
            } else {
                teamRows.append(SlackConfiguredTeamDiagnostic(
                    id: teamId,
                    name: "",
                    status: "configured_not_current_token_team",
                    reason: "The saved bot token did not authenticate as this workspace."
                ))
            }
        }

        // A signing secret alone never counts as receive capability: native
        // Slack receive runs over Socket Mode, which requires the app token.
        let receiveCredentialSaved = appToken != nil
        let receiveNeedsSenderAllowlist = receiveCredentialSaved
            && !config.readableChannelIds.isEmpty
            && config.senderAllowlist.isEmpty
        let receiveReady = identity != nil
            && socketModeStatus == "ok"
            && !config.readableChannelIds.isEmpty
            && !config.senderAllowlist.isEmpty

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
            failures: failures,
            socketModeStatus: socketModeStatus,
            receiveReady: receiveReady,
            inboundDispatchEnabled: config.inboundDispatch.enabled,
            inboundDispatchIssue: inboundDispatchIssue,
            warnings: [duplicateWarning].compactMap(\.self)
        )
    }

    /// Fetch metadata for the settings picker without applying the current
    /// workspace/channel allowlists. Setup must be able to discover the
    /// authenticated workspace even when the saved allowlist is empty or stale.
    /// Authentication failure is fatal; channel/user scope failures are returned
    /// as warnings so operators can still repair the rest of the configuration.
    func discoverConfigurationOptions() async throws -> SlackConnectionDiscovery {
        let token = try requireToken()
        return try await discoverConfigurationOptions(token: token, persistPrimaryIdentity: true)
    }

    func discoverConfigurationOptions(botToken: String) async throws -> SlackConnectionDiscovery {
        let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SlackConnectionServiceError.notConfigured }
        return try await discoverConfigurationOptions(token: token, persistPrimaryIdentity: false)
    }

    private func discoverConfigurationOptions(
        token: String,
        persistPrimaryIdentity: Bool
    ) async throws -> SlackConnectionDiscovery {
        let signingSecret = credentialStore.signingSecret()
        let appToken = credentialStore.appToken()
        let identity: SlackAuthIdentity
        do {
            identity = try await client.authTest(token: token)
            if persistPrimaryIdentity {
                persistIdentity(identity)
            }
        } catch {
            throw SlackConnectionServiceError.api(redacted(
                error,
                token: token,
                signingSecret: signingSecret,
                appToken: appToken
            ))
        }

        var conversations: [SlackConversation] = []
        var users: [SlackUser] = []
        var conversationsTruncated = false
        var usersTruncated = false
        var warnings: [String] = []

        do {
            (conversations, conversationsTruncated) = try await collectConversations(token: token)
        } catch {
            warnings.append(
                "Channels could not be loaded. "
                    + redacted(error, token: token, signingSecret: signingSecret, appToken: appToken)
            )
        }

        do {
            (users, usersTruncated) = try await collectUsers(token: token)
        } catch {
            warnings.append(
                "Workspace users could not be loaded. "
                    + redacted(error, token: token, signingSecret: signingSecret, appToken: appToken)
            )
        }

        if conversationsTruncated {
            warnings.append(
                "Only the first \(Self.maxConversationListPages * 100) Slack conversations are shown."
            )
        }
        if usersTruncated {
            warnings.append(
                "Only the first \(Self.maxUserListPages * 200) Slack users are shown."
            )
        }

        return SlackConnectionDiscovery(
            identity: identity,
            conversations: conversations.sorted {
                if $0.isMember != $1.isMember { return $0.isMember && !$1.isMember }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            },
            users: users.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            },
            conversationsTruncated: conversationsTruncated,
            usersTruncated: usersTruncated,
            warnings: warnings
        )
    }

    func saveWorkspaceAccount(
        discovery: SlackConnectionDiscovery,
        botToken: String,
        appToken: String?,
        readableChannelIds: [String],
        writableChannelIds: [String],
        senderAllowlist: [String]
    ) throws {
        let teamId = discovery.identity.teamId
        guard credentialStore.saveBotToken(botToken, teamId: teamId) else {
            throw SlackConnectionServiceError.configurationSaveFailed("The workspace bot token could not be saved.")
        }
        if let appToken = appToken?.trimmingCharacters(in: .whitespacesAndNewlines), !appToken.isEmpty,
           !credentialStore.saveAppToken(appToken, teamId: teamId) {
            throw SlackConnectionServiceError.configurationSaveFailed("The workspace app token could not be saved.")
        }
        var config = configuration()
        let account = SlackWorkspaceAccountConfiguration(
            teamId: teamId,
            teamName: discovery.identity.team,
            readableChannelIds: readableChannelIds,
            writableChannelIds: writableChannelIds,
            senderAllowlist: senderAllowlist,
            botUserId: discovery.identity.userId,
            botId: discovery.identity.botId,
            apiAppId: nil
        )
        config.workspaceAccounts.removeAll { $0.teamId == teamId }
        config.workspaceAccounts.append(account)
        if !config.configuredTeamIds.contains(teamId) {
            config.configuredTeamIds.append(teamId)
        }
        try saveConfiguration(config)
    }

    func removeWorkspaceAccount(teamId: String) throws {
        let teamId = SlackConnectionConfiguration.normalizedId(teamId)
        var config = configuration()
        config.workspaceAccounts.removeAll { $0.teamId == teamId }
        config.configuredTeamIds.removeAll { $0 == teamId }
        _ = credentialStore.deleteBotToken(teamId: teamId)
        _ = credentialStore.deleteAppToken(teamId: teamId)
        try saveConfiguration(config)
    }

    func listWorkspaces() async throws -> [[String: Any]] {
        let token = try requireToken()
        let config = configuration()
        let identity = try await client.authTest(token: token)
        persistIdentity(identity)
        guard config.canUseTeam(teamId: identity.teamId) else {
            throw SlackConnectionServiceError.teamNotConfigured(identity.teamId)
        }
        var rows: [[String: Any]] = [[
            "id": identity.teamId,
            "name": identity.team ?? identity.teamId,
            "configured": config.configuredTeamIds.isEmpty || config.configuredTeamIds.contains(identity.teamId),
        ]]
        rows.append(contentsOf: config.workspaceAccounts.map {
            [
                "id": $0.teamId,
                "name": $0.teamName ?? $0.teamId,
                "configured": true,
            ]
        })
        return rows
    }

    func listChannels(teamId: String) async throws -> [[String: Any]] {
        let config = configuration()
        let normalizedTeamId = try requireSlackId(teamId, field: "team_id")
        guard config.canUseTeam(teamId: normalizedTeamId) else {
            throw SlackConnectionServiceError.teamNotConfigured(normalizedTeamId)
        }
        let token = try requireToken(forTeamId: normalizedTeamId, config: config)
        let identity = try await client.authTest(token: token)
        if config.workspaceAccounts.allSatisfy({ $0.teamId != normalizedTeamId }) {
            persistIdentity(identity)
        }
        guard identity.teamId == normalizedTeamId else {
            throw SlackConnectionServiceError.teamNotConfigured(normalizedTeamId)
        }

        let (channels, truncated) = try await collectConversations(token: token)
        // DMs have no `name`; resolve the person's display name so a `D…`
        // conversation never surfaces as a bare id. Name resolution is
        // best-effort — a users.list failure degrades to ids, not an error.
        var userNames: [String: String] = [:]
        if channels.contains(where: { $0.isIM && $0.user != nil }) {
            if let (users, _) = try? await collectUsers(token: token) {
                for user in users {
                    userNames[user.id] = user.displayName
                }
            }
        }
        var rows: [[String: Any]] = channels.map { channel in
            [
                "id": channel.id,
                "name": channel.resolvedDisplayName(userNames: userNames),
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

    private func collectConversations(token: String) async throws -> ([SlackConversation], Bool) {
        var conversations: [SlackConversation] = []
        var cursor: String?
        var truncated = false
        for page in 0 ..< Self.maxConversationListPages {
            let result = try await client.conversations(token: token, limit: 100, cursor: cursor)
            conversations.append(contentsOf: result.conversations)
            guard let nextCursor = result.nextCursor else {
                truncated = false
                break
            }
            cursor = nextCursor
            truncated = page == Self.maxConversationListPages - 1
        }
        return (conversations, truncated)
    }

    private func collectUsers(token: String) async throws -> ([SlackUser], Bool) {
        var users: [SlackUser] = []
        var cursor: String?
        var truncated = false
        for page in 0 ..< Self.maxUserListPages {
            let result = try await client.users(token: token, limit: 200, cursor: cursor)
            users.append(contentsOf: result.users)
            guard let nextCursor = result.nextCursor else {
                truncated = false
                break
            }
            cursor = nextCursor
            truncated = page == Self.maxUserListPages - 1
        }
        return (users, truncated)
    }

    func readChannel(channelId: String, limit: Int?) async throws -> [String: Any] {
        let config = configuration()
        let normalizedChannelId = try requireReadableChannel(channelId, config: config)
        let token = try requireToken(forChannelId: normalizedChannelId, config: config)
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
        let config = configuration()
        let parsed = try parseThreadId(threadId)
        let normalizedChannelId = try requireReadableChannel(parsed.channelId, config: config)
        let token = try requireToken(forChannelId: normalizedChannelId, config: config)
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

        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limitPerChannel ?? config.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        let needle = trimmedQuery.lowercased()
        var matches: [[String: Any]] = []

        for channelId in allowedChannels {
            let token = try requireToken(forChannelId: channelId, config: config)
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
        let config = configuration()
        let normalizedChannelId = try requireWritableChannel(channelId, config: config)
        let token = try requireToken(forChannelId: normalizedChannelId, config: config)
        let trimmedContent = try validateMessageContent(content, config: config)
        let messages = try await sendRenderedChunks(
            content: trimmedContent,
            channelId: normalizedChannelId,
            threadTs: nil,
            token: token
        )
        var result: [String: Any] = [
            "kind": "slack_message_sent",
            "channel_id": normalizedChannelId,
            "message": Self.messageDictionary(messages[0], channelId: normalizedChannelId),
            "mention_policy": mentionPolicyDictionary(config: config),
        ]
        if messages.count > 1 {
            result["chunk_count"] = messages.count
        }
        return result
    }

    /// Renders agent Markdown to Slack `markdown_text` chunks and posts them
    /// in order (same channel/thread). Returns the sent messages, first chunk
    /// first. Content that would need more than
    /// `AgentChannelMessageFormatter.maxChunksPerSend` messages fails as too
    /// long instead of flooding the channel.
    private func sendRenderedChunks(
        content: String,
        channelId: String,
        threadTs: String?,
        token: String
    ) async throws -> [SlackMessage] {
        let chunks = AgentChannelMessageFormatter.slackChunks(content)
        guard !chunks.isEmpty else {
            throw SlackConnectionServiceError.emptyMessage
        }
        guard chunks.count <= AgentChannelMessageFormatter.maxChunksPerSend else {
            throw SlackConnectionServiceError.messageTooLong
        }
        var messages: [SlackMessage] = []
        for chunk in chunks {
            let request = SlackOutboundMessageRequest(
                channelId: channelId,
                content: chunk,
                threadTs: threadTs
            )
            messages.append(try await client.sendMessage(request, token: token))
        }
        recordMessages(messages, channelId: channelId, direction: .outbound)
        return messages
    }

    func replyToThread(
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else {
            throw SlackConnectionServiceError.sendConfirmationRequired
        }
        let config = configuration()
        let parsed = try parseThreadId(threadId)
        let normalizedChannelId = try requireWritableChannel(parsed.channelId, config: config)
        let token = try requireToken(forChannelId: normalizedChannelId, config: config)
        let trimmedContent = try validateMessageContent(content, config: config)
        let messages = try await sendRenderedChunks(
            content: trimmedContent,
            channelId: normalizedChannelId,
            threadTs: parsed.threadTs,
            token: token
        )
        var result: [String: Any] = [
            "kind": "slack_thread_reply_sent",
            "channel_id": normalizedChannelId,
            "thread_id": "\(normalizedChannelId):\(parsed.threadTs)",
            "thread_ts": parsed.threadTs,
            "message": Self.messageDictionary(messages[0], channelId: normalizedChannelId),
            "mention_policy": mentionPolicyDictionary(config: config),
        ]
        if messages.count > 1 {
            result["chunk_count"] = messages.count
        }
        return result
    }

    func editMessage(
        channelId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw SlackConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let token = try requireToken(forChannelId: channelId, config: config)
        guard Self.isValidThreadTimestamp(messageId) else {
            throw SlackConnectionServiceError.invalidId(field: "message_id")
        }
        let content = try validateMessageContent(content, config: config)
        // Edits must stay a single native message: reject content whose
        // rendered form would need chunking.
        let chunks = AgentChannelMessageFormatter.slackChunks(content)
        guard chunks.count == 1, let rendered = chunks.first else {
            throw SlackConnectionServiceError.messageTooLong
        }
        let message = try await client.updateMessage(
            channelId: channelId,
            messageId: messageId,
            content: rendered,
            token: token
        )
        recordMessages([message], channelId: channelId, direction: .outbound)
        return [
            "kind": "slack_message_edited",
            "channel_id": channelId,
            "message_id": messageId,
            "message": Self.messageDictionary(message, channelId: channelId),
        ]
    }

    func deleteMessage(
        channelId: String,
        messageId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw SlackConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let token = try requireToken(forChannelId: channelId, config: config)
        guard Self.isValidThreadTimestamp(messageId) else {
            throw SlackConnectionServiceError.invalidId(field: "message_id")
        }
        try await client.deleteMessage(channelId: channelId, messageId: messageId, token: token)
        return [
            "kind": "slack_message_deleted",
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
        guard confirmSend else { throw SlackConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let channelId = try requireWritableChannel(channelId, config: config)
        let token = try requireToken(forChannelId: channelId, config: config)
        guard Self.isValidThreadTimestamp(messageId) else {
            throw SlackConnectionServiceError.invalidId(field: "message_id")
        }
        guard let reaction = AgentChannelReactionNormalizer.slackName(reaction) else {
            throw SlackConnectionServiceError.invalidId(field: "reaction")
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
            "kind": adding ? "slack_reaction_added" : "slack_reaction_removed",
            "channel_id": channelId,
            "message_id": messageId,
            "reaction": reaction,
            "delivery_status": adding ? "added" : "removed",
        ]
    }

    private func requireToken() throws -> String {
        guard let token = credentialStore.botToken() else {
            throw SlackConnectionServiceError.notConfigured
        }
        return token
    }

    private func requireToken(
        forTeamId teamId: String,
        config: SlackConnectionConfiguration
    ) throws -> String {
        if config.workspaceAccounts.contains(where: { $0.teamId == teamId }) {
            guard let token = credentialStore.botToken(teamId: teamId) else {
                throw SlackConnectionServiceError.notConfigured
            }
            return token
        }
        return try requireToken()
    }

    private func requireToken(
        forChannelId channelId: String,
        config: SlackConnectionConfiguration
    ) throws -> String {
        if let account = config.workspaceAccounts.first(where: {
            $0.readableChannelIds.contains(channelId) || $0.writableChannelIds.contains(channelId)
        }) {
            guard let token = credentialStore.botToken(teamId: account.teamId) else {
                throw SlackConnectionServiceError.notConfigured
            }
            return token
        }
        return try requireToken()
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
        if case .message(let message) = classifyInboundEvent(
            envelope,
            config: config,
            enforceSenderAllowlist: enforceSenderAllowlist
        ) {
            return message
        }
        return nil
    }

    /// Classifies an inbound envelope with a machine rejection reason so
    /// transports can report the exact boundary that dropped an event
    /// instead of silently returning nil.
    func classifyInboundEvent(
        _ envelope: SlackEventEnvelope,
        config: SlackConnectionConfiguration,
        enforceSenderAllowlist: Bool = true
    ) -> SlackInboundEventClassification {
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
            return .rejected(reason: "not_a_channel_message")
        }
        let account = config.workspaceAccounts.first { $0.teamId == teamId }
        let botUserId = account?.botUserId ?? config.botUserId
        let botId = account?.botId ?? config.botId
        let channelAllowed = account?.readableChannelIds.contains(channelId) ?? config.canRead(channelId: channelId)
        guard config.canUseTeam(teamId: teamId) else {
            return .rejected(reason: "team_not_allowlisted")
        }
        guard channelAllowed else {
            return .rejected(reason: "channel_not_readable")
        }
        guard botUserId != nil || botId != nil else {
            return .rejected(reason: "bot_identity_unknown")
        }

        guard !Self.isOwnMessage(event: event, botUserId: botUserId, botId: botId) else {
            return .rejected(reason: "own_message")
        }

        let authorId = event.user ?? event.botId
        let senderAllowed = account.map { account in
            authorId.map { account.senderAllowlist.contains($0) } ?? false
        } ?? config.canUseSender(senderId: authorId)
        if enforceSenderAllowlist && !senderAllowed {
            return .rejected(reason: "sender_not_allowlisted")
        }

        let content = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadTs = event.threadTs.flatMap { candidate -> String? in
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.isValidThreadTimestamp(normalized) ? normalized : nil
        } ?? messageTs
        let mentionedUserIds = Self.mentionedUserIds(in: content)
        let mentionsBot = botUserId.map(mentionedUserIds.contains) ?? false
        return .message(SlackNormalizedInboundMessage(
            connectionId: AgentChannelConnection.nativeSlackConnectionId,
            providerEventId: providerEventId,
            teamId: teamId,
            roomId: channelId,
            providerMessageId: messageTs,
            threadId: "\(channelId):\(threadTs)",
            threadTs: threadTs,
            authorId: authorId,
            content: content,
            attachments: event.files.map(Self.storedAttachment),
            isThreadReply: threadTs != messageTs,
            isMention: event.type == "app_mention" || mentionsBot,
            mentionedUserIds: mentionedUserIds,
            payloadJSON: Self.encodedInboundPayload(envelope)
        ))
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
        if case .accepted(let normalized) = try recordInboundEventOutcome(envelope) {
            return normalized
        }
        return nil
    }

    /// Like `recordInboundEvent`, but reports the machine reason an envelope
    /// was refused so transports can publish per-event stage telemetry.
    func recordInboundEventOutcome(_ envelope: SlackEventEnvelope) throws -> SlackInboundEventOutcome {
        let config = configuration()
        let classification = classifyInboundEvent(
            envelope,
            config: config,
            enforceSenderAllowlist: messageStore == nil
        )
        guard case .message(let normalized) = classification else {
            if case .rejected(let reason) = classification {
                return .rejected(reason: reason)
            }
            return .rejected(reason: "not_a_channel_message")
        }
        guard let messageStore else {
            return .accepted(normalized)
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
        guard authorization.decision == .allow else {
            return .rejected(reason: authorization.reason)
        }
        guard try messageStore.markEventSeen(
            connectionId: normalized.connectionId,
            providerEventId: Self.inboundDispatchEventId(normalized)
        ) else {
            return .rejected(reason: "duplicate_event")
        }
        return .accepted(normalized)
    }

    func relayInboundMessage(
        _ message: SlackNormalizedInboundMessage
    ) async -> AgentChannelInboundRelaySubmission {
        let config = configuration()
        let settings = config.inboundDispatch
        guard settings.isConfigured else {
            return .suppressed("inbound_dispatch_not_configured")
        }
        guard let senderId = message.authorId else {
            return .suppressed("inbound_sender_missing")
        }
        if settings.requireMention, !message.isMention {
            let continuingKnownThread =
                settings.continueThreads
                && message.isThreadReply
                && hasOutboundMessage(in: message.threadId, roomId: message.roomId)
            guard continuingKnownThread else {
                return .suppressed("mention_required")
            }
        }

        let content: String
        let botUserId = message.teamId.flatMap { teamId in
            config.workspaceAccounts.first { $0.teamId == teamId }?.botUserId
        } ?? config.botUserId
        if let botUserId {
            content = message.content
                .replacingOccurrences(of: "<@\(botUserId)>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            content = message.content
        }
        let identity = ChannelIdentity(
            kind: .slack,
            installationId: message.teamId ?? message.connectionId,
            groupId: message.roomId,
            threadId: message.threadTs,
            sender: ChannelSenderMetadata(senderId: senderId),
            trustLevel: .verified
        )
        let responder: AgentChannelInboundReplyHandler?
        if settings.autoReplyEnabled {
            responder = { [weak self] reply in
                guard let self else {
                    throw SlackConnectionServiceError.api("Slack connection was released before replying.")
                }
                _ = try await self.replyToThread(
                    threadId: message.threadId,
                    content: self.redactSecrets(in: reply),
                    confirmSend: true
                )
            }
        } else {
            responder = nil
        }
        return await AgentChannelInboundRelay.shared.submit(
            AgentChannelInboundRelayRequest(
                identity: identity,
                connectionId: message.connectionId,
                providerEventId: message.providerEventId,
                providerRoute: AgentChannelProviderRoute(
                    conversationId: message.roomId,
                    threadId: message.threadTs,
                    displayName: "Slack \(message.roomId)"
                ),
                content: content,
                attachments: message.attachments,
                settings: settings,
                sourceLabel: "Slack workspace \(message.teamId ?? "unknown"), channel \(message.roomId), sender \(senderId)",
                reply: responder
            )
        )
    }

    private static func inboundDispatchEventId(_ message: SlackNormalizedInboundMessage) -> String {
        "slack-dispatch:\(message.roomId):\(message.providerMessageId)"
    }

    private func hasOutboundMessage(in threadId: String, roomId: String) -> Bool {
        guard let messageStore else { return false }
        do {
            try messageStore.openIfNeeded()
            return try messageStore.recentMessages(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                roomId: roomId,
                limit: 200
            ).contains { row in
                row.direction == .outbound && row.threadId == threadId
            }
        } catch {
            return false
        }
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
            attachments: message.files.map(Self.storedAttachment),
            payloadJSON: encodedPayload(message),
            providerTimestamp: message.ts
        )
    }

    private static func storedAttachment(_ file: SlackFile) -> AgentChannelStoredAttachment {
        let contentType = file.mimetype?.lowercased() ?? ""
        let kind: AgentChannelStoredAttachmentKind
        if contentType.hasPrefix("image/") {
            kind = .image
        } else if contentType.hasPrefix("audio/") {
            kind = .audio
        } else if contentType.hasPrefix("video/") {
            kind = .video
        } else {
            kind = .file
        }
        return AgentChannelStoredAttachment(
            providerId: file.id,
            kind: kind,
            filename: file.name,
            contentType: file.mimetype,
            sizeBytes: file.size,
            remoteURL: file.urlPrivateDownload ?? file.urlPrivate
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
        botUserId: String?,
        botId configuredBotId: String?
    ) -> Bool {
        let userId = SlackConnectionConfiguration.normalizedOptionalId(event.user)
        let botId = SlackConnectionConfiguration.normalizedOptionalId(event.botId)
        return userId.map { $0 == botUserId } == true
            || botId.map { $0 == configuredBotId } == true
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
            "attachments": message.files.map { file in
                [
                    "id": file.id,
                    "filename": file.name ?? "",
                    "content_type": file.mimetype ?? "",
                    "size": file.size ?? 0,
                    "url": file.urlPrivateDownload ?? file.urlPrivate ?? "",
                ] as [String: Any]
            },
        ]
    }
}
