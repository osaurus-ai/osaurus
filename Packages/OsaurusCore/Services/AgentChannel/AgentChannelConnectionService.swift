//
//  AgentChannelConnectionService.swift
//  osaurus
//
//  Standard action dispatcher for agent communication channels.
//

import Foundation

enum AgentChannelConnectionServiceError: LocalizedError, Equatable, Sendable {
    case connectionNotFound(String)
    case connectionDisabled(String)
    case unsupportedKind(AgentChannelKind)
    case unsupportedAction(action: AgentChannelAction, connectionId: String)
    case customExecutionNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let connectionId):
            return "Agent channel connection `\(connectionId)` is not configured."
        case .connectionDisabled(let connectionId):
            return "Agent channel connection `\(connectionId)` is disabled."
        case .unsupportedKind(let kind):
            return "Agent channel kind `\(kind.rawValue)` is not executable yet."
        case .unsupportedAction(let action, let connectionId):
            return "Agent channel connection `\(connectionId)` does not support `\(action.rawValue)`."
        case .customExecutionNotImplemented(let connectionId):
            return "Custom JSON channel `\(connectionId)` is configured, but custom HTTP execution is not enabled yet."
        }
    }
}

final class AgentChannelConnectionService: @unchecked Sendable {
    static let shared = AgentChannelConnectionService(discordService: .shared)

    private static let discordConnectionId = AgentChannelConnection.nativeDiscordConnectionId
    private let discordService: DiscordConnectionService

    init(discordService: DiscordConnectionService) {
        self.discordService = discordService
    }

    func listConnections() -> [[String: Any]] {
        var rows = [discordConnectionDictionary()]
        let customRows = AgentChannelConfigurationStore.load().connections
            .filter { $0.id.lowercased() != Self.discordConnectionId }
            .map(connectionDictionary)
        rows.append(contentsOf: customRows)
        return rows
    }

    func diagnostics(connectionId: String?) async -> [String: Any] {
        do {
            let connection = try resolveConnection(connectionId)
            switch connection.kind {
            case .discord:
                var payload = await discordService.diagnostics().dictionary
                payload["connection_id"] = connection.id
                payload["kind"] = connection.kind.rawValue
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                payload["message_store"] = discordService.messageStoreDiagnostics()
                return payload
            case .customHTTP:
                return [
                    "connection_id": connection.id,
                    "kind": connection.kind.rawValue,
                    "status": "configured_not_executable",
                    "enabled": connection.enabled,
                    "standard_actions": connection.supportedActions.map(\.rawValue),
                    "custom_actions": connection.customHTTP?.actions.keys.sorted() ?? [],
                    "action_policies": actionPolicies(for: connection).map(\.dictionary),
                    "relay_receive_policy": relayReceivePolicy(for: connection).dictionary,
                ]
            case .slack, .telegram:
                return [
                    "connection_id": connection.id,
                    "kind": connection.kind.rawValue,
                    "status": "configured_not_executable",
                    "enabled": connection.enabled,
                    "standard_actions": connection.supportedActions.map(\.rawValue),
                    "action_policies": actionPolicies(for: connection).map(\.dictionary),
                    "relay_receive_policy": relayReceivePolicy(for: connection).dictionary,
                ]
            }
        } catch {
            return [
                "status": "unavailable",
                "failure": error.localizedDescription,
            ]
        }
    }

    func listSpaces(connectionId: String?) async throws -> [[String: Any]] {
        let connection = try requireAction(.listSpaces, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            return try await discordService.listServers().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": "server",
                    "connection_id": connection.id,
                    "raw": row,
                ]
            }
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func listRooms(connectionId: String?, spaceId: String) async throws -> [[String: Any]] {
        let connection = try requireAction(.listRooms, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            return try await discordService.listChannels(guildId: spaceId).map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": "room",
                    "space_id": spaceId,
                    "connection_id": connection.id,
                    "read_allowed": row["read_allowed"] ?? false,
                    "write_allowed": row["write_allowed"] ?? false,
                    "raw": row,
                ]
            }
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func readMessages(connectionId: String?, roomId: String, limit: Int?) async throws -> [String: Any] {
        let connection = try requireAction(.readMessages, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.readChannel(channelId: roomId, limit: limit)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "channel_messages"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func readThread(connectionId: String?, threadId: String, limit: Int?) async throws -> [String: Any] {
        let connection = try requireAction(.readMessages, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.readThread(threadId: threadId, limit: limit)
            payload["connection_id"] = connection.id
            payload["thread_id"] = threadId
            payload["standard_kind"] = "thread_messages"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func searchMessages(
        connectionId: String?,
        query: String,
        roomIds: [String]?,
        limitPerRoom: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any] {
        let connection = try requireAction(.searchMessages, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.findRecentMessages(
                query: query,
                channelIds: roomIds,
                limitPerChannel: limitPerRoom,
                maxMatches: maxMatches
            )
            payload["connection_id"] = connection.id
            payload["room_ids"] = roomIds ?? []
            payload["standard_kind"] = "message_search"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func draftMessage(connectionId: String?, roomId: String, content: String) throws -> [String: Any] {
        let connection = try requireAction(.draftMessage, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try discordService.draftMessage(channelId: roomId, content: content)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_draft"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func sendMessage(
        connectionId: String?,
        roomId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.sendMessage, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.sendMessage(
                channelId: roomId,
                content: content,
                confirmSend: confirmSend
            )
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_sent"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func replyThread(
        connectionId: String?,
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.replyThread, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.replyToThread(
                threadId: threadId,
                content: content,
                confirmSend: confirmSend
            )
            payload["connection_id"] = connection.id
            payload["standard_kind"] = "thread_reply_sent"
            return payload
        case .customHTTP:
            throw AgentChannelConnectionServiceError.customExecutionNotImplemented(connection.id)
        case .slack, .telegram:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func authorizeInboundMessage(
        _ request: AgentChannelInboundMessageAuthorizationRequest,
        messageStore: AgentChannelMessageStore? = nil
    ) throws -> AgentChannelInboundAuthorizationDecision {
        let requestedConnectionId = request.connectionId.flatMap(Self.normalizedOptionalId)
        let providerEventId = request.providerEventId.flatMap(Self.normalizedOptionalId)
        let providerMessageId = request.providerMessageId.flatMap(Self.normalizedOptionalId)
        let spaceId = request.spaceId.flatMap(Self.normalizedOptionalId)
        let roomId = Self.normalizedId(request.roomId)
        let senderId = request.senderId.flatMap(Self.normalizedOptionalId)
        guard let requestedConnectionId else {
            return Self.inboundAuthorizationDeny(
                reason: "connection_id_required",
                connectionId: "",
                providerEventId: providerEventId,
                providerMessageId: providerMessageId,
                spaceId: spaceId,
                roomId: roomId,
                senderId: senderId
            )
        }

        let connection: AgentChannelConnection
        do {
            connection = try resolveConnection(requestedConnectionId)
        } catch AgentChannelConnectionServiceError.connectionNotFound(_) {
            return Self.inboundAuthorizationDeny(
                reason: "connection_not_found",
                connectionId: requestedConnectionId,
                providerEventId: providerEventId,
                providerMessageId: providerMessageId,
                spaceId: spaceId,
                roomId: roomId,
                senderId: senderId
            )
        }

        let policy = connection.inboundAuthorization

        func deny(
            _ reason: String,
            decision: AgentChannelInboundAuthorizationDecisionValue = .deny,
            details: [String: String] = [:]
        ) -> AgentChannelInboundAuthorizationDecision {
            AgentChannelInboundAuthorizationDecision(
                decision: decision,
                shouldDispatch: false,
                reason: reason,
                auditDecisionReason: policy.auditDecisionReason,
                connectionId: connection.id,
                providerEventId: providerEventId,
                providerMessageId: providerMessageId,
                spaceId: spaceId,
                roomId: roomId,
                senderId: senderId,
                details: details
            )
        }

        guard connection.enabled else {
            return deny("connection_disabled")
        }
        guard !policy.requireProviderEventId || providerEventId != nil else {
            return deny("provider_event_id_required")
        }
        guard policy.requireProviderEventId || providerMessageId != nil else {
            return deny("provider_message_id_required_for_receive_recording")
        }
        if !connection.spaceAllowlist.isEmpty {
            guard let spaceId, connection.spaceAllowlist.contains(spaceId) else {
                return deny("space_not_allowlisted")
            }
        } else if spaceId != nil, !policy.allowUnscopedSpaces {
            return deny("space_allowlist_required")
        }
        guard !policy.roomAllowlist.isEmpty, policy.roomAllowlist.contains(roomId) else {
            return deny("room_not_allowlisted")
        }
        if request.isSelfMessage, !policy.allowSelfMessages {
            return deny("self_message_denied")
        }
        if request.isBotMessage, !policy.allowBotMessages {
            return deny("bot_message_denied")
        }
        guard let senderId,
              !policy.senderAllowlist.isEmpty,
              policy.senderAllowlist.contains(senderId)
        else {
            return deny("sender_not_allowlisted")
        }
        if policy.requireProviderEventId {
            guard let messageStore else {
                return deny("message_store_required_for_replay_check")
            }
            do {
                if let providerEventId,
                   try messageStore.isEventSeen(connectionId: connection.id, providerEventId: providerEventId) {
                    return deny("duplicate_event_\(policy.duplicateBehavior)", decision: .duplicate)
                }
            } catch {
                return deny(
                    "authorization_store_error",
                    details: ["store_error": error.localizedDescription]
                )
            }
        }

        return AgentChannelInboundAuthorizationDecision(
            decision: .allow,
            shouldDispatch: true,
            reason: "allowed",
            auditDecisionReason: policy.auditDecisionReason,
            connectionId: connection.id,
            providerEventId: providerEventId,
            providerMessageId: providerMessageId,
            spaceId: spaceId,
            roomId: roomId,
            senderId: senderId
        )
    }

    private func requireAction(
        _ action: AgentChannelAction,
        connectionId: String?
    ) throws -> AgentChannelConnection {
        let connection = try resolveConnection(connectionId)
        guard connection.enabled else {
            throw AgentChannelConnectionServiceError.connectionDisabled(connection.id)
        }
        guard connection.supportedActions.contains(action) else {
            throw AgentChannelConnectionServiceError.unsupportedAction(
                action: action,
                connectionId: connection.id
            )
        }
        return connection
    }

    private func resolveConnection(_ connectionId: String?) throws -> AgentChannelConnection {
        let id = AgentChannelConnection.normalizedId(connectionId ?? "")
        let resolvedId = id.isEmpty ? Self.discordConnectionId : id
        if resolvedId.lowercased() == Self.discordConnectionId {
            return discordConnection()
        }
        guard let connection = AgentChannelConfigurationStore.load().connection(id: resolvedId) else {
            throw AgentChannelConnectionServiceError.connectionNotFound(resolvedId)
        }
        return connection
    }

    private func discordConnection() -> AgentChannelConnection {
        let config = discordService.configuration()
        return AgentChannelConnection(
            id: Self.discordConnectionId,
            name: "Discord",
            kind: .discord,
            enabled: true,
            supportedActions: [
                .diagnostics,
                .listSpaces,
                .listRooms,
                .readMessages,
                .searchMessages,
                .draftMessage,
                .sendMessage,
                .replyThread,
            ],
            spaceAllowlist: config.configuredGuildIds,
            readRoomAllowlist: config.readableChannelIds,
            writeRoomAllowlist: config.writableChannelIds,
            writeEnabled: config.writeEnabled,
            defaultReadLimit: config.defaultReadLimit,
            secrets: [
                AgentChannelSecretReference(
                    name: "bot_token",
                    keychainId: DiscordCredentialStore.botTokenKey
                )
            ]
        )
    }

    private func discordConnectionDictionary() -> [String: Any] {
        var row = connectionDictionary(discordConnection())
        row["credential_saved"] = discordService.hasBotToken()
        let readRooms = row["read_room_allowlist"] as? [String] ?? []
        let writeRooms = row["write_room_allowlist"] as? [String] ?? []
        row["configured"] =
            discordService.hasBotToken()
            && (!readRooms.isEmpty || !writeRooms.isEmpty)
        return row
    }

    private func connectionDictionary(_ connection: AgentChannelConnection) -> [String: Any] {
        [
            "id": connection.id,
            "name": connection.name,
            "kind": connection.kind.rawValue,
            "enabled": connection.enabled,
            "standard_actions": connection.supportedActions.map(\.rawValue),
            "space_allowlist": connection.spaceAllowlist,
            "read_room_allowlist": connection.readRoomAllowlist,
            "write_room_allowlist": connection.writeRoomAllowlist,
            "write_enabled": connection.writeEnabled,
            "default_read_limit": connection.defaultReadLimit,
            "secret_names": connection.secrets.map(\.name),
            "custom_http_configured": connection.customHTTP != nil,
            "inbound_authorization": connection.inboundAuthorization.dictionary,
            "action_policies": actionPolicies(for: connection).map(\.dictionary),
            "relay_receive_policy": relayReceivePolicy(for: connection).dictionary,
        ]
    }

    private func actionPolicies(for connection: AgentChannelConnection) -> [AgentChannelActionPolicy] {
        AgentChannelAction.allCases.map { action in
            actionPolicy(for: action, connection: connection)
        }
    }

    private func actionPolicy(
        for action: AgentChannelAction,
        connection: AgentChannelConnection
    ) -> AgentChannelActionPolicy {
        let statusAndReason = actionStatus(for: action, connection: connection)
        return AgentChannelActionPolicy(
            action: action,
            effect: statusAndReason.status == .unsupported ? .unsupportedConfiguredOnly : action.baseEffect,
            status: statusAndReason.status,
            reason: statusAndReason.reason,
            requiresConfirmation: action.requiresSendConfirmation,
            dedupeKey: dedupeKey(for: action),
            idempotencyRequired: action.requiresSendConfirmation,
            constraints: action.providerNeutralConstraints
        )
    }

    private func actionStatus(
        for action: AgentChannelAction,
        connection: AgentChannelConnection
    ) -> (status: AgentChannelActionStatus, reason: String?) {
        guard connection.enabled else {
            return (.disabled, "Connection is disabled.")
        }
        guard connection.supportedActions.contains(action) else {
            return (.unsupported, "Connection does not advertise this standard action.")
        }

        switch connection.kind {
        case .customHTTP:
            return (.configuredOnly, "Custom HTTP action is configured, but execution is not enabled yet.")
        case .slack, .telegram:
            return (.configuredOnly, "Provider adapter is configured, but execution is not implemented yet.")
        case .discord:
            switch action {
            case .diagnostics, .listSpaces:
                return (.available, nil)
            case .listRooms:
                guard !connection.spaceAllowlist.isEmpty else {
                    return (.unavailable, "No spaces are allowlisted for this connection.")
                }
                return (.available, nil)
            case .readMessages, .searchMessages:
                guard !connection.readRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for read access.")
                }
                return (.available, nil)
            case .draftMessage, .sendMessage, .replyThread:
                guard connection.writeEnabled else {
                    return (.unavailable, "Write access is disabled for this connection.")
                }
                guard !connection.writeRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for write access.")
                }
                return (.available, nil)
            }
        }
    }

    private func relayReceivePolicy(for connection: AgentChannelConnection) -> AgentChannelRelayReceivePolicy {
        guard connection.enabled else {
            return AgentChannelRelayReceivePolicy(
                status: .disabled,
                reason: "Connection is disabled.",
                providerEventIdRequired: connection.inboundAuthorization.requireProviderEventId,
                inboundAuthorization: connection.inboundAuthorization
            )
        }
        return AgentChannelRelayReceivePolicy(
            status: .unsupported,
            reason: "No live receive relay is registered for this connection.",
            providerEventIdRequired: connection.inboundAuthorization.requireProviderEventId,
            inboundAuthorization: connection.inboundAuthorization
        )
    }

    private func dedupeKey(for action: AgentChannelAction) -> String? {
        switch action {
        case .readMessages, .searchMessages:
            return "connection_id + room_id + provider_message_id"
        case .sendMessage, .replyThread:
            return "provider_send_id + confirm_send_true"
        case .diagnostics, .listSpaces, .listRooms, .draftMessage:
            return nil
        }
    }

    private static func normalizedId(_ id: String) -> String {
        AgentChannelConnection.normalizedId(id)
    }

    private static func normalizedOptionalId(_ id: String?) -> String? {
        let normalized = AgentChannelConnection.normalizedId(id ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func inboundAuthorizationDeny(
        reason: String,
        connectionId: String,
        providerEventId: String?,
        providerMessageId: String?,
        spaceId: String?,
        roomId: String,
        senderId: String?
    ) -> AgentChannelInboundAuthorizationDecision {
        AgentChannelInboundAuthorizationDecision(
            decision: .deny,
            shouldDispatch: false,
            reason: reason,
            auditDecisionReason: AgentChannelInboundAuthorizationPolicy.defaultAuditDecisionReason,
            connectionId: connectionId,
            providerEventId: providerEventId,
            providerMessageId: providerMessageId,
            spaceId: spaceId,
            roomId: roomId,
            senderId: senderId
        )
    }
}
