//
//  AgentChannelTools.swift
//  osaurus
//
//  Standard model-facing tools for agent communication channels.
//

import Foundation

private enum AgentChannelToolPolicy {
    static let readRequirements = ["network", "agent_channel.read"]
    static let writeRequirements = ["network", "agent_channel.write"]
    static let defaultPolicy: ToolPermissionPolicy = .ask
}

private protocol AgentChannelServiceTool {
    var service: AgentChannelConnectionService { get }
}

private extension OsaurusTool {
    func agentChannelFailure(_ error: Error, tool: String) -> String {
        if let error = error as? AgentChannelConnectionServiceError {
            switch error {
            case .connectionNotFound, .connectionDisabled:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .globalWritesDisabled, .unsupportedKind, .unsupportedAction, .customExecutionNotImplemented:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? AgentChannelCustomJSONRunnerError {
            let metadata: [String: Any]? = error.partialWriteStatus.map {
                [
                    "partial_write": true,
                    "partial_write_status": $0,
                ]
            }
            switch error {
            case .missingConfiguration, .actionNotConfigured, .methodNotAllowed,
                .blockedURL, .spaceNotAllowlisted, .roomNotReadable, .roomNotWritable,
                .writeDisabled:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false,
                    metadata: metadata
                )
            case .missingSecret:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false,
                    metadata: metadata
                )
            case .invalidRequest, .invalidTemplate, .missingInput,
                .sendConfirmationRequired, .emptyMessage:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false,
                    metadata: metadata
                )
            case .httpStatus, .invalidResponse, .transport, .cancelled:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false,
                    metadata: metadata
                )
            }
        }

        if let error = error as? DiscordConnectionServiceError {
            switch error {
            case .invalidId, .sendConfirmationRequired, .messageTooLong, .emptyMessage:
                return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: tool)
            case .guildNotConfigured, .channelNotReadable, .channelNotWritable, .writeDisabled:
                return ToolEnvelope.failure(kind: .rejected, message: error.localizedDescription, tool: tool)
            case .notConfigured:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .configurationSaveFailed, .api:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? DiscordAPIError {
            switch error {
            case .invalidToken:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .missingPermissions:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .notFound:
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .rateLimited:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true
                )
            case .invalidResponse, .requestFailed:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? SlackConnectionServiceError {
            switch error {
            case .invalidId, .sendConfirmationRequired, .messageTooLong, .emptyMessage, .invalidThreadId:
                return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: tool)
            case .teamNotConfigured, .channelNotReadable, .channelNotWritable, .writeDisabled, .broadcastMentionDenied:
                return ToolEnvelope.failure(kind: .rejected, message: error.localizedDescription, tool: tool)
            case .notConfigured:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .signingSecretNotConfigured:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .signatureVerificationFailed, .invalidInboundPayload:
                return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: tool)
            case .configurationSaveFailed, .api:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? SlackAPIError {
            switch error {
            case .invalidToken:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .missingPermissions:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .notFound:
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .rateLimited:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true
                )
            case .invalidResponse, .requestFailed:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? TelegramConnectionServiceError {
            switch error {
            case .invalidChatId, .sendConfirmationRequired, .messageTooLong, .emptyMessage, .invalidWebhookSecret:
                return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: tool)
            case .chatNotReadable, .chatNotWritable, .writeDisabled:
                return ToolEnvelope.failure(kind: .rejected, message: error.localizedDescription, tool: tool)
            case .sendBackpressure:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true
                )
            case .notConfigured, .messageStoreUnavailable:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .configurationSaveFailed, .api:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? IMessageConnectionServiceError {
            switch error {
            case .invalidChatId, .sendConfirmationRequired, .messageTooLong, .emptyMessage,
                .invalidAdvancedParameter:
                return ToolEnvelope.failure(kind: .invalidArgs, message: error.localizedDescription, tool: tool)
            case .chatNotReadable, .chatNotWritable, .writeDisabled, .advancedActionDisabled,
                .attachmentNotAllowed:
                return ToolEnvelope.failure(kind: .rejected, message: error.localizedDescription, tool: tool)
            case .notConfigured, .messageStoreUnavailable, .advancedActionUnavailable:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .configurationSaveFailed, .helper:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        if let error = error as? TelegramAPIError {
            switch error {
            case .invalidToken:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .forbidden:
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .notFound:
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case .conflict, .rateLimited:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true
                )
            case .invalidResponse, .requestFailed:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            }
        }

        return ToolEnvelope.failure(
            kind: .executionError,
            message: error.localizedDescription,
            tool: tool,
            retryable: false
        )
    }
}

final class AgentChannelListConnectionsTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_list_connections"
    let description =
        "List configured agent communication channel connections such as Discord, Slack, Telegram, iMessage, or custom JSON channels."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        ToolEnvelope.success(tool: name, result: ["connections": service.listConnections()])
    }
}

final class AgentChannelDiagnosticsTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_diagnostics"
    let description = "Check an agent channel connection without exposing secrets."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ])
        ]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        return ToolEnvelope.success(tool: name, result: await service.diagnostics(connectionId: connectionId))
    }
}

final class AgentChannelListSpacesTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_list_spaces"
    let description =
        "List top-level spaces for a channel connection, such as Discord servers, Slack workspaces, or Telegram groups."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ])
        ]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: ["spaces": try await service.listSpaces(connectionId: connectionId)]
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelListRoomsTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_list_rooms"
    let description =
        "List rooms inside a channel space, such as Discord channels, Slack channels, or Telegram topics."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "space_id": .object([
                "type": .string("string"),
                "description": .string("Top-level space id, such as a Discord server id."),
            ]),
        ]),
        "required": .array([.string("space_id")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let spaceReq = requireString(args, "space_id", expected: "channel space id", tool: name)
        guard case .value(let spaceId) = spaceReq else { return spaceReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "space_id": spaceId,
                    "rooms": try await service.listRooms(connectionId: connectionId, spaceId: spaceId),
                ]
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelReadMessagesTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_read_messages"
    let description = "Read recent messages from an allowlisted channel room."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("Room/channel id allowlisted for read access."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Number of recent messages to read, 1-100."),
            ]),
        ]),
        "required": .array([.string("room_id")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.readMessages(
                    connectionId: connectionId,
                    roomId: roomId,
                    limit: coerceInt(args["limit"])
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelReadThreadTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_read_thread"
    let description = "Read recent messages from an allowlisted channel thread."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "thread_id": .object([
                "type": .string("string"),
                "description": .string("Thread id allowlisted for read access."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Number of recent thread messages to read, 1-100."),
            ]),
        ]),
        "required": .array([.string("thread_id")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let threadReq = requireString(args, "thread_id", expected: "channel thread id", tool: name)
        guard case .value(let threadId) = threadReq else { return threadReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.readThread(
                    connectionId: connectionId,
                    threadId: threadId,
                    limit: coerceInt(args["limit"])
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelSearchMessagesTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_search_messages"
    let description = "Search recent messages across allowlisted channel rooms."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("Text to match in recent messages."),
            ]),
            "room_ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Optional allowlisted room/channel ids. Defaults to all readable rooms."),
            ]),
            "limit_per_room": .object([
                "type": .string("integer"),
                "description": .string("Recent messages to scan per room, 1-100."),
            ]),
            "max_matches": .object([
                "type": .string("integer"),
                "description": .string("Maximum matches to return, 1-50."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.readRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let queryReq = requireString(args, "query", expected: "message search text", tool: name)
        guard case .value(let query) = queryReq else { return queryReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.searchMessages(
                    connectionId: connectionId,
                    query: query,
                    roomIds: coerceStringArray(args["room_ids"]),
                    limitPerRoom: coerceInt(args["limit_per_room"]),
                    maxMatches: coerceInt(args["max_matches"])
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelDraftMessageTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_draft_message"
    let description = "Prepare a message for a write-allowlisted channel room without sending it."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("Room/channel id allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to draft."),
            ]),
        ]),
        "required": .array([.string("room_id"), .string("content")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try service.draftMessage(connectionId: connectionId, roomId: roomId, content: content)
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelSendMessageTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_send_message"
    let description =
        "Send a message to a write-allowlisted channel room. Requires `confirm_send: true`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("Room/channel id allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to send."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([.string("room_id"), .string("content"), .string("confirm_send")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.sendMessage(
                    connectionId: connectionId,
                    roomId: roomId,
                    content: content,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelReplyThreadTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_reply_thread"
    let description = "Reply in a write-allowlisted channel thread. Requires `confirm_send: true`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Channel connection id: `discord`, `slack`, `telegram`, `imessage`, or a custom connection id (see agent_channel_list_connections). Defaults to `discord` when omitted."
                ),
            ]),
            "thread_id": .object([
                "type": .string("string"),
                "description": .string("Thread id allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Reply body to send."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([.string("thread_id"), .string("content"), .string("confirm_send")]),
    ])

    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) {
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let threadReq = requireString(args, "thread_id", expected: "channel thread id", tool: name)
        guard case .value(let threadId) = threadReq else { return threadReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "reply body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.replyThread(
                    connectionId: connectionId,
                    threadId: threadId,
                    content: content,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelEditMessageTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_edit_message"
    let description = "Edit a message in a write-allowlisted room. Requires `confirm_send: true`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object(["type": .string("string")]),
            "room_id": .object(["type": .string("string")]),
            "message_id": .object(["type": .string("string")]),
            "content": .object(["type": .string("string")]),
            "confirm_send": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("room_id"), .string("message_id"), .string("content"), .string("confirm_send"),
        ]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let messageReq = requireString(args, "message_id", expected: "provider message id", tool: name)
        guard case .value(let messageId) = messageReq else { return messageReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "replacement message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.editMessage(
                    connectionId: connectionId,
                    roomId: roomId,
                    messageId: messageId,
                    content: content,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelDeleteMessageTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_delete_message"
    let description = "Delete a message in a write-allowlisted room. Requires `confirm_send: true`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object(["type": .string("string")]),
            "room_id": .object(["type": .string("string")]),
            "message_id": .object(["type": .string("string")]),
            "confirm_send": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("room_id"), .string("message_id"), .string("confirm_send")]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let messageReq = requireString(args, "message_id", expected: "provider message id", tool: name)
        guard case .value(let messageId) = messageReq else { return messageReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.deleteMessage(
                    connectionId: connectionId,
                    roomId: roomId,
                    messageId: messageId,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

class AgentChannelReactionTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name: String
    let description: String
    let adding: Bool
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object(["type": .string("string")]),
            "room_id": .object(["type": .string("string")]),
            "message_id": .object(["type": .string("string")]),
            "reaction": .object(["type": .string("string")]),
            "confirm_send": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("room_id"), .string("message_id"), .string("reaction"), .string("confirm_send"),
        ]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(name: String, description: String, adding: Bool, service: AgentChannelConnectionService = .shared) {
        self.name = name
        self.description = description
        self.adding = adding
        self.service = service
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let messageReq = requireString(args, "message_id", expected: "provider message id", tool: name)
        guard case .value(let messageId) = messageReq else { return messageReq.failureEnvelope ?? "" }
        let reactionReq = requireString(args, "reaction", expected: "provider emoji or reaction name", tool: name)
        guard case .value(let reaction) = reactionReq else { return reactionReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.setReaction(
                    connectionId: connectionId,
                    roomId: roomId,
                    messageId: messageId,
                    reaction: reaction,
                    adding: adding,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelAddReactionTool: AgentChannelReactionTool, @unchecked Sendable {
    init(service: AgentChannelConnectionService = .shared) {
        super.init(
            name: "agent_channel_add_reaction",
            description: "Add an emoji reaction to a message in a write-allowlisted room. Requires `confirm_send: true`. `reaction` accepts a Unicode emoji (🎉), a Slack-style alias (`:white_check_mark:`), a Discord custom emoji (`name:id` or `<:name:id>`), a Telegram custom emoji (`custom_emoji:<id>`), or an iMessage tapback kind (love, like, dislike, laugh, emphasize, question); it is normalized to the connection's native format.",
            adding: true,
            service: service
        )
    }
}

final class AgentChannelRemoveReactionTool: AgentChannelReactionTool, @unchecked Sendable {
    init(service: AgentChannelConnectionService = .shared) {
        super.init(
            name: "agent_channel_remove_reaction",
            description: "Remove the bot's own reaction from a message. Requires `confirm_send: true`. `reaction` takes the same forms as `agent_channel_add_reaction`. On Telegram, bots keep a single reaction per message; removal is refused if the bot's current reaction differs from `reaction`.",
            adding: false,
            service: service
        )
    }
}

final class AgentChannelSendTypingTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_send_typing"
    let description = "Send a short typing/progress indicator to a write-allowlisted room."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object(["type": .string("string")]),
            "room_id": .object(["type": .string("string")]),
            "confirm_send": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("room_id"), .string("confirm_send")]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "channel room id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.sendTyping(
                    connectionId: connectionId,
                    roomId: roomId,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

// MARK: - iMessage-only advanced tools (private API)
//
// Narrowly-typed tools for iMessage capabilities that have no
// provider-neutral standard action. Every one requires the operator to have
// enabled the specific advanced action in iMessage settings AND a live
// bridge capability probe to pass, on top of the usual write allowlist,
// `confirm_send`, and the global write kill switch. Because their names are
// in `agentChannelToolNames`, they are automatically denied on external
// HTTP/MCP surfaces.

final class AgentChannelIMessageSendAttachmentTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_imessage_send_attachment"
    let description =
        "iMessage only: send a file attachment to a write-allowlisted chat. Requires "
        + "`confirm_send: true`, the Send Attachments advanced action enabled in iMessage "
        + "settings, an active private-API bridge, and a `path` inside an allowlisted "
        + "attachment root."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("Channel connection id. Defaults to `imessage`."),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("iMessage chat id allowlisted for write access."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("Absolute file path inside an allowlisted attachment root."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([.string("room_id"), .string("path"), .string("confirm_send")]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "iMessage chat id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let pathReq = requireString(args, "path", expected: "attachment file path", tool: name)
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.imessageSendAttachment(
                    connectionId: connectionId,
                    roomId: roomId,
                    path: path,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelIMessageSendEffectTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_imessage_send_effect"
    let description =
        "iMessage only: send a message with a screen or bubble effect (e.g. `confetti`, "
        + "`fireworks`, `slam`, `invisible-ink`) to a write-allowlisted chat. Requires "
        + "`confirm_send: true`, the Message Effects advanced action enabled in iMessage "
        + "settings, and an active private-API bridge."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("Channel connection id. Defaults to `imessage`."),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("iMessage chat id allowlisted for write access."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to send."),
            ]),
            "effect": .object([
                "type": .string("string"),
                "description": .string("Effect name, e.g. `confetti`, `fireworks`, `slam`, `invisible-ink`."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([
            .string("room_id"), .string("content"), .string("effect"), .string("confirm_send"),
        ]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "iMessage chat id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        let effectReq = requireString(args, "effect", expected: "iMessage effect name", tool: name)
        guard case .value(let effect) = effectReq else { return effectReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.imessageSendEffect(
                    connectionId: connectionId,
                    roomId: roomId,
                    content: content,
                    effect: effect,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelIMessageCreatePollTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_imessage_create_poll"
    let description =
        "iMessage only: create a native Apple Messages poll in a write-allowlisted group "
        + "chat. Requires `confirm_send: true`, the Polls advanced action enabled in "
        + "iMessage settings, and an active private-API bridge. Provide 2-12 options."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("Channel connection id. Defaults to `imessage`."),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("iMessage group chat id allowlisted for write access."),
            ]),
            "question": .object([
                "type": .string("string"),
                "description": .string("Poll question."),
            ]),
            "options": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("2-12 poll answer options."),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to send. False or omitted refuses."),
            ]),
        ]),
        "required": .array([
            .string("room_id"), .string("question"), .string("options"), .string("confirm_send"),
        ]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "iMessage chat id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let questionReq = requireString(args, "question", expected: "poll question", tool: name)
        guard case .value(let question) = questionReq else { return questionReq.failureEnvelope ?? "" }
        let optionsReq = requireStringArray(args, "options", expected: "poll options", tool: name)
        guard case .value(let options) = optionsReq else { return optionsReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.imessageCreatePoll(
                    connectionId: connectionId,
                    roomId: roomId,
                    question: question,
                    options: options,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

final class AgentChannelIMessageManageGroupTool: OsaurusTool, PermissionedTool, AgentChannelServiceTool, @unchecked Sendable {
    let name = "agent_channel_imessage_manage_group"
    let description =
        "iMessage only: manage a write-allowlisted group chat. `operation` is `rename` "
        + "(with `value` as the new name), `add_participant`, or `remove_participant` "
        + "(with `value` as the participant handle). Requires `confirm_send: true`, the "
        + "Group Management advanced action enabled in iMessage settings, and an active "
        + "private-API bridge."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("Channel connection id. Defaults to `imessage`."),
            ]),
            "room_id": .object([
                "type": .string("string"),
                "description": .string("iMessage group chat id allowlisted for write access."),
            ]),
            "operation": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("rename"), .string("add_participant"), .string("remove_participant"),
                ]),
                "description": .string("Group operation to perform."),
            ]),
            "value": .object([
                "type": .string("string"),
                "description": .string(
                    "New group name for `rename`, or the participant handle (phone/email) "
                        + "for `add_participant` / `remove_participant`."
                ),
            ]),
            "confirm_send": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to apply. False or omitted refuses."),
            ]),
        ]),
        "required": .array([
            .string("room_id"), .string("operation"), .string("value"), .string("confirm_send"),
        ]),
    ])
    let service: AgentChannelConnectionService
    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    var defaultPermissionPolicy: ToolPermissionPolicy { AgentChannelToolPolicy.defaultPolicy }

    init(service: AgentChannelConnectionService = .shared) { self.service = service }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let connectionReq = optionalString(args, "connection_id", expected: "channel connection id", tool: name)
        guard case .value(let connectionId) = connectionReq else { return connectionReq.failureEnvelope ?? "" }
        let roomReq = requireString(args, "room_id", expected: "iMessage chat id", tool: name)
        guard case .value(let roomId) = roomReq else { return roomReq.failureEnvelope ?? "" }
        let operationReq = requireString(args, "operation", expected: "group operation", tool: name)
        guard case .value(let operationRaw) = operationReq else { return operationReq.failureEnvelope ?? "" }
        guard let operation = IMessageConnectionService.GroupOperation(rawValue: operationRaw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`operation` must be one of: "
                    + IMessageConnectionService.GroupOperation.allCases.map(\.rawValue)
                        .joined(separator: ", "),
                tool: name
            )
        }
        let valueReq = requireString(args, "value", expected: "group name or participant handle", tool: name)
        guard case .value(let value) = valueReq else { return valueReq.failureEnvelope ?? "" }
        do {
            return ToolEnvelope.success(
                tool: name,
                result: try await service.imessageManageGroup(
                    connectionId: connectionId,
                    roomId: roomId,
                    operation: operation,
                    value: value,
                    confirmSend: coerceBool(args["confirm_send"]) ?? false
                )
            )
        } catch {
            return agentChannelFailure(error, tool: name)
        }
    }
}

/// Proactive, binding-scoped publish tool. Unlike `agent_channel_send_message`,
/// the model NEVER supplies a raw connection or room: it references an
/// operator-approved destination binding by id and the host resolves,
/// re-validates, and rate-limits the destination. The binding's outbound
/// mode (`draft` / `confirm` / `autonomous`) decides between recording a
/// local draft, asking for approval (or queuing on unattended runs), and
/// sending directly. All provider writes flow through the durable
/// outbound-intent ledger, so a repeated `intent_key` can never produce a
/// second provider write.
final class AgentChannelPublishTool: OsaurusTool, ContextualPermissionedTool, @unchecked Sendable {
    static let toolName = "agent_channel_publish"

    let name = AgentChannelPublishTool.toolName
    let description =
        "Publish a message to one of this agent's pre-approved channel destinations "
        + "(see the Channel Destinations context). Use a stable `intent_key` per logical "
        + "message; repeating a key never sends twice."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "binding_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Destination binding id from the Channel Destinations context."
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Message body to publish."),
            ]),
            "intent_key": .object([
                "type": .string("string"),
                "description": .string(
                    "Caller-stable idempotency key for this logical message, e.g. "
                        + "`daily-report-2026-07-26`. Reusing a key returns the prior result "
                        + "instead of sending again."
                ),
            ]),
            "thread_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional provider thread inside the destination's room to publish "
                        + "into. Only valid when the destination does not pin a thread "
                        + "itself; the thread must belong to the destination's allowlisted "
                        + "room."
                ),
            ]),
        ]),
        "required": .array([.string("binding_id"), .string("content"), .string("intent_key")]),
    ])

    var requirements: [String] { AgentChannelToolPolicy.writeRequirements }
    /// `.auto` by default: the binding's outbound mode is the real per-
    /// destination policy, resolved argument-aware below. A stricter global
    /// per-tool setting still narrows via strictest-wins in the registry.
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let publishService: AgentChannelPublishService
    private let loadConfiguration: @Sendable () -> AgentChannelConfiguration
    private let configuredUserPolicy: @Sendable () async -> ToolPermissionPolicy?

    init(
        publishService: AgentChannelPublishService = .shared,
        // Stored bindings plus automatic (derived) destinations, so a
        // derived `confirm` binding resolves to `.ask` on attended runs
        // exactly like a stored one.
        loadConfiguration: @escaping @Sendable () -> AgentChannelConfiguration = {
            AgentChannelAutoDestinationResolver.effectiveConfiguration()
        },
        configuredUserPolicy: @escaping @Sendable () async -> ToolPermissionPolicy? = {
            await MainActor.run {
                ToolRegistry.shared.configuredPolicy(for: AgentChannelPublishTool.toolName)
            }
        }
    ) {
        self.publishService = publishService
        self.loadConfiguration = loadConfiguration
        self.configuredUserPolicy = configuredUserPolicy
    }

    /// Argument-aware approval semantics: a `confirm`-mode binding on an
    /// ATTENDED run resolves to `.ask` (interactive approval card before the
    /// send); everything else resolves `.auto` and the tool body / publish
    /// service enforces the full authorization matrix with typed envelopes
    /// (including queuing `confirm` sends on unattended runs — a prompt
    /// nobody can answer must never block a scheduled run).
    func resolveContextualPermissionPolicy(argumentsJSON: String) async -> ToolPermissionPolicy {
        guard
            let data = argumentsJSON.data(using: .utf8),
            let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let bindingId = args["binding_id"] as? String,
            let binding = loadConfiguration().binding(id: bindingId)
        else {
            return .auto
        }
        if binding.outboundMode == .confirm,
            !ChatExecutionContext.isUnattendedDispatch,
            !ChatExecutionContext.isExternalSurface
        {
            return .ask
        }
        return .auto
    }

    /// An unanswerable `.ask` (unattended dispatch + user-configured `.ask`
    /// on this tool) proceeds into the tool body, which queues the message
    /// for operator approval in the channel outbox instead of writing to
    /// the provider (see `requiresOperatorApproval` below).
    func unattendedAskQueuesForApproval(argumentsJSON: String) async -> Bool { true }

    /// Mirror of the registry's effective-policy math for THIS invocation:
    /// when the user configured `.ask` on the publish tool and the run is
    /// unattended with no auto-approve override, no human approved this
    /// send — the publish service must queue it for operator approval even
    /// for an autonomous destination. Attended runs that reach `execute`
    /// already passed the interactive approval card, so they send normally.
    private func requiresOperatorApproval() async -> Bool {
        guard ChatExecutionContext.isUnattendedDispatch,
            !ChatExecutionContext.autoApproveToolPrompts
        else { return false }
        return await configuredUserPolicy() == .ask
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let bindingReq = requireString(args, "binding_id", expected: "destination binding id", tool: name)
        guard case .value(let bindingId) = bindingReq else { return bindingReq.failureEnvelope ?? "" }
        let contentReq = requireString(args, "content", expected: "message body", tool: name)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        let intentKeyReq = requireString(args, "intent_key", expected: "idempotency key", tool: name)
        guard case .value(let intentKey) = intentKeyReq else { return intentKeyReq.failureEnvelope ?? "" }
        let threadId = args["thread_id"] as? String

        let outcome = await publishService.publish(
            AgentChannelPublishRequest(
                bindingId: bindingId,
                content: content,
                intentKey: intentKey,
                threadId: threadId
            ),
            context: .current(requiresOperatorApproval: await requiresOperatorApproval())
        )
        return Self.envelope(for: outcome, bindingId: bindingId, intentKey: intentKey, tool: name)
    }

    static func envelope(
        for outcome: AgentChannelPublishOutcome,
        bindingId: String,
        intentKey: String,
        tool: String
    ) -> String {
        switch outcome {
        case .sent(let intentId, let providerMessageId):
            var result: [String: Any] = [
                "status": "sent",
                "intent_id": intentId,
                "binding_id": bindingId,
                "intent_key": intentKey,
            ]
            if let providerMessageId {
                result["provider_message_id"] = providerMessageId
            }
            return ToolEnvelope.success(tool: tool, result: result)
        case .draftRecorded(let intentId):
            return ToolEnvelope.success(
                tool: tool,
                result: [
                    "status": "draft_recorded",
                    "intent_id": intentId,
                    "binding_id": bindingId,
                    "intent_key": intentKey,
                    "note":
                        "This destination is in draft mode. Nothing was sent; the draft "
                        + "awaits the operator in the channel outbox.",
                ]
            )
        case .queuedForApproval(let intentId):
            return ToolEnvelope.success(
                tool: tool,
                result: [
                    "status": "queued_for_approval",
                    "intent_id": intentId,
                    "binding_id": bindingId,
                    "intent_key": intentKey,
                    "note":
                        "This destination requires confirmation and no user is present. "
                        + "The message awaits operator approval in the channel outbox; "
                        + "do not resend.",
                ]
            )
        case .duplicate(let intentId, let status):
            return ToolEnvelope.success(
                tool: tool,
                result: [
                    "status": "duplicate",
                    "intent_id": intentId,
                    "intent_status": status.rawValue,
                    "binding_id": bindingId,
                    "intent_key": intentKey,
                    "note": "This intent_key was already recorded; nothing new was sent.",
                ]
            )
        case .denied(let code, let message, let retryable):
            let kind: ToolEnvelope.Kind
            switch code {
            case "empty_content", "content_too_long", "missing_intent_key",
                "intent_key_too_long", "thread_conflict":
                kind = .invalidArgs
            case "rate_limited", "provider_error", "ledger_unavailable", "ledger_write_failed",
                "intent_in_flight", "connection_unavailable":
                kind = .unavailable
            case "delivery_unknown":
                // NOT retryable and NOT the caller's fault: the provider did
                // not confirm the write and only the operator may resolve it.
                kind = .executionError
            default:
                kind = .rejected
            }
            return ToolEnvelope.failure(
                kind: kind,
                message: message,
                tool: tool,
                retryable: retryable,
                metadata: ["denial_code": code, "binding_id": bindingId]
            )
        }
    }
}
