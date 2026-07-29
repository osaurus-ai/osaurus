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
    case globalWritesDisabled(generation: Int)
    case unsupportedKind(AgentChannelKind)
    case unsupportedAction(action: AgentChannelAction, connectionId: String)
    case customExecutionNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let connectionId):
            return L("Agent channel connection `\(connectionId)` is not configured.")
        case .connectionDisabled(let connectionId):
            return L("Agent channel connection `\(connectionId)` is disabled.")
        case .globalWritesDisabled(let generation):
            return L("Global Agent Channel writes are disabled by the write kill switch (generation \(generation)).")
        case .unsupportedKind(let kind):
            return L("Agent channel kind `\(kind.rawValue)` is not executable yet.")
        case .unsupportedAction(let action, let connectionId):
            return L("Agent channel connection `\(connectionId)` does not support `\(action.rawValue)`.")
        case .customExecutionNotImplemented(let connectionId):
            return L("Custom JSON channel `\(connectionId)` is configured, but custom HTTP execution is not enabled yet.")
        }
    }
}

final class AgentChannelConnectionService: @unchecked Sendable {
    static let shared = AgentChannelConnectionService(
        discordService: .shared,
        slackService: .shared,
        telegramService: .shared,
        imessageService: .shared
    )

    private static let discordConnectionId = AgentChannelConnection.nativeDiscordConnectionId
    private static let slackConnectionId = AgentChannelConnection.nativeSlackConnectionId
    private static let telegramConnectionId = AgentChannelConnection.nativeTelegramConnectionId
    private static let imessageConnectionId = AgentChannelConnection.nativeIMessageConnectionId
    private let discordService: DiscordConnectionService
    private let slackService: SlackConnectionService
    private let telegramService: TelegramConnectionService
    private let imessageService: IMessageConnectionService
    private let customJSONRunner: any AgentChannelCustomJSONRunning
    private let writeKillSwitch: ChannelWriteKillSwitch

    init(
        discordService: DiscordConnectionService,
        slackService: SlackConnectionService = .shared,
        telegramService: TelegramConnectionService = .shared,
        imessageService: IMessageConnectionService = .shared,
        customJSONRunner: any AgentChannelCustomJSONRunning = AgentChannelCustomJSONRunner(),
        writeKillSwitch: ChannelWriteKillSwitch = .shared
    ) {
        self.discordService = discordService
        self.slackService = slackService
        self.telegramService = telegramService
        self.imessageService = imessageService
        self.customJSONRunner = customJSONRunner
        self.writeKillSwitch = writeKillSwitch
    }

    func listConnections() -> [[String: Any]] {
        var rows = [
            discordConnectionDictionary(),
            slackConnectionDictionary(),
            telegramConnectionDictionary(),
            imessageConnectionDictionary(),
        ]
        let customRows = AgentChannelConfigurationStore.load().connections
            .filter { connection in
                let id = connection.id.lowercased()
                return id != Self.discordConnectionId
                    && id != Self.slackConnectionId
                    && id != Self.telegramConnectionId
                    && id != Self.imessageConnectionId
            }
            .map(connectionDictionary)
        rows.append(contentsOf: customRows)
        return rows
    }

    func diagnostics(connectionId: String?) async -> [String: Any] {
        do {
            let connection = try resolveConnection(connectionId)
            switch connection.kind {
            case .discord:
                let diagnostics = await discordService.diagnostics()
                var payload = diagnostics.dictionary
                payload["connection_id"] = connection.id
                payload["kind"] = connection.kind.rawValue
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                payload["message_store"] = discordService.messageStoreDiagnostics()
                payload["transport_health"] = await AgentChannelTransportHealthCenter.shared
                    .allStates(connectionId: connection.id)
                    .map(\.dictionary)
                // A token alone is not receive capability: polling only runs
                // once readable channels and authorized senders exist too.
                payload["receive_transport"] = [
                    "status": diagnostics.receiveReady ? "configured" : "not_configured",
                    "transport_id": DiscordPollingTransportRuntime.transportId,
                    "summary": "Discord receive polling starts when a bot token, readable channels, and authorized sender IDs are configured.",
                ]
                return payload
            case .slack:
                var payload = await slackService.diagnostics().dictionary
                payload["connection_id"] = connection.id
                payload["kind"] = connection.kind.rawValue
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                payload["message_store"] = slackService.messageStoreDiagnostics()
                payload["transport_health"] = await AgentChannelTransportHealthCenter.shared
                    .allStates(connectionId: connection.id)
                    .map(\.dictionary)
                payload["receive_transport"] = [
                    "status": slackService.hasAppToken() ? "configured" : "not_configured",
                    "transport_id": SlackSocketModeTransportRuntime.transportId,
                    "summary": "Slack Socket Mode receive starts when an app token, readable channels, and authorized sender IDs are configured.",
                    "app_token_saved": slackService.hasAppToken(),
                ]
                return payload
            case .telegram:
                var payload = await telegramService.diagnostics().dictionary
                payload["connection_id"] = connection.id
                payload["kind"] = connection.kind.rawValue
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                payload["message_store"] = telegramService.messageStoreDiagnostics()
                payload["transport_health"] = await AgentChannelTransportHealthCenter.shared
                    .allStates(connectionId: connection.id)
                    .map(\.dictionary)
                return payload
            case .imessage:
                let diagnostics = await imessageService.diagnostics()
                var payload = diagnostics.dictionary
                payload["connection_id"] = connection.id
                payload["kind"] = connection.kind.rawValue
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                payload["message_store"] = imessageService.messageStoreDiagnostics()
                payload["transport_health"] = await AgentChannelTransportHealthCenter.shared
                    .allStates(connectionId: connection.id)
                    .map(\.dictionary)
                payload["receive_transport"] = [
                    "status": diagnostics.receiveReady ? "configured" : "not_configured",
                    "transport_id": IMessageWatchTransportRuntime.transportId,
                    "summary": "The iMessage receive stream starts when the imsg helper is verified, Full Disk Access is granted, and readable chats plus authorized senders are configured.",
                ]
                return payload
            case .customHTTP:
                var payload = await customJSONRunner.diagnostics(connection: connection)
                payload["standard_actions"] = connection.supportedActions.map(\.rawValue)
                payload["custom_actions"] = connection.customHTTP?.actions.keys.sorted() ?? []
                payload["action_policies"] = actionPolicies(for: connection).map(\.dictionary)
                payload["relay_receive_policy"] = relayReceivePolicy(for: connection).dictionary
                return payload
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
        case .slack:
            return try await slackService.listWorkspaces().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": "workspace",
                    "connection_id": connection.id,
                    "raw": row,
                ]
            }
        case .telegram:
            return telegramService.listSpaces().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": row["kind"] ?? "messaging_network",
                    "connection_id": connection.id,
                    "raw": row,
                ]
            }
        case .imessage:
            return imessageService.listSpaces().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": row["kind"] ?? "messaging_network",
                    "connection_id": connection.id,
                    "raw": row,
                ]
            }
        case .customHTTP:
            return try await customJSONRunner.listSpaces(connection: connection)
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
        case .slack:
            return try await slackService.listChannels(teamId: spaceId).map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    // Slack's real conversation type (channel / private_channel /
                    // im / mpim) so pickers and rows can label DMs as DMs.
                    "kind": row["type"] ?? "room",
                    "space_id": spaceId,
                    "connection_id": connection.id,
                    "read_allowed": row["read_allowed"] ?? false,
                    "write_allowed": row["write_allowed"] ?? false,
                    "raw": row,
                ]
            }
        case .telegram:
            return try await telegramService.listChats().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    // Telegram's chat type (private / group / supergroup /
                    // channel) when known, else the generic kind.
                    "kind": row["type"] ?? row["kind"] ?? "chat",
                    "space_id": spaceId,
                    "connection_id": connection.id,
                    "read_allowed": row["read_allowed"] ?? false,
                    "write_allowed": row["write_allowed"] ?? false,
                    "raw": row,
                ]
            }
        case .imessage:
            return try await imessageService.listChats().map { row in
                [
                    "id": row["id"] ?? "",
                    "name": row["name"] ?? "",
                    "kind": row["kind"] ?? "chat",
                    "space_id": spaceId,
                    "connection_id": connection.id,
                    "read_allowed": row["read_allowed"] ?? false,
                    "write_allowed": row["write_allowed"] ?? false,
                    "raw": row,
                ]
            }
        case .customHTTP:
            return try await customJSONRunner.listRooms(connection: connection, spaceId: spaceId)
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
        case .slack:
            var payload = try await slackService.readChannel(channelId: roomId, limit: limit)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "channel_messages"
            return payload
        case .telegram:
            var payload = try telegramService.readChat(TelegramReadRequest(chatId: roomId, limit: limit))
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "chat_messages"
            return payload
        case .imessage:
            var payload = try imessageService.readChat(chatId: roomId, limit: limit)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "chat_messages"
            return payload
        case .customHTTP:
            return try await customJSONRunner.readMessages(connection: connection, roomId: roomId, limit: limit)
        }
    }

    func readThread(connectionId: String?, threadId: String, limit: Int?) async throws -> [String: Any] {
        let connection = try requireAction(.readThread, connectionId: connectionId)
        switch connection.kind {
        case .discord:
            var payload = try await discordService.readThread(threadId: threadId, limit: limit)
            payload["connection_id"] = connection.id
            payload["thread_id"] = threadId
            payload["standard_kind"] = "thread_messages"
            return payload
        case .slack:
            var payload = try await slackService.readThread(threadId: threadId, limit: limit)
            payload["connection_id"] = connection.id
            payload["standard_kind"] = "thread_messages"
            return payload
        case .customHTTP:
            return try await customJSONRunner.readThread(connection: connection, threadId: threadId, limit: limit)
        case .telegram, .imessage:
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
        case .slack:
            var payload = try await slackService.findRecentMessages(
                query: query,
                channelIds: roomIds,
                limitPerChannel: limitPerRoom,
                maxMatches: maxMatches
            )
            payload["connection_id"] = connection.id
            payload["room_ids"] = roomIds ?? []
            payload["standard_kind"] = "message_search"
            return payload
        case .telegram:
            var payload = try telegramService.searchMessages(
                query: query,
                chatIds: roomIds,
                limitPerChat: limitPerRoom,
                maxMatches: maxMatches
            )
            payload["connection_id"] = connection.id
            payload["room_ids"] = roomIds ?? []
            payload["standard_kind"] = "message_search"
            return payload
        case .imessage:
            var payload = try imessageService.searchMessages(
                query: query,
                chatIds: roomIds,
                limitPerChat: limitPerRoom,
                maxMatches: maxMatches
            )
            payload["connection_id"] = connection.id
            payload["room_ids"] = roomIds ?? []
            payload["standard_kind"] = "message_search"
            return payload
        case .customHTTP:
            return try await customJSONRunner.searchMessages(
                connection: connection,
                query: query,
                roomIds: roomIds,
                limitPerRoom: limitPerRoom,
                maxMatches: maxMatches
            )
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
        case .slack:
            var payload = try slackService.draftMessage(channelId: roomId, content: content)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_draft"
            return payload
        case .telegram:
            var payload = try telegramService.draftMessage(chatId: roomId, content: content)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_draft"
            return payload
        case .imessage:
            var payload = try imessageService.draftMessage(chatId: roomId, content: content)
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_draft"
            return payload
        case .customHTTP:
            return try customJSONRunner.draftMessage(connection: connection, roomId: roomId, content: content)
        }
    }

    func sendMessage(
        connectionId: String?,
        roomId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.sendMessage, connectionId: connectionId)
        try requireGlobalWritesEnabled()
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
        case .slack:
            var payload = try await slackService.sendMessage(
                channelId: roomId,
                content: content,
                confirmSend: confirmSend
            )
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_sent"
            return payload
        case .telegram:
            var payload = try await telegramService.sendMessage(
                TelegramWriteRequest(
                    chatId: roomId,
                    text: content,
                    replyToMessageId: nil,
                    confirmSend: confirmSend
                )
            )
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_sent"
            return payload
        case .imessage:
            var payload = try await imessageService.sendMessage(
                chatId: roomId,
                content: content,
                confirmSend: confirmSend
            )
            payload["connection_id"] = connection.id
            payload["room_id"] = roomId
            payload["standard_kind"] = "message_sent"
            return payload
        case .customHTTP:
            return try await customJSONRunner.sendMessage(
                connection: connection,
                roomId: roomId,
                content: content,
                confirmSend: confirmSend
            )
        }
    }

    func replyThread(
        connectionId: String?,
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.replyThread, connectionId: connectionId)
        try requireGlobalWritesEnabled()
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
        case .slack:
            var payload = try await slackService.replyToThread(
                threadId: threadId,
                content: content,
                confirmSend: confirmSend
            )
            payload["connection_id"] = connection.id
            payload["standard_kind"] = "thread_reply_sent"
            return payload
        case .customHTTP:
            return try await customJSONRunner.replyThread(
                connection: connection,
                threadId: threadId,
                content: content,
                confirmSend: confirmSend
            )
        case .telegram, .imessage:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
    }

    func editMessage(
        connectionId: String?,
        roomId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.editMessage, connectionId: connectionId)
        try requireGlobalWritesEnabled()
        var payload: [String: Any]
        switch connection.kind {
        case .discord:
            payload = try await discordService.editMessage(
                channelId: roomId,
                messageId: messageId,
                content: content,
                confirmSend: confirmSend
            )
        case .slack:
            payload = try await slackService.editMessage(
                channelId: roomId,
                messageId: messageId,
                content: content,
                confirmSend: confirmSend
            )
        case .telegram:
            payload = try await telegramService.editMessage(
                chatId: roomId,
                messageId: messageId,
                content: content,
                confirmSend: confirmSend
            )
        case .imessage:
            // Advanced private-API action: gated inside the service on the
            // per-action enablement AND a live bridge capability probe.
            payload = try await imessageService.editMessage(
                chatId: roomId,
                messageId: messageId,
                content: content,
                confirmSend: confirmSend
            )
        case .customHTTP:
            payload = try await customJSONRunner.editMessage(
                connection: connection,
                roomId: roomId,
                messageId: messageId,
                content: content,
                confirmSend: confirmSend
            )
        }
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        payload["standard_kind"] = "message_edited"
        return payload
    }

    func deleteMessage(
        connectionId: String?,
        roomId: String,
        messageId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.deleteMessage, connectionId: connectionId)
        try requireGlobalWritesEnabled()
        var payload: [String: Any]
        switch connection.kind {
        case .discord:
            payload = try await discordService.deleteMessage(
                channelId: roomId,
                messageId: messageId,
                confirmSend: confirmSend
            )
        case .slack:
            payload = try await slackService.deleteMessage(
                channelId: roomId,
                messageId: messageId,
                confirmSend: confirmSend
            )
        case .telegram:
            payload = try await telegramService.deleteMessage(
                chatId: roomId,
                messageId: messageId,
                confirmSend: confirmSend
            )
        case .imessage:
            // iMessage "delete" is unsend — an advanced private-API action.
            payload = try await imessageService.unsendMessage(
                chatId: roomId,
                messageId: messageId,
                confirmSend: confirmSend
            )
        case .customHTTP:
            payload = try await customJSONRunner.deleteMessage(
                connection: connection,
                roomId: roomId,
                messageId: messageId,
                confirmSend: confirmSend
            )
        }
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        payload["standard_kind"] = "message_deleted"
        return payload
    }

    func setReaction(
        connectionId: String?,
        roomId: String,
        messageId: String,
        reaction: String,
        adding: Bool,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let action: AgentChannelAction = adding ? .addReaction : .removeReaction
        let connection = try requireAction(action, connectionId: connectionId)
        try requireGlobalWritesEnabled()
        var payload: [String: Any]
        switch connection.kind {
        case .discord:
            payload = try await discordService.setReaction(
                channelId: roomId,
                messageId: messageId,
                reaction: reaction,
                adding: adding,
                confirmSend: confirmSend
            )
        case .slack:
            payload = try await slackService.setReaction(
                channelId: roomId,
                messageId: messageId,
                reaction: reaction,
                adding: adding,
                confirmSend: confirmSend
            )
        case .telegram:
            payload = try await telegramService.setReaction(
                chatId: roomId,
                messageId: messageId,
                reaction: reaction,
                adding: adding,
                confirmSend: confirmSend
            )
        case .imessage:
            // iMessage reactions are tapbacks — an advanced private-API action.
            payload = try await imessageService.setTapback(
                chatId: roomId,
                messageId: messageId,
                reaction: reaction,
                adding: adding,
                confirmSend: confirmSend
            )
        case .customHTTP:
            payload = try await customJSONRunner.setReaction(
                connection: connection,
                roomId: roomId,
                messageId: messageId,
                reaction: reaction,
                adding: adding,
                confirmSend: confirmSend
            )
        }
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        payload["standard_kind"] = adding ? "reaction_added" : "reaction_removed"
        return payload
    }

    func sendTyping(
        connectionId: String?,
        roomId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireAction(.sendTyping, connectionId: connectionId)
        try requireGlobalWritesEnabled()
        var payload: [String: Any]
        switch connection.kind {
        case .discord:
            payload = try await discordService.sendTyping(
                channelId: roomId,
                confirmSend: confirmSend
            )
        case .telegram:
            payload = try await telegramService.sendTyping(
                chatId: roomId,
                confirmSend: confirmSend
            )
        case .imessage:
            payload = try await imessageService.sendTyping(
                chatId: roomId,
                confirmSend: confirmSend
            )
        case .customHTTP:
            payload = try await customJSONRunner.sendTyping(
                connection: connection,
                roomId: roomId,
                confirmSend: confirmSend
            )
        case .slack:
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        payload["standard_kind"] = "typing_sent"
        return payload
    }

    // MARK: - iMessage-only advanced actions (private API)
    //
    // These have no provider-neutral standard action; they exist only for the
    // native iMessage connection. Routing them through this dispatcher keeps
    // the global write kill switch and connection resolution in one place;
    // per-action enablement, confirmation, allowlists, and the live bridge
    // capability probe are enforced inside IMessageConnectionService.

    func imessageSendAttachment(
        connectionId: String?,
        roomId: String,
        path: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireIMessageConnection(connectionId)
        try requireGlobalWritesEnabled()
        var payload = try await imessageService.sendAttachment(
            chatId: roomId,
            path: path,
            confirmSend: confirmSend
        )
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        return payload
    }

    func imessageSendEffect(
        connectionId: String?,
        roomId: String,
        content: String,
        effect: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireIMessageConnection(connectionId)
        try requireGlobalWritesEnabled()
        var payload = try await imessageService.sendEffect(
            chatId: roomId,
            content: content,
            effect: effect,
            confirmSend: confirmSend
        )
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        return payload
    }

    func imessageCreatePoll(
        connectionId: String?,
        roomId: String,
        question: String,
        options: [String],
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireIMessageConnection(connectionId)
        try requireGlobalWritesEnabled()
        var payload = try await imessageService.createPoll(
            chatId: roomId,
            question: question,
            options: options,
            confirmSend: confirmSend
        )
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        return payload
    }

    func imessageManageGroup(
        connectionId: String?,
        roomId: String,
        operation: IMessageConnectionService.GroupOperation,
        value: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let connection = try requireIMessageConnection(connectionId)
        try requireGlobalWritesEnabled()
        var payload = try await imessageService.manageGroup(
            chatId: roomId,
            operation: operation,
            value: value,
            confirmSend: confirmSend
        )
        payload["connection_id"] = connection.id
        payload["room_id"] = roomId
        return payload
    }

    /// Resolve the connection and require it to be the native iMessage one.
    /// A nil/empty connection id defaults to iMessage here (unlike standard
    /// actions, which default to Discord) because these tools are
    /// iMessage-specific by name.
    private func requireIMessageConnection(_ connectionId: String?) throws -> AgentChannelConnection {
        let normalized = Self.normalizedId(connectionId ?? "")
        let resolved = normalized.isEmpty ? Self.imessageConnectionId : normalized
        let connection = try resolveConnection(resolved)
        guard connection.kind == .imessage else {
            throw AgentChannelConnectionServiceError.unsupportedKind(connection.kind)
        }
        return connection
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

    /// Resolved read-only view of a connection id (native projection or
    /// custom JSON row). Used by the proactive publish path to re-validate
    /// a binding's destination without duplicating the projection logic.
    func resolvedConnectionView(id: String) throws -> AgentChannelConnection {
        try resolveConnection(id)
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

    private func requireGlobalWritesEnabled() throws {
        let snapshot = writeKillSwitch.snapshot()
        guard snapshot.writeEnabled else {
            throw AgentChannelConnectionServiceError.globalWritesDisabled(generation: snapshot.generation)
        }
    }

    private func resolveConnection(_ connectionId: String?) throws -> AgentChannelConnection {
        let id = AgentChannelConnection.normalizedId(connectionId ?? "")
        let resolvedId = id.isEmpty ? Self.discordConnectionId : id
        if resolvedId.lowercased() == Self.discordConnectionId {
            return discordConnection()
        }
        if resolvedId.lowercased() == Self.slackConnectionId {
            return slackConnection()
        }
        if resolvedId.lowercased() == Self.telegramConnectionId {
            return telegramConnection()
        }
        if resolvedId.lowercased() == Self.imessageConnectionId {
            return imessageConnection()
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
                .readThread,
                .searchMessages,
                .draftMessage,
                .sendMessage,
                .replyThread,
                .editMessage,
                .deleteMessage,
                .addReaction,
                .removeReaction,
                .sendTyping,
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
            ],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: config.senderAllowlist,
                roomAllowlist: config.readableChannelIds,
                allowUnscopedSpaces: false,
                allowBotMessages: false,
                allowSelfMessages: false,
                requireProviderEventId: true,
                auditDecisionReason: "discord_receive_authorization"
            )
        )
    }

    private func slackConnection() -> AgentChannelConnection {
        let config = slackService.configuration()
        let workspaceTeamIds = config.workspaceAccounts.map(\.teamId)
        let workspaceReadRooms = config.workspaceAccounts.flatMap(\.readableChannelIds)
        let workspaceWriteRooms = config.workspaceAccounts.flatMap(\.writableChannelIds)
        let workspaceSenders = config.workspaceAccounts.flatMap(\.senderAllowlist)
        return AgentChannelConnection(
            id: Self.slackConnectionId,
            name: "Slack",
            kind: .slack,
            enabled: true,
            supportedActions: [
                .diagnostics,
                .listSpaces,
                .listRooms,
                .readMessages,
                .readThread,
                .searchMessages,
                .draftMessage,
                .sendMessage,
                .replyThread,
                .editMessage,
                .deleteMessage,
                .addReaction,
                .removeReaction,
            ],
            spaceAllowlist: config.configuredTeamIds + workspaceTeamIds,
            readRoomAllowlist: config.readableChannelIds + workspaceReadRooms,
            writeRoomAllowlist: config.writableChannelIds + workspaceWriteRooms,
            writeEnabled: config.writeEnabled,
            defaultReadLimit: config.defaultReadLimit,
            secrets: [
                AgentChannelSecretReference(
                    name: "bot_token",
                    keychainId: SlackCredentialStore.botTokenKey
                ),
                AgentChannelSecretReference(
                    name: "signing_secret",
                    keychainId: SlackCredentialStore.signingSecretKey
                ),
                AgentChannelSecretReference(
                    name: "app_token",
                    keychainId: SlackCredentialStore.appTokenKey
                ),
            ],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: config.senderAllowlist + workspaceSenders,
                roomAllowlist: config.readableChannelIds + workspaceReadRooms,
                allowUnscopedSpaces: config.configuredTeamIds.isEmpty,
                allowBotMessages: false,
                allowSelfMessages: false,
                requireProviderEventId: true,
                auditDecisionReason: "slack_receive_authorization"
            )
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

    private func slackConnectionDictionary() -> [String: Any] {
        var row = connectionDictionary(slackConnection())
        row["credential_saved"] = slackService.hasBotToken()
        row["bot_token_saved"] = slackService.hasBotToken()
        row["signing_secret_saved"] = slackService.hasSigningSecret()
        row["app_token_saved"] = slackService.hasAppToken()
        row["sender_allowlist"] = slackService.configuration().senderAllowlist
        let readRooms = row["read_room_allowlist"] as? [String] ?? []
        let writeRooms = row["write_room_allowlist"] as? [String] ?? []
        row["configured"] = slackService.hasBotToken()
            && (!readRooms.isEmpty || !writeRooms.isEmpty)
        return row
    }

    private func telegramConnection() -> AgentChannelConnection {
        let config = telegramService.configuration()
        return AgentChannelConnection(
            id: Self.telegramConnectionId,
            name: "Telegram",
            kind: .telegram,
            enabled: true,
            supportedActions: [
                .diagnostics,
                .listSpaces,
                .listRooms,
                .readMessages,
                .searchMessages,
                .draftMessage,
                .sendMessage,
                .editMessage,
                .deleteMessage,
                .addReaction,
                .removeReaction,
                .sendTyping,
            ],
            spaceAllowlist: ["telegram"],
            readRoomAllowlist: config.readableChatIds,
            writeRoomAllowlist: config.writableChatIds,
            writeEnabled: config.writeEnabled,
            defaultReadLimit: config.defaultReadLimit,
            secrets: [
                AgentChannelSecretReference(
                    name: "bot_token",
                    keychainId: TelegramCredentialStore.botTokenKey
                )
            ],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: config.senderAllowlist,
                roomAllowlist: config.readableChatIds,
                allowUnscopedSpaces: false,
                allowBotMessages: !config.ignoreBotMessages,
                allowSelfMessages: !config.ignoreSelfMessages,
                requireProviderEventId: true,
                auditDecisionReason: "telegram_receive_authorization"
            )
        )
    }

    private func telegramConnectionDictionary() -> [String: Any] {
        var row = connectionDictionary(telegramConnection())
        row["credential_saved"] = telegramService.hasBotToken()
        let readRooms = row["read_room_allowlist"] as? [String] ?? []
        let writeRooms = row["write_room_allowlist"] as? [String] ?? []
        row["configured"] =
            telegramService.hasBotToken()
            && (!readRooms.isEmpty || !writeRooms.isEmpty)
        return row
    }

    private func imessageConnection() -> AgentChannelConnection {
        let config = imessageService.configuration()
        return AgentChannelConnection(
            id: Self.imessageConnectionId,
            name: "iMessage",
            kind: .imessage,
            enabled: true,
            supportedActions: [
                .diagnostics,
                .listSpaces,
                .listRooms,
                .readMessages,
                .searchMessages,
                .draftMessage,
                .sendMessage,
                // Standard mutations map onto the advanced private-API
                // actions (edit, unsend, tapback, typing); each is further
                // gated inside IMessageConnectionService on per-action
                // enablement and a live bridge capability probe.
                .editMessage,
                .deleteMessage,
                .addReaction,
                .removeReaction,
                .sendTyping,
            ],
            spaceAllowlist: [IMessageConnectionService.spaceId],
            readRoomAllowlist: config.readableChatIds,
            writeRoomAllowlist: config.writableChatIds,
            writeEnabled: config.writeEnabled,
            defaultReadLimit: config.defaultReadLimit,
            // The local helper needs no remote credential; trust is anchored
            // in the pinned, digest-verified bundled executable instead.
            secrets: [],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: config.senderAllowlist,
                roomAllowlist: config.readableChatIds,
                allowUnscopedSpaces: false,
                allowBotMessages: false,
                // Operator-controlled: turning Ignore Self Messages off lets
                // messages sent from this Mac's own account dispatch, which
                // is the only way to test the loop from a single machine.
                allowSelfMessages: !config.ignoreSelfMessages,
                requireProviderEventId: true,
                auditDecisionReason: "imessage_receive_authorization"
            )
        )
    }

    private func imessageConnectionDictionary() -> [String: Any] {
        var row = connectionDictionary(imessageConnection())
        // No remote credential: the "credential" is the verified local helper.
        row["credential_saved"] = imessageService.helperAvailable()
        row["helper_available"] = imessageService.helperAvailable()
        let readRooms = row["read_room_allowlist"] as? [String] ?? []
        let writeRooms = row["write_room_allowlist"] as? [String] ?? []
        row["configured"] =
            imessageService.helperAvailable()
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
            guard let customHTTP = connection.customHTTP else {
                return (.unavailable, "Custom HTTP configuration is missing.")
            }
            guard action == .diagnostics || customHTTP.actions[action.rawValue] != nil else {
                return (.unavailable, "No custom HTTP mapping is configured for this action.")
            }
            switch action {
            case .diagnostics:
                return (.available, nil)
            case .listSpaces:
                return (.available, nil)
            case .listRooms:
                guard !connection.spaceAllowlist.isEmpty else {
                    return (.unavailable, "No spaces are allowlisted for this connection.")
                }
                return (.available, nil)
            case .readMessages, .readThread, .searchMessages:
                guard !connection.readRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for read access.")
                }
                return (.available, nil)
            case .draftMessage, .sendMessage, .replyThread, .editMessage, .deleteMessage,
                .addReaction, .removeReaction, .sendTyping:
                guard connection.writeEnabled else {
                    return (.unavailable, "Write access is disabled for this connection.")
                }
                guard !connection.writeRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for write access.")
                }
                guard action == .draftMessage || writeKillSwitch.snapshot().writeEnabled else {
                    return (.unavailable, "Global Agent Channel writes are disabled.")
                }
                return (.available, nil)
            }
        case .discord, .slack, .telegram, .imessage:
            switch action {
            case .diagnostics, .listSpaces:
                return (.available, nil)
            case .listRooms:
                guard !connection.spaceAllowlist.isEmpty else {
                    return (.unavailable, "No spaces are allowlisted for this connection.")
                }
                return (.available, nil)
            case .readMessages, .readThread, .searchMessages:
                guard !connection.readRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for read access.")
                }
                return (.available, nil)
            case .draftMessage, .sendMessage, .replyThread, .editMessage, .deleteMessage,
                .addReaction, .removeReaction, .sendTyping:
                guard connection.writeEnabled else {
                    return (.unavailable, "Write access is disabled for this connection.")
                }
                guard !connection.writeRoomAllowlist.isEmpty else {
                    return (.unavailable, "No rooms are allowlisted for write access.")
                }
                guard action == .draftMessage || writeKillSwitch.snapshot().writeEnabled else {
                    return (.unavailable, "Global Agent Channel writes are disabled.")
                }
                if connection.kind == .imessage,
                    let gate = imessageAdvancedActionGate(for: action)
                {
                    return gate
                }
                return (.available, nil)
            }
        }
    }

    /// iMessage maps several standard mutations onto private-API bridge
    /// actions. Advertise them as available only when the operator's master
    /// toggle is on, the specific action is individually enabled, AND the
    /// last capability probe saw an active bridge — otherwise agents would
    /// plan around actions that are guaranteed to fail at execution time.
    /// Returns nil for basic actions that need no advanced gate.
    private func imessageAdvancedActionGate(
        for action: AgentChannelAction
    ) -> (status: AgentChannelActionStatus, reason: String?)? {
        let advanced: IMessageConnectionConfiguration.AdvancedAction
        switch action {
        case .editMessage: advanced = .edit
        case .deleteMessage: advanced = .unsend
        case .addReaction, .removeReaction: advanced = .tapback
        case .sendTyping: advanced = .typing
        case .replyThread: advanced = .reply
        default: return nil
        }
        let config = imessageService.configuration()
        guard config.advancedActionsEnabled else {
            return (.unavailable, "Advanced iMessage actions are disabled (master toggle in iMessage settings).")
        }
        guard config.enabledAdvancedActions.contains(advanced) else {
            return (.unavailable, "The \(advanced.rawValue) advanced action is not enabled in iMessage settings.")
        }
        guard imessageService.lastKnownBridgeAvailable() else {
            return (
                .unavailable,
                "The iMessage private-API bridge is not active (requires SIP and Library Validation disabled by the operator)."
            )
        }
        return nil
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
        let dispatch: AgentChannelInboundDispatchConfiguration?
        switch connection.kind {
        case .slack:
            dispatch = slackService.configuration().inboundDispatch
        case .telegram:
            dispatch = telegramService.configuration().inboundDispatch
        case .discord:
            dispatch = discordService.configuration().inboundDispatch
        case .imessage:
            dispatch = imessageService.configuration().inboundDispatch
        case .customHTTP:
            dispatch = nil
        }
        if let dispatch, dispatch.isConfigured {
            return AgentChannelRelayReceivePolicy(
                status: .available,
                reason: dispatch.autoReplyEnabled
                    ? "Verified inbound messages dispatch to the selected agent and replies use existing write allowlists."
                    : "Verified inbound messages dispatch to the selected agent; automatic provider replies are disabled.",
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
        case .readMessages, .readThread, .searchMessages:
            return "connection_id + room_id + provider_message_id"
        case .sendMessage, .replyThread, .editMessage, .deleteMessage, .addReaction, .removeReaction:
            return "provider_send_id + confirm_send_true"
        case .sendTyping:
            return "connection_id + room_id + short_time_window"
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
