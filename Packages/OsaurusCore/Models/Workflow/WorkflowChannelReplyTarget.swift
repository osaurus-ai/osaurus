//
//  WorkflowChannelReplyTarget.swift
//  osaurus
//
//  The conversation a channel-triggered workflow run may talk back to.
//  Stored on the run's caller so a `reply` step, a relayed dialog, or a
//  run picked up after a relaunch can still find the room; the live reply
//  closure itself is held separately (`ChannelReplyRegistry`).
//

import Foundation

public struct WorkflowChannelReplyTarget: Codable, Sendable, Equatable {
    public var connectionId: String
    public var kind: AgentChannelKind
    public var conversationId: String
    public var threadId: String?
    public var replyAddress: String?
    public var senderId: String?
    public var senderName: String?
    /// The room or chat as the platform names it, when known.
    public var displayName: String?

    public init(
        connectionId: String, kind: AgentChannelKind, conversationId: String, threadId: String? = nil,
        replyAddress: String? = nil, senderId: String? = nil, senderName: String? = nil, displayName: String? = nil
    ) {
        self.connectionId = connectionId
        self.kind = kind
        self.conversationId = conversationId
        self.threadId = threadId
        self.replyAddress = replyAddress
        self.senderId = senderId
        self.senderName = senderName
        self.displayName = displayName
    }

    /// The lane key `EventOccurrence.conversationKey` uses for this room.
    public var conversationKey: String {
        [connectionId, conversationId, threadId ?? ""].joined(separator: "|")
    }

    /// The `{{caller.channel}}` value steps read.
    public var bindingValue: JSONValue {
        var fields: [String: JSONValue] = [
            "platform": .string(kind.rawValue),
            "connection_id": .string(connectionId),
            "room_id": .string(conversationId),
            "thread_id": threadId.map(JSONValue.string) ?? .null,
            "sender_id": senderId.map(JSONValue.string) ?? .null,
            "sender_name": senderName.map(JSONValue.string) ?? .null,
        ]
        if let displayName { fields["room_name"] = .string(displayName) }
        return .object(fields)
    }

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case kind
        case conversationId = "conversation_id"
        case threadId = "thread_id"
        case replyAddress = "reply_address"
        case senderId = "sender_id"
        case senderName = "sender_name"
        case displayName = "display_name"
    }
}
