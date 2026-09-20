//
//  MailService.swift
//  osaurus
//
//  Apple Mail access over AppleScript. Fixes carried over from the plugin
//  port: dates come back in local time WITH the local offset (the plugin
//  emitted a local wall-clock string suffixed "Z"), `mailbox_path` values
//  round-trip between `mail_mailboxes`, `mail_list`, `mail_read` and
//  `mail_move`, date filters use component-built dates (locale-safe), and a
//  small LRU maps RFC Message-IDs to Mail's internal ids so follow-up calls
//  do not rescan the mailbox.
//
//  Mailbox paths are `Account/Mailbox[/Sub…]`; the two special values
//  `INBOX` (unified inbox) and `Account/INBOX` are accepted too.
//

import AppKit
import Foundation

struct MailboxInfo: Codable, Sendable, Equatable {
    let path: String
    let name: String
    let account: String
    let unreadCount: Int
    let messageCount: Int
}

struct MailMessageSummary: Codable, Sendable, Equatable {
    /// RFC Message-ID (globally unique). Pass back as `id`.
    let id: String
    let subject: String
    let sender: String
    let dateReceived: String?
    let dateSent: String?
    let isRead: Bool
    let isFlagged: Bool
    let mailboxPath: String
}

struct MailAttachmentInfo: Codable, Sendable, Equatable {
    let name: String
    let sizeBytes: Int?
    let mimeType: String?
}

struct MailMessageContent: Codable, Sendable, Equatable {
    let id: String
    let subject: String
    let sender: String
    let to: [String]
    let cc: [String]
    let replyTo: String?
    let dateReceived: String?
    let dateSent: String?
    let isRead: Bool
    let isFlagged: Bool
    let isJunk: Bool
    let mailboxPath: String
    let content: String
    let attachments: [MailAttachmentInfo]
}

struct MailQuery: Sendable, Equatable {
    var mailboxPath: String?
    var unreadOnly: Bool = false
    var since: Date?
    var limit: Int = 25
}

struct MailSearchQuery: Sendable, Equatable {
    enum Field: String, Sendable { case any, subject, sender, recipient }
    var text: String
    var field: Field = .any
    var mailboxPath: String?
    var limit: Int = 25
}

struct MailDraft: Sendable, Equatable {
    var to: [String]
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String
    var body: String
    var send: Bool = false
}

struct MailStatusPatch: Sendable, Equatable {
    var read: Bool?
    var flagged: Bool?
    var junk: Bool?
}

protocol MailServicing: Sendable {
    func mailboxes() async throws -> [MailboxInfo]
    func list(_ query: MailQuery) async throws -> [MailMessageSummary]
    func search(_ query: MailSearchQuery) async throws -> [MailMessageSummary]
    func read(id: String, mailboxPath: String?) async throws -> MailMessageContent
    /// Returns the outgoing message's subject + recipients; `sent` tells
    /// whether it went out or sits in a compose window / Drafts.
    func compose(_ draft: MailDraft) async throws -> (sent: Bool, subject: String)
    func reply(id: String, mailboxPath: String?, body: String, replyAll: Bool, send: Bool) async throws -> (
        sent: Bool, subject: String
    )
    func move(id: String, mailboxPath: String?, to destinationPath: String) async throws -> MailMessageSummary
    func setStatus(id: String, mailboxPath: String?, patch: MailStatusPatch) async throws -> MailMessageSummary
    func thread(id: String, mailboxPath: String?, limit: Int) async throws -> [MailMessageSummary]
}

final class AppleScriptMailService: MailServicing, @unchecked Sendable {
    static let bundleIdentifier = "com.apple.mail"
    static let appName = "Mail"

    /// RFC Message-ID → (mailbox path, Mail internal id). Bounded LRU.
    private let cacheLock = NSLock()
    private var cache: [String: (path: String, internalId: Int)] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity = 512

    private func remember(_ messageId: String, path: String, internalId: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache[messageId] == nil {
            cacheOrder.append(messageId)
            if cacheOrder.count > cacheCapacity {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[messageId] = (path, internalId)
    }

    private func cached(_ messageId: String) -> (path: String, internalId: Int)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[messageId]
    }

    private func forget(_ messageId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: messageId)
        cacheOrder.removeAll { $0 == messageId }
    }

    // MARK: Script plumbing

    private func run(_ body: String, timeout: TimeInterval = AppleScriptBridge.defaultTimeout) async throws -> String {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: Self.bundleIdentifier, appName: Self.appName) else {
            throw AppleToolError.unavailable("Mail could not be launched on this Mac.", retryable: true)
        }
        let source = """
            \(AppleScriptBridge.separatorPrelude)
            \(AppleScriptBridge.isoDateHandler)
            \(AppleScriptBridge.makeDateHandler)
            \(Self.helperHandlers)
            \(body)
            """
        return try await AppleScriptBridge.run(source, permission: .automationMail, appName: Self.appName, timeout: timeout)
    }

    /// Shared handlers: mailbox path rendering + one-row message encoding.
    private static let helperHandlers = """
        on mailboxPath(mb)
            using terms from application "Mail"
                set parts to {}
                set cur to mb
                repeat 12 times
                    try
                        set beginning of parts to (name of cur)
                        set cur to container of cur
                        if class of cur is account then
                            set beginning of parts to (name of cur)
                            exit repeat
                        end if
                    on error
                        exit repeat
                    end try
                end repeat
                set AppleScript's text item delimiters to "/"
                set p to parts as text
                set AppleScript's text item delimiters to ""
                return p
            end using terms from
        end mailboxPath
        on encodeMessage(msg, FS)
            using terms from application "Mail"
                set msgIdText to ""
                try
                    set msgIdText to message id of msg
                end try
                set subjectText to ""
                try
                    set subjectText to subject of msg
                end try
                set senderText to ""
                try
                    set senderText to sender of msg
                end try
                set readText to "false"
                try
                    set readText to (read status of msg) as string
                end try
                set flagText to "false"
                try
                    set flagText to (flagged status of msg) as string
                end try
                set dateRecvText to ""
                try
                    set dateRecvText to my isoDate(date received of msg)
                end try
                set dateSentText to ""
                try
                    set dateSentText to my isoDate(date sent of msg)
                end try
                set mboxPathText to ""
                try
                    set mboxPathText to my mailboxPath(mailbox of msg)
                end try
                return msgIdText & FS & subjectText & FS & senderText & FS & dateRecvText & FS & dateSentText & FS & readText & FS & flagText & FS & mboxPathText & FS & ((id of msg) as string)
            end using terms from
        end encodeMessage
        """

    /// AppleScript reference expression for a mailbox path.
    static func mailboxReference(_ path: String) throws -> String {
        let parts = path.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw AppleToolError.invalidArgs("`mailbox_path` must not be empty.", field: "mailbox_path")
        }
        if parts.count == 1 {
            switch parts[0].uppercased() {
            case "INBOX": return "inbox"
            case "DRAFTS": return "drafts mailbox"
            case "SENT": return "sent mailbox"
            case "TRASH": return "trash mailbox"
            case "JUNK": return "junk mailbox"
            default:
                throw AppleToolError.invalidArgs(
                    "`mailbox_path` must be `Account/Mailbox[/Sub]` or one of INBOX, Drafts, Sent, Trash, Junk. Got `\(path)`.",
                    field: "mailbox_path", expected: "Account/Mailbox from mail_mailboxes"
                )
            }
        }
        var ref = "account \(AppleScriptBridge.literal(parts[0]))"
        for name in parts.dropFirst() {
            ref = "mailbox \(AppleScriptBridge.literal(name)) of \(ref)"
        }
        return ref
    }

    private static func decodeRows(_ out: String) -> [(summary: MailMessageSummary, internalId: Int)] {
        AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 9 else { return nil }
            let summary = MailMessageSummary(
                id: r[0], subject: r[1], sender: r[2],
                dateReceived: AppleScriptBridge.isoOutput(r[3]), dateSent: AppleScriptBridge.isoOutput(r[4]),
                isRead: AppleScriptBridge.bool(r[5]), isFlagged: AppleScriptBridge.bool(r[6]),
                mailboxPath: r[7]
            )
            return (summary, Int(r[8]) ?? 0)
        }
    }

    private func decodeAndRemember(_ out: String) -> [MailMessageSummary] {
        Self.decodeRows(out).map { row in
            if !row.summary.id.isEmpty { remember(row.summary.id, path: row.summary.mailboxPath, internalId: row.internalId) }
            return row.summary
        }
    }

    // MARK: Message resolution

    /// AppleScript that binds `msg` to the message with RFC id `messageId`.
    /// Cached internal id first (O(1)), then a `whose` scan of the given or
    /// cached mailbox, then the unified inbox.
    private func resolveScript(messageId: String, mailboxPath: String?) throws -> String {
        let lit = AppleScriptBridge.literal(messageId)
        var candidates: [String] = []
        if let hit = cached(messageId) {
            candidates.append(
                "try\n set msg to message id \(hit.internalId) of (\(try Self.mailboxReference(hit.path)))\n if message id of msg is not \(lit) then set msg to missing value\n end try"
            )
        }
        if let mailboxPath, !mailboxPath.isEmpty {
            candidates.append(
                "if msg is missing value then\n try\n set msg to first message of (\(try Self.mailboxReference(mailboxPath))) whose message id is \(lit)\n end try\n end if"
            )
        }
        if let hit = cached(messageId) {
            candidates.append(
                "if msg is missing value then\n try\n set msg to first message of (\(try Self.mailboxReference(hit.path))) whose message id is \(lit)\n end try\n end if"
            )
        }
        candidates.append("if msg is missing value then\n try\n set msg to first message of inbox whose message id is \(lit)\n end try\n end if")
        return "set msg to missing value\n" + candidates.joined(separator: "\n")
            + "\nif msg is missing value then error \"No message with id \" & \(lit) number -1728"
    }

    private func notFound(_ id: String, _ mailboxPath: String?) -> AppleToolError {
        .notFound(
            "No message with id `\(id)`\(mailboxPath.map { " in `\($0)`" } ?? " in the inbox"). Pass the `mailbox_path` returned by mail_list / mail_search, or search again."
        )
    }

    // MARK: MailServicing

    func mailboxes() async throws -> [MailboxInfo] {
        let out = try await run(
            """
            tell application "Mail"
                set rows to {}
                repeat with acct in accounts
                    set acctName to name of acct
                    repeat with mb in mailboxes of acct
                        set end of rows to my encodeMailbox(mb, acctName, FS)
                        try
                            repeat with sub in mailboxes of mb
                                set end of rows to my encodeMailbox(sub, acctName, FS)
                            end repeat
                        end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            on encodeMailbox(mb, acctName, FS)
                using terms from application "Mail"
                    set unreadCountValue to 0
                    set messageCountValue to 0
                    try
                        set unreadCountValue to unread count of mb
                    end try
                    try
                        set messageCountValue to count of messages of mb
                    end try
                    return my mailboxPath(mb) & FS & (name of mb) & FS & acctName & FS & (unreadCountValue as string) & FS & (messageCountValue as string)
                end using terms from
            end encodeMailbox
            """,
            timeout: 120
        )
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 5 else { return nil }
            return MailboxInfo(path: r[0], name: r[1], account: r[2], unreadCount: Int(r[3]) ?? 0, messageCount: Int(r[4]) ?? 0)
        }
    }

    func list(_ query: MailQuery) async throws -> [MailMessageSummary] {
        let ref = try Self.mailboxReference(query.mailboxPath ?? "INBOX")
        var conditions: [String] = []
        if query.unreadOnly { conditions.append("read status is false") }
        if let since = query.since { conditions.append("date received > \(AppleScriptBridge.dateExpression(since))") }
        let selector = conditions.isEmpty ? "messages of (\(ref))" : "(messages of (\(ref)) whose \(conditions.joined(separator: " and ")))"
        let out = try await run(
            """
            tell application "Mail"
                set msgs to \(selector)
                set rows to {}
                set n to 0
                repeat with msg in msgs
                    set end of rows to my encodeMessage(msg, FS)
                    set n to n + 1
                    if n ≥ \(query.limit) then exit repeat
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """,
            timeout: 120
        )
        return decodeAndRemember(out)
    }

    func search(_ query: MailSearchQuery) async throws -> [MailMessageSummary] {
        let ref = try Self.mailboxReference(query.mailboxPath ?? "INBOX")
        let lit = AppleScriptBridge.literal(query.text)
        let clause: String
        switch query.field {
        case .subject: clause = "subject contains \(lit)"
        case .sender: clause = "sender contains \(lit)"
        case .recipient: clause = "(address of to recipients contains \(lit))"
        case .any: clause = "(subject contains \(lit) or sender contains \(lit))"
        }
        let out = try await run(
            """
            tell application "Mail"
                set msgs to (messages of (\(ref)) whose \(clause))
                set rows to {}
                set n to 0
                repeat with msg in msgs
                    set end of rows to my encodeMessage(msg, FS)
                    set n to n + 1
                    if n ≥ \(query.limit) then exit repeat
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """,
            timeout: 120
        )
        return decodeAndRemember(out)
    }

    func read(id: String, mailboxPath: String?) async throws -> MailMessageContent {
        let out: String
        do {
            out = try await run(
                """
                tell application "Mail"
                    \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                    set header to my encodeMessage(msg, FS)
                    set toList to {}
                    try
                        repeat with r in to recipients of msg
                            set end of toList to (address of r)
                        end repeat
                    end try
                    set ccList to {}
                    try
                        repeat with r in cc recipients of msg
                            set end of ccList to (address of r)
                        end repeat
                    end try
                    set replyToText to ""
                    try
                        set replyToText to reply to of msg
                    end try
                    set junkText to "false"
                    try
                        set junkText to (junk mail status of msg) as string
                    end try
                    set attList to {}
                    try
                        repeat with a in mail attachments of msg
                            set sizeText to ""
                            try
                                set sizeText to (file size of a) as string
                            end try
                            set mimeText to ""
                            try
                                set mimeText to MIME type of a
                            end try
                            set end of attList to (name of a) & "|" & sizeText & "|" & mimeText
                        end repeat
                    end try
                    set AppleScript's text item delimiters to ","
                    set toText to toList as text
                    set ccText to ccList as text
                    set AppleScript's text item delimiters to (character id 29)
                    set attText to attList as text
                    set AppleScript's text item delimiters to ""
                    set body to ""
                    try
                        set body to content of msg
                    end try
                    return header & RS & toText & FS & ccText & FS & replyToText & FS & junkText & FS & attText & RS & body
                end tell
                """,
                timeout: 90
            )
        } catch let error as AppleToolError {
            if case .notFound = error {
                forget(id)
                throw notFound(id, mailboxPath)
            }
            throw error
        }
        let sections = out.split(separator: AppleScriptBridge.recordSeparator, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard sections.count >= 2, let row = Self.decodeRows(sections[0]).first else {
            throw notFound(id, mailboxPath)
        }
        remember(row.summary.id, path: row.summary.mailboxPath, internalId: row.internalId)
        let meta = sections[1].split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        let body = sections.count > 2 ? sections[2] : ""
        let split: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let attachments: [MailAttachmentInfo] = (meta.count > 4 ? meta[4] : "")
            .split(separator: "\u{1D}", omittingEmptySubsequences: true)
            .map { raw in
                let p = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return MailAttachmentInfo(
                    name: p.first ?? "", sizeBytes: p.count > 1 ? Int(p[1]) : nil,
                    mimeType: p.count > 2 && !p[2].isEmpty ? p[2] : nil
                )
            }
        let s = row.summary
        return MailMessageContent(
            id: s.id, subject: s.subject, sender: s.sender,
            to: split(meta.first ?? ""), cc: split(meta.count > 1 ? meta[1] : ""),
            replyTo: meta.count > 2 && !meta[2].isEmpty ? meta[2] : nil,
            dateReceived: s.dateReceived, dateSent: s.dateSent, isRead: s.isRead, isFlagged: s.isFlagged,
            isJunk: meta.count > 3 ? AppleScriptBridge.bool(meta[3]) : false,
            mailboxPath: s.mailboxPath, content: body, attachments: attachments
        )
    }

    func compose(_ draft: MailDraft) async throws -> (sent: Bool, subject: String) {
        func recipients(_ kind: String, _ list: [String]) -> String {
            list.map { "make new \(kind) at end of \(kind)s with properties {address:\(AppleScriptBridge.literal($0))}" }
                .joined(separator: "\n")
        }
        // A draft stays visible in a compose window inside Mail (no
        // `activate`, so focus does not move); a send closes it.
        let out = try await run(
            """
            tell application "Mail"
                set newMsg to make new outgoing message with properties {subject:\(AppleScriptBridge.literal(draft.subject)), content:\(AppleScriptBridge.literal(draft.body)), visible:\(draft.send ? "false" : "true")}
                tell newMsg
                    \(recipients("to recipient", draft.to))
                    \(recipients("cc recipient", draft.cc))
                    \(recipients("bcc recipient", draft.bcc))
                end tell
                \(draft.send ? "send newMsg\nreturn \"sent\"" : "return \"draft\"")
            end tell
            """
        )
        return (out.trimmingCharacters(in: .whitespacesAndNewlines) == "sent", draft.subject)
    }

    func reply(id: String, mailboxPath: String?, body: String, replyAll: Bool, send: Bool) async throws -> (
        sent: Bool, subject: String
    ) {
        var flags: [String] = []
        if replyAll { flags.append("reply to all") }
        if !send { flags.append("opening window") }
        let flagClause = flags.isEmpty ? "" : "with " + flags.joined(separator: " and ")
        let out = try await run(
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                set r to reply msg \(flagClause)
                set content of r to \(AppleScriptBridge.literal(body + "\n\n")) & (content of r)
                \(send ? "send r\nreturn \"sent\" & FS & (subject of r)" : "return \"draft\" & FS & (subject of r)")
            end tell
            """
        )
        let parts = out.split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        return (parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "sent", parts.count > 1 ? parts[1] : "")
    }

    func move(id: String, mailboxPath: String?, to destinationPath: String) async throws -> MailMessageSummary {
        let dest = try Self.mailboxReference(destinationPath)
        let out = try await run(
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                set mailbox of msg to (\(dest))
                delay 0.3
                set moved to first message of (\(dest)) whose message id is \(AppleScriptBridge.literal(id))
                return my encodeMessage(moved, FS)
            end tell
            """
        )
        forget(id)
        guard let summary = decodeAndRemember(out).first else { throw notFound(id, mailboxPath) }
        return summary
    }

    func setStatus(id: String, mailboxPath: String?, patch: MailStatusPatch) async throws -> MailMessageSummary {
        var sets: [String] = []
        if let r = patch.read { sets.append("set read status of msg to \(r)") }
        if let f = patch.flagged { sets.append("set flagged status of msg to \(f)") }
        if let j = patch.junk { sets.append("set junk mail status of msg to \(j)") }
        let out = try await run(
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                \(sets.joined(separator: "\n"))
                return my encodeMessage(msg, FS)
            end tell
            """
        )
        guard let summary = decodeAndRemember(out).first else { throw notFound(id, mailboxPath) }
        return summary
    }

    func thread(id: String, mailboxPath: String?, limit: Int) async throws -> [MailMessageSummary] {
        let root = try await read(id: id, mailboxPath: mailboxPath)
        let normalized = Self.normalizedSubject(root.subject)
        guard !normalized.isEmpty else { return [MailMessageSummary(from: root)] }
        let ref = try Self.mailboxReference(root.mailboxPath)
        let out = try await run(
            """
            tell application "Mail"
                set msgs to (messages of (\(ref)) whose subject contains \(AppleScriptBridge.literal(normalized)))
                set rows to {}
                set n to 0
                repeat with msg in msgs
                    set end of rows to my encodeMessage(msg, FS)
                    set n to n + 1
                    if n ≥ \(max(limit, 1) * 3) then exit repeat
                end repeat
                set AppleScript's text item delimiters to RS
                return rows as text
            end tell
            """,
            timeout: 120
        )
        let rows = decodeAndRemember(out).filter { Self.normalizedSubject($0.subject) == normalized }
        return Array(rows.sorted { ($0.dateReceived ?? "") < ($1.dateReceived ?? "") }.prefix(limit))
    }

    /// Strip Re:/Fwd:/Fw:/AW: prefixes for thread grouping.
    static func normalizedSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try? NSRegularExpression(pattern: "^(?:(?:re|fwd?|aw|wg|sv|vs)\\s*:\\s*)+", options: [.caseInsensitive])
        if let pattern {
            let range = NSRange(s.startIndex..., in: s)
            s = pattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension MailMessageSummary {
    init(from content: MailMessageContent) {
        self.init(
            id: content.id, subject: content.subject, sender: content.sender, dateReceived: content.dateReceived,
            dateSent: content.dateSent, isRead: content.isRead, isFlagged: content.isFlagged,
            mailboxPath: content.mailboxPath
        )
    }
}
