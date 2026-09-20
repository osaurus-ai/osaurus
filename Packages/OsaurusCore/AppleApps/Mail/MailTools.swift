//
//  MailTools.swift
//  osaurus
//
//  Built-in `mail_*` tools (per-agent opt-in via `AppleApp.mail`).
//

import Foundation

enum MailToolFactory {
    static func makeTools(service: MailServicing = AppleScriptMailService()) -> [OsaurusTool] {
        [
            MailMailboxesTool(service: service),
            MailListTool(service: service),
            MailReadTool(service: service),
            MailSearchTool(service: service),
            MailComposeTool(service: service),
            MailReplyTool(service: service),
            MailMoveTool(service: service),
            MailSetStatusTool(service: service),
            MailThreadTool(service: service),
        ]
    }

    static let mailboxPathSchema = AppleSchema.string(
        "Mailbox path exactly as returned by mail_mailboxes (`Account/Mailbox[/Sub]`), or INBOX / Drafts / Sent / Trash / Junk. Defaults to the unified INBOX."
    )
    static let idSchema = AppleSchema.string("Message `id` from mail_list / mail_search / mail_read.")

    static func addresses(_ args: [String: Any], _ key: String) throws -> [String] {
        if let list = try AppleArgs.stringArray(args, key) { return list }
        return []
    }
}

final class MailMailboxesTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_mailboxes",
            description: "List every account's mailboxes with unread and total counts. The `path` values are what mail_list / mail_move / mail_read accept as `mailbox_path`.",
            parameters: AppleSchema.object([:]), isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let boxes = try await service.mailboxes()
        return AppleToolPayload(["mailboxes": boxes, "count": boxes.count])
    }
}

final class MailListTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    static let defaultLimit = 20
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_list",
            description: "List recent messages (newest first) in a mailbox — headers only: id, subject, sender, dates, read/flagged. Use mail_read for the body.",
            parameters: AppleSchema.object([
                "mailbox_path": MailToolFactory.mailboxPathSchema,
                "unread_only": AppleSchema.boolean("Only unread messages (default false)."),
                "since": AppleSchema.date("Only messages received after this date/time."),
                "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
            ]),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        var query = MailQuery()
        query.mailboxPath = try AppleArgs.string(args, "mailbox_path")
        query.unreadOnly = try AppleArgs.bool(args, "unread_only") ?? false
        query.since = try AppleArgs.date(args, "since")?.date
        query.limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let messages = try await service.list(query)
        return AppleToolPayload([
            "messages": messages, "count": messages.count, "mailbox_path": query.mailboxPath ?? "INBOX",
            "truncated": messages.count >= query.limit,
        ])
    }
}

final class MailReadTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_read",
            description: "Read one message in full by `id`: recipients, dates, status, plain-text body, attachment names. Pass the `mailbox_path` from the listing so the lookup is exact.",
            parameters: AppleSchema.object(
                ["id": MailToolFactory.idSchema, "mailbox_path": MailToolFactory.mailboxPathSchema],
                required: ["id"]
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a message id")
        let path = try AppleArgs.string(args, "mailbox_path")
        return AppleToolPayload(["message": try await service.read(id: id, mailboxPath: path)])
    }
}

final class MailSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    static let defaultLimit = 20
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_search",
            description: "Search a mailbox by subject and/or sender (case-insensitive substring; message bodies are not searched). Defaults to the unified INBOX.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("Text to match."),
                    "field": AppleSchema.string("Which header to match (default any = subject or sender).", enum: ["any", "subject", "sender", "recipient"]),
                    "mailbox_path": MailToolFactory.mailboxPathSchema,
                    "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
                ],
                required: ["query"]
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let text = try AppleArgs.requiredString(args, "query", expected: "search text")
        let fieldRaw = try AppleArgs.enumeration(args, "field", allowed: ["any", "subject", "sender", "recipient"], default: "any") ?? "any"
        var query = MailSearchQuery(text: text)
        query.field = MailSearchQuery.Field(rawValue: fieldRaw) ?? .any
        query.mailboxPath = try AppleArgs.string(args, "mailbox_path")
        query.limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let messages = try await service.search(query)
        return AppleToolPayload([
            "messages": messages, "count": messages.count, "query": text, "field": fieldRaw,
            "mailbox_path": query.mailboxPath ?? "INBOX", "truncated": messages.count >= query.limit,
        ])
    }
}

final class MailComposeTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_compose",
            description: "Compose a new email. By default it opens as a draft in Mail for the user to review (`send: false`); set `send: true` only after the user confirmed the exact recipients and text.",
            parameters: AppleSchema.object(
                [
                    "to": AppleSchema.stringArray("Recipient email addresses."),
                    "cc": AppleSchema.stringArray("CC addresses."),
                    "bcc": AppleSchema.stringArray("BCC addresses."),
                    "subject": AppleSchema.string("Subject line."),
                    "body": AppleSchema.string("Plain-text body."),
                    "send": AppleSchema.boolean("Send immediately (default false = leave as an open draft)."),
                ],
                required: ["to", "subject", "body"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let to = try MailToolFactory.addresses(args, "to")
        guard !to.isEmpty else {
            throw AppleToolError.invalidArgs("`to` must contain at least one address.", field: "to", expected: "an array of email addresses")
        }
        let draft = MailDraft(
            to: to, cc: try MailToolFactory.addresses(args, "cc"), bcc: try MailToolFactory.addresses(args, "bcc"),
            subject: try AppleArgs.requiredString(args, "subject", expected: "a subject"),
            body: try AppleArgs.string(args, "body") ?? "",
            send: try AppleArgs.bool(args, "send") ?? false
        )
        let result = try await service.compose(draft)
        return AppleToolPayload([
            "sent": result.sent, "draft_open_in_mail": !result.sent, "subject": result.subject,
            "to": draft.to, "cc": draft.cc, "bcc": draft.bcc,
        ])
    }
}

final class MailReplyTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_reply",
            description: "Reply to a message by `id`. Your `body` is placed above the quoted original. Defaults to an open draft (`send: false`); `reply_all` includes every original recipient.",
            parameters: AppleSchema.object(
                [
                    "id": MailToolFactory.idSchema,
                    "mailbox_path": MailToolFactory.mailboxPathSchema,
                    "body": AppleSchema.string("Reply text."),
                    "reply_all": AppleSchema.boolean("Reply to all recipients (default false)."),
                    "send": AppleSchema.boolean("Send immediately (default false = open draft)."),
                ],
                required: ["id", "body"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a message id")
        let path = try AppleArgs.string(args, "mailbox_path")
        let body = try AppleArgs.requiredString(args, "body", expected: "reply text")
        let replyAll = try AppleArgs.bool(args, "reply_all") ?? false
        let send = try AppleArgs.bool(args, "send") ?? false
        let result = try await service.reply(id: id, mailboxPath: path, body: body, replyAll: replyAll, send: send)
        return AppleToolPayload([
            "sent": result.sent, "draft_open_in_mail": !result.sent, "subject": result.subject, "reply_all": replyAll, "id": id,
        ])
    }
}

final class MailMoveTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_move",
            description: "Move a message by `id` to another mailbox (`to_mailbox_path` from mail_mailboxes, or Trash / Junk / Archive-style paths).",
            parameters: AppleSchema.object(
                [
                    "id": MailToolFactory.idSchema,
                    "mailbox_path": MailToolFactory.mailboxPathSchema,
                    "to_mailbox_path": AppleSchema.string("Destination mailbox path (from mail_mailboxes) or Trash / Junk."),
                ],
                required: ["id", "to_mailbox_path"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a message id")
        let path = try AppleArgs.string(args, "mailbox_path")
        let dest = try AppleArgs.requiredString(args, "to_mailbox_path", expected: "a mailbox path")
        let moved = try await service.move(id: id, mailboxPath: path, to: dest)
        return AppleToolPayload(["message": moved, "moved": true, "to_mailbox_path": moved.mailboxPath])
    }
}

final class MailSetStatusTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_set_status",
            description: "Mark a message read/unread, flagged/unflagged, or junk/not junk. Only the flags you pass change.",
            parameters: AppleSchema.object(
                [
                    "id": MailToolFactory.idSchema,
                    "mailbox_path": MailToolFactory.mailboxPathSchema,
                    "read": AppleSchema.boolean("Read status."),
                    "flagged": AppleSchema.boolean("Flagged status."),
                    "junk": AppleSchema.boolean("Junk status."),
                ],
                required: ["id"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a message id")
        let path = try AppleArgs.string(args, "mailbox_path")
        let patch = MailStatusPatch(
            read: try AppleArgs.bool(args, "read"), flagged: try AppleArgs.bool(args, "flagged"), junk: try AppleArgs.bool(args, "junk")
        )
        guard patch.read != nil || patch.flagged != nil || patch.junk != nil else {
            throw AppleToolError.invalidArgs("Pass at least one of `read`, `flagged`, `junk`.")
        }
        let message = try await service.setStatus(id: id, mailboxPath: path, patch: patch)
        return AppleToolPayload(["message": message, "updated": true])
    }
}

final class MailThreadTool: AppleToolBase, @unchecked Sendable {
    private let service: MailServicing
    static let defaultLimit = 20
    init(service: MailServicing) {
        self.service = service
        super.init(
            app: .mail, name: "mail_thread",
            description: "Return the conversation around a message: messages in the same mailbox whose subject matches after stripping Re:/Fwd:, oldest first.",
            parameters: AppleSchema.object(
                [
                    "id": MailToolFactory.idSchema,
                    "mailbox_path": MailToolFactory.mailboxPathSchema,
                    "limit": AppleSchema.limit(default: Self.defaultLimit, max: 100),
                ],
                required: ["id"]
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a message id")
        let path = try AppleArgs.string(args, "mailbox_path")
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 100)
        let messages = try await service.thread(id: id, mailboxPath: path, limit: limit)
        return AppleToolPayload(["messages": messages, "count": messages.count, "root_id": id])
    }
}
