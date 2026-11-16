//
//  MessagesTools.swift
//  osaurus
//
//  `messages_*` tools. Reads need only Full Disk Access; `messages_send`
//  needs Automation for Messages and asks for approval by default.
//

import Foundation

enum MessagesToolFactory {
    static func makeTools(service: MessagesServicing = ChatDBMessagesService()) -> [OsaurusTool] {
        [
            MessagesConversationsTool(service: service),
            MessagesReadTool(service: service),
            MessagesUnreadTool(service: service),
            MessagesSearchTool(service: service),
            MessagesSendTool(service: service),
        ]
    }
}

final class MessagesConversationsTool: AppleToolBase, @unchecked Sendable {
    private let service: MessagesServicing
    init(service: MessagesServicing) {
        self.service = service
        super.init(
            app: .messages, name: "messages_conversations",
            description: "List recent Messages conversations (most recent first) with participants, unread count, and last message preview. Use the returned `id` with messages_read or messages_send.",
            parameters: AppleSchema.object(["limit": AppleSchema.limit(default: 25, max: 200)]),
            isWrite: false, requirements: [.disk]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let limit = try AppleArgs.limit(args, default: 25, max: 200)
        let items = try await service.conversations(limit: limit)
        return AppleToolPayload(["conversations": items, "count": items.count])
    }
}

final class MessagesReadTool: AppleToolBase, @unchecked Sendable {
    private let service: MessagesServicing
    init(service: MessagesServicing) {
        self.service = service
        super.init(
            app: .messages, name: "messages_read",
            description: "Read messages from one conversation (by `chat_id` from messages_conversations) or with one person (`handle`: phone number or email). Oldest first within the page. Omit both for the most recent messages across all chats.",
            parameters: AppleSchema.object([
                "chat_id": AppleSchema.string("Conversation id (chat GUID or chat identifier)."),
                "handle": AppleSchema.string("Phone number or email of the other person."),
                "since": AppleSchema.date("Only messages after this time."),
                "limit": AppleSchema.limit(default: 25, max: 500),
            ]),
            isWrite: false, requirements: [.disk]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        var query = MessagesReadQuery()
        query.chatId = try AppleArgs.string(args, "chat_id")
        query.handle = try AppleArgs.string(args, "handle")
        query.since = try AppleArgs.date(args, "since")?.date
        query.limit = try AppleArgs.limit(args, default: 25, max: 500)
        let items = try await service.read(query)
        return AppleToolPayload(["messages": items, "count": items.count])
    }
}

final class MessagesUnreadTool: AppleToolBase, @unchecked Sendable {
    private let service: MessagesServicing
    init(service: MessagesServicing) {
        self.service = service
        super.init(
            app: .messages, name: "messages_unread",
            description: "List unread incoming messages across all conversations, newest first.",
            parameters: AppleSchema.object(["limit": AppleSchema.limit(default: 25, max: 200)]),
            isWrite: false, requirements: [.disk]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let limit = try AppleArgs.limit(args, default: 25, max: 200)
        let items = try await service.unread(limit: limit)
        return AppleToolPayload(["messages": items, "count": items.count])
    }
}

final class MessagesSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: MessagesServicing
    init(service: MessagesServicing) {
        self.service = service
        super.init(
            app: .messages, name: "messages_search",
            description: "Search message text across all conversations (case-insensitive substring), newest first.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("Text to look for."),
                    "limit": AppleSchema.limit(default: 25, max: 200),
                ],
                required: ["query"]
            ),
            isWrite: false, requirements: [.disk]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.requiredString(args, "query", expected: "search text")
        let limit = try AppleArgs.limit(args, default: 25, max: 200)
        let items = try await service.search(query, limit: limit)
        return AppleToolPayload(["messages": items, "count": items.count, "query": query])
    }
}

/// Sending an iMessage/SMS as the user is per-call approval only: a run
/// lease or "Always Allow" taken for another Messages write must never cover
/// an outgoing message, and the guidance promises the user every send pauses.
final class MessagesSendTool: AppleToolBase, PerCallApprovalTool, @unchecked Sendable {
    private let service: MessagesServicing
    init(service: MessagesServicing) {
        self.service = service
        super.init(
            app: .messages, name: "messages_send",
            description: "Send a message. Provide `to` (phone number or email; iMessage first, SMS fallback only when iMessage reports an error) or `chat_id` for an existing conversation or group. Confirm the recipient and text with the user before sending; never resend when `delivered` is null.",
            parameters: AppleSchema.object(
                [
                    "to": AppleSchema.string("Recipient phone number (E.164 preferred) or email."),
                    "chat_id": AppleSchema.string("Existing conversation id from messages_conversations (use for groups)."),
                    "text": AppleSchema.string("Message body."),
                    "service": AppleSchema.string("auto (default), imessage, or sms.", enum: MessagesSendService.allCases.map(\.rawValue)),
                ],
                required: ["text"]
            ),
            isWrite: true, requirements: [.automationMessages]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let text = try AppleArgs.requiredString(args, "text", expected: "the message body")
        let to = try AppleArgs.string(args, "to")
        let chatId = try AppleArgs.string(args, "chat_id")
        guard (to?.isEmpty == false) || (chatId?.isEmpty == false) else {
            throw AppleToolError.invalidArgs("Provide `to` or `chat_id`.", field: "to", expected: "a phone number, email, or chat id")
        }
        let serviceRaw = try AppleArgs.enumeration(args, "service", allowed: MessagesSendService.allCases.map(\.rawValue), default: "auto") ?? "auto"
        let sendService = MessagesSendService(rawValue: serviceRaw) ?? .auto
        let result = try await service.send(to: to, chatId: chatId, text: text, service: sendService)
        var payload: [String: Any] = ["sent": true, "service": result.service, "target": result.target, "text": text]
        var warnings: [String] = []
        if let delivered = result.delivered {
            payload["delivered"] = delivered
            if !delivered { warnings.append("Messages stored the message with a send error; it may not have reached the recipient.") }
        } else {
            payload["delivered"] = NSNull()
            warnings.append("Delivery could not be verified (Messages database not readable or no confirmation yet). Do not resend blindly.")
        }
        return AppleToolPayload(payload, warnings: warnings)
    }
}
