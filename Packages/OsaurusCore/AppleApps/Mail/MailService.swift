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
//  Mailbox paths are `Account/Mailbox[/Sub…]`; "On My Mac" mailboxes use the
//  pseudo-account `Local`. The special single-segment values `INBOX`,
//  `Drafts`, `Sent`, `Trash`, `Junk` address the unified mailboxes, and
//  `Account/INBOX` is accepted too. A `/` inside a mailbox name is escaped
//  as `\/` in every path this service emits or accepts.
//
//  Scripting notes that shaped this file:
//    - `message id <int>` is NOT a by-id specifier in Mail: `message id` is
//      the RFC Message-ID *property*, so that form does not compile. The
//      internal id is addressed with `first message of <mailbox> whose id is
//      <int>`.
//    - `header`, `sender`, `subject`, `content`, `id`, `name` are Mail
//      terminology and cannot be used as script variables.
//    - Mail does not guarantee the order of `messages of <mailbox>`; every
//      listing compares the first/last `date received` to pick the recent
//      end and Swift sorts newest-first.
//

import AppKit
import Foundation

struct MailboxInfo: Codable, Sendable, Equatable {
    let path: String
    let name: String
    let account: String
    let unreadCount: Int
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
    enum Field: String, Sendable { case any, subject, sender }
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

// MARK: - Mailbox paths

/// Pure helpers for the `Account/Mailbox[/Sub]` path syntax (testable
/// without Mail).
enum MailboxPath {
    /// Pseudo-account used for "On My Mac" mailboxes.
    static let localAccount = "Local"

    /// Split a path on unescaped `/`, unescaping `\/` inside segments.
    static func segments(_ path: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for ch in path {
            if escaping {
                if ch != "/" { current.append("\\") }
                current.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "/" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaping { current.append("\\") }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Escape `/` in one segment.
    static func escape(_ segment: String) -> String {
        segment.replacingOccurrences(of: "/", with: "\\/")
    }

    /// Join segments back into a path.
    static func join(_ segments: [String]) -> String {
        segments.map(escape).joined(separator: "/")
    }

    /// The unified special mailboxes addressable by a single segment.
    static let unifiedNames: [String: String] = [
        "INBOX": "inbox", "DRAFTS": "drafts mailbox", "SENT": "sent mailbox", "TRASH": "trash mailbox",
        "JUNK": "junk mailbox", "OUTBOX": "outbox",
    ]

    /// AppleScript reference expression for a mailbox path.
    static func reference(_ path: String) throws -> String {
        let parts = segments(path)
        guard !parts.isEmpty else {
            throw AppleToolError.invalidArgs("`mailbox_path` must not be empty.", field: "mailbox_path")
        }
        if parts.count == 1 {
            if let unified = unifiedNames[parts[0].uppercased()] { return unified }
            throw AppleToolError.invalidArgs(
                "`mailbox_path` must be `Account/Mailbox[/Sub]` (or `Local/Mailbox` for On My Mac) or one of INBOX, Drafts, Sent, Trash, Junk. Got `\(path)`.",
                field: "mailbox_path", expected: "Account/Mailbox from mail_mailboxes"
            )
        }
        var ref: String
        let names = Array(parts.dropFirst())
        if parts[0].caseInsensitiveCompare(localAccount) == .orderedSame {
            ref = "mailbox \(AppleScriptBridge.literal(names[0]))"
        } else {
            ref = "mailbox \(AppleScriptBridge.literal(names[0])) of account \(AppleScriptBridge.literal(parts[0]))"
        }
        for name in names.dropFirst() {
            ref = "mailbox \(AppleScriptBridge.literal(name)) of \(ref)"
        }
        return ref
    }

    /// Whether `path` addresses one of the unified special mailboxes.
    static func isUnified(_ path: String) -> Bool {
        let parts = segments(path)
        return parts.count == 1 && unifiedNames[parts[0].uppercased()] != nil
    }
}

// MARK: - Script builders

/// Pure AppleScript fragment builders for the Mail service, split out so
/// tests can assert the exact object specifiers without driving Mail.
enum MailScripts {
    /// Bind `msg` to the message with RFC Message-ID `messageId`.
    ///
    /// Order: cached `(mailbox, internal id)` via `first message … whose id
    /// is N` (the `message id N` form does not compile — see file header),
    /// then a `whose message id is` scan of the given mailbox, the cached
    /// mailbox and finally the unified inbox.
    static func resolve(messageId: String, mailboxPath: String?, cached: (path: String, internalId: Int)?) throws -> String {
        let lit = AppleScriptBridge.literal(messageId)
        var lines: [String] = ["set msg to missing value"]
        if let cached {
            let ref = try MailboxPath.reference(cached.path)
            lines.append(
                """
                try
                    set msg to first message of (\(ref)) whose id is \(cached.internalId)
                    if (message id of msg) is not \(lit) then set msg to missing value
                on error
                    set msg to missing value
                end try
                """
            )
        }
        var scanned: [String] = []
        for path in [mailboxPath, cached?.path].compactMap({ $0 }) where !path.isEmpty {
            let ref = try MailboxPath.reference(path)
            guard !scanned.contains(ref) else { continue }
            scanned.append(ref)
            lines.append(
                """
                if msg is missing value then
                    try
                        set msg to first message of (\(ref)) whose message id is \(lit)
                    on error
                        set msg to missing value
                    end try
                end if
                """
            )
        }
        if !scanned.contains("inbox") {
            lines.append(
                """
                if msg is missing value then
                    try
                        set msg to first message of inbox whose message id is \(lit)
                    on error
                        set msg to missing value
                    end try
                end if
                """
            )
        }
        lines.append("if msg is missing value then error \"No message with id \" & \(lit) number -1728")
        return lines.joined(separator: "\n")
    }

    /// Select the most recent `limit` messages of `ref` (optionally
    /// filtered by `whose` conditions) into `msgs`. Mail does not promise an
    /// order for `messages of <mailbox>`, so the script compares the first and
    /// last `date received` and takes the newer end; Swift sorts afterwards.
    static func selectRecent(ref: String, conditions: [String], limit: Int) -> String {
        let n = max(limit, 1)
        if conditions.isEmpty {
            return """
                set c to count of messages of (\(ref))
                set msgs to {}
                if c > 0 then
                    set n to \(n)
                    if n > c then set n to c
                    set newestFirst to true
                    if c > 1 then
                        try
                            if (date received of message 1 of (\(ref))) < (date received of message c of (\(ref))) then set newestFirst to false
                        end try
                    end if
                    if newestFirst then
                        set msgs to messages 1 thru n of (\(ref))
                    else
                        set msgs to messages (c - n + 1) thru c of (\(ref))
                    end if
                end if
                """
        }
        return """
            set hits to (messages of (\(ref)) whose \(conditions.joined(separator: " and ")))
            set msgs to my takeRecent(hits, \(n))
            """
    }

    /// Encode `msgs` as separator-delimited rows and return them.
    /// `knownPathExpression` is an AppleScript expression (variable or
    /// literal) holding the canonical mailbox path, or `""` to resolve per row.
    static func encodeRows(knownPathExpression: String = "\"\"") -> String {
        """
        set rows to {}
        repeat with msg in msgs
            set end of rows to my encodeMessage(msg, FS, \(knownPathExpression))
        end repeat
        set AppleScript's text item delimiters to RS
        set outText to rows as text
        set AppleScript's text item delimiters to ""
        return outText
        """
    }
}

// MARK: - Service

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

    /// Run `body` with the shared handlers. The Apple Event timeout is set
    /// slightly below the executor budget so Mail's own `-1712` surfaces as
    /// a typed timeout instead of the executor giving up on a live script.
    private func run(
        _ body: String, timeout: TimeInterval = AppleScriptBridge.defaultTimeout, isWrite: Bool = false
    ) async throws -> String {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: Self.bundleIdentifier, appName: Self.appName) else {
            throw AppleToolError.unavailable("Mail could not be launched on this Mac.", retryable: true)
        }
        let eventBudget = max(Int(timeout) - 5, 10)
        let source = """
            \(AppleScriptBridge.separatorPrelude)
            \(AppleScriptBridge.isoDateHandler)
            \(AppleScriptBridge.makeDateHandler)
            \(Self.helperHandlers)
            with timeout of \(eventBudget) seconds
            \(body)
            end timeout
            """
        return try await AppleScriptBridge.runRetryingIfAppGone(
            bundleIdentifier: Self.bundleIdentifier, appName: Self.appName, isWrite: isWrite
        ) {
            try await AppleScriptBridge.run(
                source, permission: .automationMail, appName: Self.appName, timeout: timeout, isWrite: isWrite
            )
        }
    }

    /// Shared handlers: mailbox path rendering, mailbox tree encoding,
    /// recent-end selection and one-row message encoding (batched property
    /// get, per-property fallback). Handlers must live at top level — the
    /// body runs inside `with timeout`, which cannot contain `on` blocks.
    private static let helperHandlers = """
        on escapeSlash(t)
            set AppleScript's text item delimiters to "/"
            set pieces to text items of (t as text)
            set AppleScript's text item delimiters to ("\\\\" & "/")
            set joined to pieces as text
            set AppleScript's text item delimiters to ""
            return joined
        end escapeSlash
        on mailboxPath(mb)
            using terms from application "Mail"
                set parts to {}
                set cur to mb
                repeat 16 times
                    set beginning of parts to my escapeSlash(name of cur)
                    try
                        set parentRef to container of cur
                        if class of parentRef is mailbox then
                            set cur to parentRef
                        else
                            exit repeat
                        end if
                    on error
                        exit repeat
                    end try
                end repeat
                set acctName to ""
                try
                    set acctName to name of (account of mb)
                end try
                if acctName is "" or acctName is missing value then set acctName to "\(MailboxPath.localAccount)"
                set beginning of parts to my escapeSlash(acctName)
                set AppleScript's text item delimiters to "/"
                set p to parts as text
                set AppleScript's text item delimiters to ""
                return p
            end using terms from
        end mailboxPath
        on encodeTree(mb, acctName, depth, FS)
            using terms from application "Mail"
                set rows to {my encodeMailbox(mb, acctName, FS)}
                if depth < 12 then
                    try
                        repeat with sub in mailboxes of mb
                            set rows to rows & my encodeTree(sub, acctName, depth + 1, FS)
                        end repeat
                    end try
                end if
                return rows
            end using terms from
        end encodeTree
        on encodeMailbox(mb, acctName, FS)
            using terms from application "Mail"
                set unreadCountValue to 0
                try
                    set unreadCountValue to unread count of mb
                end try
                return my mailboxPath(mb) & FS & (name of mb) & FS & acctName & FS & (unreadCountValue as text)
            end using terms from
        end encodeMailbox
        on takeRecent(hits, n)
            using terms from application "Mail"
                set c to count of hits
                if c is 0 then return {}
                if n > c then set n to c
                if c is 1 then return hits
                set newestFirst to true
                try
                    if (date received of item 1 of hits) < (date received of item c of hits) then set newestFirst to false
                end try
                if newestFirst then
                    return items 1 thru n of hits
                else
                    return items (c - n + 1) thru c of hits
                end if
            end using terms from
        end takeRecent
        on encodeMessage(msg, FS, knownPath)
            using terms from application "Mail"
                set msgIdText to ""
                set subjectText to ""
                set senderText to ""
                set dateRecvText to ""
                set dateSentText to ""
                set readText to "false"
                set flagText to "false"
                set internalIdText to ""
                try
                    set {mid, subj, sndr, dr, ds, readVal, flagVal, iid} to {message id, subject, sender, date received, date sent, read status, flagged status, id} of msg
                    if mid is not missing value then set msgIdText to mid as text
                    if subj is not missing value then set subjectText to subj as text
                    if sndr is not missing value then set senderText to sndr as text
                    set dateRecvText to my isoDate(dr)
                    set dateSentText to my isoDate(ds)
                    if readVal is not missing value then set readText to readVal as text
                    if flagVal is not missing value then set flagText to flagVal as text
                    if iid is not missing value then set internalIdText to iid as text
                on error
                    try
                        set msgIdText to message id of msg
                    end try
                    try
                        set subjectText to subject of msg
                    end try
                    try
                        set senderText to sender of msg
                    end try
                    try
                        set readText to (read status of msg) as text
                    end try
                    try
                        set flagText to (flagged status of msg) as text
                    end try
                    try
                        set dateRecvText to my isoDate(date received of msg)
                    end try
                    try
                        set dateSentText to my isoDate(date sent of msg)
                    end try
                    try
                        set internalIdText to (id of msg) as text
                    end try
                end try
                set mboxPathText to knownPath
                if mboxPathText is "" then
                    try
                        set mboxPathText to my mailboxPath(mailbox of msg)
                    end try
                end if
                return msgIdText & FS & subjectText & FS & senderText & FS & dateRecvText & FS & dateSentText & FS & readText & FS & flagText & FS & mboxPathText & FS & internalIdText
            end using terms from
        end encodeMessage
        """

    /// AppleScript reference expression for a mailbox path.
    static func mailboxReference(_ path: String) throws -> String {
        try MailboxPath.reference(path)
    }

    private static func decodeRows(_ out: String) -> [(summary: MailMessageSummary, internalId: Int?)] {
        AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 9 else { return nil }
            let summary = MailMessageSummary(
                id: r[0], subject: r[1], sender: r[2],
                dateReceived: AppleScriptBridge.isoOutput(r[3]), dateSent: AppleScriptBridge.isoOutput(r[4]),
                isRead: AppleScriptBridge.bool(r[5]), isFlagged: AppleScriptBridge.bool(r[6]),
                mailboxPath: r[7]
            )
            return (summary, AppleScriptBridge.int(r[8]))
        }
    }

    private func decodeAndRemember(_ out: String) -> [MailMessageSummary] {
        Self.decodeRows(out).map { row in
            if !row.summary.id.isEmpty, let internalId = row.internalId, !row.summary.mailboxPath.isEmpty {
                remember(row.summary.id, path: row.summary.mailboxPath, internalId: internalId)
            }
            return row.summary
        }
    }

    /// Newest first; rows without a parseable date sink to the end.
    static func sortedNewestFirst(_ rows: [MailMessageSummary]) -> [MailMessageSummary] {
        rows.sorted { a, b in
            let da = a.dateReceived.flatMap { AppleDateParsing.parse($0)?.date }
            let db = b.dateReceived.flatMap { AppleDateParsing.parse($0)?.date }
            switch (da, db) {
            case (let x?, let y?): return x > y
            case (_?, nil): return true
            default: return false
            }
        }
    }

    // MARK: Message resolution

    private func resolveScript(messageId: String, mailboxPath: String?) throws -> String {
        try MailScripts.resolve(messageId: messageId, mailboxPath: mailboxPath, cached: cached(messageId))
    }

    private func notFound(_ id: String, _ mailboxPath: String?) -> AppleToolError {
        .notFound(
            "No message with id `\(id)`\(mailboxPath.map { " in `\($0)`" } ?? " in the inbox"). Pass the `mailbox_path` returned by mail_list / mail_search, or search again."
        )
    }

    /// Run a script that resolves `msg` first; a `-1728` from the resolver
    /// drops the stale cache entry and rethrows a path-aware not-found.
    private func runResolved(
        _ id: String, _ mailboxPath: String?, timeout: TimeInterval, isWrite: Bool = false, body: () throws -> String
    ) async throws -> String {
        do {
            return try await run(try body(), timeout: timeout, isWrite: isWrite)
        } catch let error as AppleToolError {
            if case .notFound = error {
                forget(id)
                throw notFound(id, mailboxPath)
            }
            throw error
        }
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
                        set rows to rows & my encodeTree(mb, acctName, 0, FS)
                    end repeat
                end repeat
                try
                    repeat with mb in mailboxes
                        set rows to rows & my encodeTree(mb, "\(MailboxPath.localAccount)", 0, FS)
                    end repeat
                end try
                set AppleScript's text item delimiters to RS
                set outText to rows as text
                set AppleScript's text item delimiters to ""
                return outText
            end tell
            """,
            timeout: 120
        )
        // Mail lists the same account-level mailbox under `mailboxes` (all
        // accounts) too; dedupe on path.
        var seen = Set<String>()
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 4, !r[0].isEmpty, !seen.contains(r[0]) else { return nil }
            seen.insert(r[0])
            return MailboxInfo(path: r[0], name: r[1], account: r[2], unreadCount: Int(r[3]) ?? 0)
        }
    }

    func list(_ query: MailQuery) async throws -> [MailMessageSummary] {
        let path = query.mailboxPath ?? "INBOX"
        let ref = try MailboxPath.reference(path)
        var conditions: [String] = []
        if query.unreadOnly { conditions.append("read status is false") }
        if let since = query.since { conditions.append("date received > \(AppleScriptBridge.dateExpression(since))") }
        let out = try await run(
            """
            tell application "Mail"
                \(Self.knownPathAssignment(path: path, ref: ref))
                \(MailScripts.selectRecent(ref: ref, conditions: conditions, limit: query.limit))
                \(MailScripts.encodeRows(knownPathExpression: "knownPath"))
            end tell
            """,
            timeout: 120
        )
        return Self.sortedNewestFirst(decodeAndRemember(out))
    }

    func search(_ query: MailSearchQuery) async throws -> [MailMessageSummary] {
        let path = query.mailboxPath ?? "INBOX"
        let ref = try MailboxPath.reference(path)
        let lit = AppleScriptBridge.literal(query.text)
        let clause: String
        switch query.field {
        case .subject: clause = "subject contains \(lit)"
        case .sender: clause = "sender contains \(lit)"
        case .any: clause = "(subject contains \(lit) or sender contains \(lit))"
        }
        let out = try await run(
            """
            tell application "Mail"
                \(Self.knownPathAssignment(path: path, ref: ref))
                \(MailScripts.selectRecent(ref: ref, conditions: [clause], limit: query.limit))
                \(MailScripts.encodeRows(knownPathExpression: "knownPath"))
            end tell
            """,
            timeout: 120
        )
        return Self.sortedNewestFirst(decodeAndRemember(out))
    }

    /// For account-scoped mailboxes the canonical path is computed once and
    /// reused for every row; unified mailboxes span accounts so each row
    /// resolves its own.
    private static func knownPathAssignment(path: String, ref: String) -> String {
        if MailboxPath.isUnified(path) { return "set knownPath to \"\"" }
        return """
            set knownPath to ""
            try
                set knownPath to my mailboxPath(\(ref))
            end try
            """
    }

    func read(id: String, mailboxPath: String?) async throws -> MailMessageContent {
        let out = try await runResolved(id, mailboxPath, timeout: 90) {
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                set GS to character id 29
                set US to character id 28
                set headerRow to my encodeMessage(msg, FS, "")
                set toList to {}
                try
                    repeat with rcpt in to recipients of msg
                        set end of toList to (address of rcpt)
                    end repeat
                end try
                set ccList to {}
                try
                    repeat with rcpt in cc recipients of msg
                        set end of ccList to (address of rcpt)
                    end repeat
                end try
                set replyToText to ""
                try
                    set replyToText to reply to of msg
                end try
                set junkText to "false"
                try
                    set junkText to (junk mail status of msg) as text
                end try
                set attList to {}
                try
                    repeat with att in mail attachments of msg
                        set sizeText to ""
                        try
                            set sizeText to (file size of att) as text
                        end try
                        set mimeText to ""
                        try
                            set mimeText to MIME type of att
                        end try
                        set end of attList to (name of att) & US & sizeText & US & mimeText
                    end repeat
                end try
                set AppleScript's text item delimiters to ","
                set toText to toList as text
                set ccText to ccList as text
                set AppleScript's text item delimiters to GS
                set attText to attList as text
                set AppleScript's text item delimiters to ""
                set bodyText to ""
                try
                    set bodyText to content of msg
                end try
                return headerRow & RS & toText & FS & ccText & FS & replyToText & FS & junkText & FS & attText & RS & bodyText
            end tell
            """
        }
        let sections = out.split(separator: AppleScriptBridge.recordSeparator, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard sections.count >= 2, let row = Self.decodeRows(sections[0]).first else {
            throw notFound(id, mailboxPath)
        }
        if let internalId = row.internalId, !row.summary.mailboxPath.isEmpty {
            remember(row.summary.id, path: row.summary.mailboxPath, internalId: internalId)
        }
        let meta = sections[1].split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        let body = sections.count > 2 ? sections[2] : ""
        let split: (String) -> [String] = { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let attachments: [MailAttachmentInfo] = (meta.count > 4 ? meta[4] : "")
            .split(separator: "\u{1D}", omittingEmptySubsequences: true)
            .map { raw in
                let p = raw.split(separator: "\u{1C}", omittingEmptySubsequences: false).map(String.init)
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
        // `activate`, so focus does not move); a send closes it. `send`
        // returns a boolean; `false` means Mail refused (no account, offline
        // queue disabled, …) and must not be reported as sent.
        let out = try await run(
            """
            tell application "Mail"
                set newMsg to make new outgoing message with properties {subject:\(AppleScriptBridge.literal(draft.subject)), content:\(AppleScriptBridge.literal(draft.body)), visible:\(draft.send ? "false" : "true")}
                tell newMsg
                    \(recipients("to recipient", draft.to))
                    \(recipients("cc recipient", draft.cc))
                    \(recipients("bcc recipient", draft.bcc))
                end tell
                \(draft.send ? "set ok to send newMsg\nif ok is false then error \"Mail refused to send the message.\" number -10000\nreturn \"sent\"" : "return \"draft\"")
            end tell
            """,
            isWrite: true
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
        // The subject is captured before `send` — the outgoing message is
        // gone once it leaves, so reading it afterwards raises -1728.
        let out = try await runResolved(id, mailboxPath, timeout: AppleScriptBridge.defaultTimeout, isWrite: true) {
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                set replyMsg to reply msg \(flagClause)
                set content of replyMsg to \(AppleScriptBridge.literal(body + "\n\n")) & (content of replyMsg)
                set subjectText to ""
                try
                    set subjectText to subject of replyMsg
                end try
                \(send ? "set ok to send replyMsg\nif ok is false then error \"Mail refused to send the reply.\" number -10000\nreturn \"sent\" & FS & subjectText" : "return \"draft\" & FS & subjectText")
            end tell
            """
        }
        let parts = out.split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        return (parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "sent", parts.count > 1 ? parts[1] : "")
    }

    func move(id: String, mailboxPath: String?, to destinationPath: String) async throws -> MailMessageSummary {
        let dest = try MailboxPath.reference(destinationPath)
        let isTrash = MailboxPath.segments(destinationPath).first?.uppercased() == "TRASH" && MailboxPath.isUnified(destinationPath)
        // Capture the summary from the original reference *before* the move
        // (the specifier points at the old location afterwards), then poll
        // the destination for up to ~3s for the re-homed copy. If the server
        // is slow the pre-move row is returned with the destination path.
        let moveStatement = isTrash ? "delete msg" : "set mailbox of msg to (\(dest))"
        let out = try await runResolved(id, mailboxPath, timeout: 60, isWrite: true) {
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                set beforeRow to my encodeMessage(msg, FS, "")
                \(moveStatement)
                set afterRow to ""
                repeat 10 times
                    delay 0.3
                    try
                        set moved to first message of (\(dest)) whose message id is \(AppleScriptBridge.literal(id))
                        set afterRow to my encodeMessage(moved, FS, "")
                        exit repeat
                    end try
                end repeat
                return beforeRow & RS & afterRow
            end tell
            """
        }
        forget(id)
        let rows = Self.decodeRows(out)
        guard let before = rows.first else { throw notFound(id, mailboxPath) }
        if rows.count > 1, !rows[1].summary.id.isEmpty {
            if let internalId = rows[1].internalId { remember(id, path: rows[1].summary.mailboxPath, internalId: internalId) }
            return rows[1].summary
        }
        let s = before.summary
        return MailMessageSummary(
            id: s.id, subject: s.subject, sender: s.sender, dateReceived: s.dateReceived, dateSent: s.dateSent,
            isRead: s.isRead, isFlagged: s.isFlagged, mailboxPath: destinationPath
        )
    }

    func setStatus(id: String, mailboxPath: String?, patch: MailStatusPatch) async throws -> MailMessageSummary {
        var sets: [String] = []
        if let r = patch.read { sets.append("set read status of msg to \(r)") }
        if let f = patch.flagged { sets.append("set flagged status of msg to \(f)") }
        if let j = patch.junk { sets.append("set junk mail status of msg to \(j)") }
        let out = try await runResolved(id, mailboxPath, timeout: AppleScriptBridge.defaultTimeout, isWrite: true) {
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                \(sets.joined(separator: "\n"))
                return my encodeMessage(msg, FS, "")
            end tell
            """
        }
        guard let summary = decodeAndRemember(out).first else { throw notFound(id, mailboxPath) }
        return summary
    }

    func thread(id: String, mailboxPath: String?, limit: Int) async throws -> [MailMessageSummary] {
        // Headers only — the root body is not needed to group a thread.
        let rootOut = try await runResolved(id, mailboxPath, timeout: AppleScriptBridge.defaultTimeout) {
            """
            tell application "Mail"
                \(try resolveScript(messageId: id, mailboxPath: mailboxPath))
                return my encodeMessage(msg, FS, "")
            end tell
            """
        }
        guard let root = decodeAndRemember(rootOut).first else { throw notFound(id, mailboxPath) }
        let normalized = Self.normalizedSubject(root.subject)
        guard !normalized.isEmpty, !root.mailboxPath.isEmpty else { return [root] }
        let ref = try MailboxPath.reference(root.mailboxPath)
        let clause = "subject contains \(AppleScriptBridge.literal(normalized))"
        let out = try await run(
            """
            tell application "Mail"
                set knownPath to \(AppleScriptBridge.literal(root.mailboxPath))
                \(MailScripts.selectRecent(ref: ref, conditions: [clause], limit: max(limit, 1) * 3))
                \(MailScripts.encodeRows(knownPathExpression: "knownPath"))
            end tell
            """,
            timeout: 120
        )
        var rows = decodeAndRemember(out).filter { Self.normalizedSubject($0.subject) == normalized }
        if !rows.contains(where: { $0.id == root.id }) { rows.append(root) }
        let oldestFirst = Array(Self.sortedNewestFirst(rows).reversed())
        return Array(oldestFirst.suffix(limit))
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
