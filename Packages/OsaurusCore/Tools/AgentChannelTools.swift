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
        "List configured agent communication channel connections such as Discord, Slack, Telegram, or custom JSON channels."
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
                "description": .string("Channel connection id. Defaults to `discord` when omitted."),
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
