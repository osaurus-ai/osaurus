//
//  MessagesService.swift
//  osaurus
//
//  Messages (iMessage / SMS) access. Reads go straight to
//  `~/Library/Messages/chat.db` (read-only SQLite; needs Full Disk Access),
//  sends go through AppleScript (needs Automation for Messages). Ported
//  fixes vs. the plugin: ISO8601 dates with local offset, message GUIDs and
//  chat GUIDs returned everywhere, `attributedBody`-only messages decoded so
//  modern macOS messages do not come back empty, and no `activate`.
//
//  Search decodes `attributedBody` in Swift: on current macOS most bodies
//  live only in that typedstream blob, and `CAST(attributedBody AS TEXT)`
//  stops at the first NUL byte (a few bytes in), so a SQL `LIKE` on it never
//  matched recent messages. Rows are paged out of SQLite and matched here.
//
//  This is self-contained; the iMessage *channel* (inbound routing through
//  `imsg rpc`) is a separate feature with its own allowlists.
//

import Foundation
import SQLite3

struct MessagesConversation: Codable, Sendable, Equatable {
    /// chat.guid, e.g. `iMessage;-;+14155551234` or `iMessage;+;chat1234`.
    let id: String
    let chatIdentifier: String
    let displayName: String?
    let participants: [String]
    let service: String?
    let isGroup: Bool
    let lastMessageDate: String?
    let lastMessagePreview: String?
    let unreadCount: Int
}

struct MessagesMessage: Codable, Sendable, Equatable {
    let id: String
    let chatId: String?
    let sender: String?
    let isFromMe: Bool
    let date: String
    let text: String
    let isRead: Bool
    let service: String?
    let hasAttachments: Bool
}

struct MessagesReadQuery: Sendable, Equatable {
    var chatId: String?
    var handle: String?
    var since: Date?
    var limit: Int = 25
}

enum MessagesSendService: String, CaseIterable, Sendable {
    case auto, imessage, sms
}

/// Outcome of `messages_send`.
struct MessagesSendResult: Sendable, Equatable {
    /// `iMessage`, `SMS`, or `chat` (sent into an existing conversation).
    let service: String
    /// Normalised handle or chat guid the message went to.
    let target: String
    /// `true` when chat.db shows the message stored without an error,
    /// `false` when it shows a send error, `nil` when delivery could not be
    /// verified (no Full Disk Access, or the row did not appear in time).
    let delivered: Bool?
}

protocol MessagesServicing: Sendable {
    func conversations(limit: Int) async throws -> [MessagesConversation]
    func read(_ query: MessagesReadQuery) async throws -> [MessagesMessage]
    func unread(limit: Int) async throws -> [MessagesMessage]
    func search(_ text: String, limit: Int) async throws -> [MessagesMessage]
    func send(to recipient: String?, chatId: String?, text: String, service: MessagesSendService) async throws
        -> MessagesSendResult
}

final class ChatDBMessagesService: MessagesServicing, @unchecked Sendable {
    /// Serial queue for this service.
    private let queue = AppleServiceQueue(label: "messages")
    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    let databaseURL: URL

    init(databaseURL: URL = ChatDBMessagesService.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    // MARK: SQLite

    private final class Connection {
        let db: OpaquePointer

        init(url: URL) throws {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            let uri = "file:\(url.path)?mode=ro"
            let rc = sqlite3_open_v2(uri, &handle, flags, nil)
            guard rc == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
                let extended = handle.map { sqlite3_extended_errcode($0) } ?? rc
                if let handle { sqlite3_close(handle) }
                if ChatDBMessagesService.isPermissionCode(extended) || ChatDBMessagesService.isPermissionMessage(message) {
                    throw AppleToolError.permissionDenied(
                        .disk, detail: "Reading Messages requires Full Disk Access for Osaurus (chat.db could not be opened: \(message))."
                    )
                }
                throw AppleToolError.unavailable("Could not open the Messages database: \(message)", retryable: true)
            }
            self.db = handle
            sqlite3_busy_timeout(handle, 3000)
        }

        deinit { sqlite3_close(db) }

        private func mapError(_ context: String) -> AppleToolError {
            let message = String(cString: sqlite3_errmsg(db))
            let extended = sqlite3_extended_errcode(db)
            if ChatDBMessagesService.isPermissionCode(extended) || ChatDBMessagesService.isPermissionMessage(message) {
                return .permissionDenied(.disk, detail: "chat.db is not readable: \(message).")
            }
            if extended & 0xFF == SQLITE_BUSY || extended & 0xFF == SQLITE_LOCKED {
                return .unavailable("The Messages database is busy (\(message)). Try again in a moment.", retryable: true)
            }
            return .execution("\(context): \(message)")
        }

        /// Run `sql` with `?` bindings and map every row.
        func query<T>(_ sql: String, bind: [Any?] = [], map: (OpaquePointer) -> T) throws -> [T] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw mapError("Messages query failed to prepare")
            }
            defer { sqlite3_finalize(stmt) }
            for (i, value) in bind.enumerated() {
                let idx = Int32(i + 1)
                switch value {
                case nil: sqlite3_bind_null(stmt, idx)
                case let s as String: sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
                case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
                case let d as Double: sqlite3_bind_double(stmt, idx, d)
                default: sqlite3_bind_text(stmt, idx, String(describing: value!), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            var rows: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { rows.append(map(stmt)) } else if rc == SQLITE_DONE { break } else {
                    throw mapError("Messages query failed")
                }
            }
            return rows
        }
    }

    /// SQLite result codes that mean "the file is there but macOS will not
    /// let this process read it" (Full Disk Access missing).
    static func isPermissionCode(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        // Extended codes (the macro forms are not imported into Swift):
        // SQLITE_IOERR_READ = IOERR | (1<<8), SQLITE_IOERR_ACCESS = IOERR | (13<<8),
        // SQLITE_READONLY_DIRECTORY = READONLY | (6<<8).
        let ioerrRead = SQLITE_IOERR | (1 << 8)
        let ioerrAccess = SQLITE_IOERR | (13 << 8)
        let readonlyDirectory = SQLITE_READONLY | (6 << 8)
        return primary == SQLITE_AUTH || primary == SQLITE_PERM || primary == SQLITE_CANTOPEN
            || code == ioerrAccess || code == ioerrRead || code == readonlyDirectory
    }

    static func isPermissionMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("unable to open")
            || message.localizedCaseInsensitiveContains("authorization")
            || message.localizedCaseInsensitiveContains("not permitted")
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    private static func int(_ stmt: OpaquePointer, _ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, col))
        return Data(bytes: p, count: n)
    }

    /// Distinguish "no database" (Messages never set up) from "database
    /// present but unreadable" (no Full Disk Access): `stat` on the file
    /// fails with EPERM/EACCES in the latter case and ENOENT in the former.
    private func open() throws -> Connection {
        var info = stat()
        if stat(databaseURL.path, &info) != 0 {
            switch errno {
            case EPERM, EACCES:
                throw AppleToolError.permissionDenied(
                    .disk, detail: "Reading Messages requires Full Disk Access for Osaurus (\(databaseURL.path) is not readable)."
                )
            case ENOENT:
                throw AppleToolError.unavailable(
                    "No Messages database found at \(databaseURL.path). Has Messages been set up on this Mac?", retryable: false
                )
            default:
                throw AppleToolError.unavailable(
                    "Could not access the Messages database (\(String(cString: strerror(errno)))).", retryable: true
                )
            }
        }
        return try Connection(url: databaseURL)
    }

    /// Whether chat.db is readable right now (used to decide whether a send
    /// can be verified).
    private func canReadDatabase() -> Bool {
        (try? open()) != nil
    }

    // MARK: Dates

    /// Apple epoch (2001-01-01) in nanoseconds on modern macOS, seconds on old databases.
    static func date(fromAppleTime raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds: TimeInterval = raw > 10_000_000_000 ? TimeInterval(raw) / 1_000_000_000 : TimeInterval(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func appleTime(from date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    // MARK: attributedBody

    /// Extract the text payload from Messages' `attributedBody` typedstream
    /// blob: the string follows the `NSString` class marker, a 5-byte
    /// preamble, and a 1- or 3-byte length.
    static func decodeAttributedBody(_ data: Data?) -> String? {
        guard let data, let range = data.range(of: Data("NSString".utf8)) else { return nil }
        var i = range.upperBound + 5
        guard i < data.count else { return nil }
        var length = Int(data[i])
        i += 1
        if length == 0x81 {
            guard i + 1 < data.count else { return nil }
            length = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2
        } else if length == 0x82 {
            guard i + 3 < data.count else { return nil }
            length = Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16) | (Int(data[i + 3]) << 24)
            i += 4
        }
        guard length > 0, i + length <= data.count else { return nil }
        return String(data: data[i ..< i + length], encoding: .utf8)
    }

    /// Body text for a row: `text`, else the decoded `attributedBody`, with
    /// the U+FFFC attachment placeholders removed. Attachment-only messages
    /// read `[attachment]` instead of an empty string.
    static func bodyText(text: String?, attributedBody: Data?, hasAttachments: Bool) -> String {
        var body = text ?? decodeAttributedBody(attributedBody) ?? ""
        body = body.replacingOccurrences(of: "\u{FFFC}", with: "")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return hasAttachments ? "[attachment]" : "" }
        return body
    }

    /// Escape `%`, `_` and the escape character for a `LIKE ? ESCAPE '\'`.
    static func likePattern(_ text: String) -> String {
        var out = "%"
        for ch in text {
            switch ch {
            case "%", "_", "\\": out.append("\\"); out.append(ch)
            default: out.append(ch)
            }
        }
        out.append("%")
        return out
    }

    // MARK: Queries

    /// Real conversation content only: `item_type = 0` drops group
    /// renames / joins / leaves; `associated_message_type` 2000–3999 are
    /// tapbacks (and their removals) that only reference another message.
    static let contentPredicate =
        "m.item_type = 0 AND (m.associated_message_type IS NULL OR m.associated_message_type = 0 OR m.associated_message_type < 2000 OR m.associated_message_type >= 4000)"

    /// Unread = incoming, unread, real content.
    static let unreadPredicate = "m.is_read = 0 AND m.is_from_me = 0 AND " + contentPredicate

    private static let messageSelect = """
        SELECT m.guid, c.guid, h.id, m.is_from_me, m.date, m.text, m.attributedBody, m.is_read, m.service, m.cache_has_attachments, m.error
        FROM message m
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        """

    /// A message joined to more than one chat would otherwise repeat.
    private static let messageGroupBy = " GROUP BY m.ROWID"

    private static func message(_ stmt: OpaquePointer) -> MessagesMessage? {
        let guid = text(stmt, 0) ?? ""
        let hasAttachments = int(stmt, 9) == 1
        let body = bodyText(text: text(stmt, 5), attributedBody: blob(stmt, 6), hasAttachments: hasAttachments)
        let date = date(fromAppleTime: int(stmt, 4))
        return MessagesMessage(
            id: guid,
            chatId: text(stmt, 1),
            sender: int(stmt, 3) == 1 ? nil : text(stmt, 2),
            isFromMe: int(stmt, 3) == 1,
            date: date.map { AppleDateParsing.format($0) } ?? "",
            text: body,
            isRead: int(stmt, 7) == 1 || int(stmt, 3) == 1,
            service: text(stmt, 8),
            hasAttachments: hasAttachments
        )
    }

    func conversations(limit: Int) async throws -> [MessagesConversation] {
        try await queue.run { [self] in
            let db = try open()
            // One statement: participants via group_concat, unread count and
            // the newest message via correlated subqueries.
            return try db.query(
                """
                SELECT c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
                       (SELECT group_concat(h.id, char(31)) FROM handle h JOIN chat_handle_join chj ON chj.handle_id = h.ROWID WHERE chj.chat_id = c.ROWID) AS participants,
                       (SELECT COUNT(*) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = c.ROWID AND \(Self.unreadPredicate)) AS unread,
                       lm.date, lm.text, lm.attributedBody, lm.cache_has_attachments
                FROM chat c
                LEFT JOIN message lm ON lm.ROWID = (
                    SELECT m.ROWID FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
                    WHERE j.chat_id = c.ROWID AND \(Self.contentPredicate)
                    ORDER BY m.date DESC LIMIT 1
                )
                ORDER BY (lm.date IS NULL), lm.date DESC
                LIMIT ?
                """,
                bind: [limit]
            ) { s in
                let participants = (Self.text(s, 5) ?? "").split(separator: "\u{1F}").map(String.init).sorted()
                let display = Self.text(s, 2).flatMap { $0.isEmpty ? nil : $0 }
                let style = Self.int(s, 4)
                let lastDate = Self.date(fromAppleTime: Self.int(s, 7))
                let hasLast = sqlite3_column_type(s, 7) != SQLITE_NULL
                let preview = hasLast
                    ? Self.bodyText(text: Self.text(s, 8), attributedBody: Self.blob(s, 9), hasAttachments: Self.int(s, 10) == 1)
                    : nil
                return MessagesConversation(
                    id: Self.text(s, 0) ?? "", chatIdentifier: Self.text(s, 1) ?? "", displayName: display,
                    participants: participants, service: Self.text(s, 3),
                    isGroup: style == 43 || participants.count > 1,
                    lastMessageDate: lastDate.map { AppleDateParsing.format($0) },
                    lastMessagePreview: preview.map { String($0.prefix(120)) },
                    unreadCount: Int(Self.int(s, 6))
                )
            }
        }
    }

    func read(_ query: MessagesReadQuery) async throws -> [MessagesMessage] {
        try await queue.run { [self] in
            let db = try open()
            var clauses: [String] = [Self.contentPredicate]
            var binds: [Any?] = []
            if let chatId = query.chatId?.trimmingCharacters(in: .whitespacesAndNewlines), !chatId.isEmpty {
                clauses.append("(c.guid = ? OR c.chat_identifier = ?)")
                binds += [chatId, chatId]
            }
            if let handle = query.handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
                let normalized = IMessageConnectionConfiguration.normalizedId(handle)
                let digits = normalized.filter(\.isNumber)
                if digits.count >= 7, !normalized.contains("@") {
                    clauses.append("(REPLACE(REPLACE(REPLACE(REPLACE(h.id,'+',''),'-',''),' ',''),'(','') LIKE ? OR c.chat_identifier LIKE ?)")
                    binds += ["%\(digits.suffix(10))", "%\(digits.suffix(10))"]
                } else {
                    clauses.append("(LOWER(h.id) = ? OR LOWER(c.chat_identifier) = ?)")
                    binds += [normalized.lowercased(), normalized.lowercased()]
                }
            }
            if let since = query.since {
                clauses.append("m.date > ?")
                binds.append(Self.appleTime(from: since))
            }
            let whereSQL = " WHERE " + clauses.joined(separator: " AND ")
            binds.append(query.limit)
            let rows: [MessagesMessage] = try db.query(
                Self.messageSelect + whereSQL + Self.messageGroupBy + " ORDER BY m.date DESC LIMIT ?", bind: binds
            ) { Self.message($0) }.compactMap { $0 }
            return rows.reversed()
        }
    }

    func unread(limit: Int) async throws -> [MessagesMessage] {
        try await queue.run { [self] in
            let db = try open()
            return try db.query(
                Self.messageSelect + " WHERE " + Self.unreadPredicate + Self.messageGroupBy + " ORDER BY m.date DESC LIMIT ?",
                bind: [limit]
            ) { Self.message($0) }.compactMap { $0 }
        }
    }

    /// Rows fetched per page while searching.
    static let searchPageSize = 400
    /// Upper bound on rows examined per search (newest first) so a rare
    /// term in a huge library still returns in bounded time.
    static let searchScanCap = 40_000

    func search(_ text: String, limit: Int) async throws -> [MessagesMessage] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return try await queue.run { [self] in
            let db = try open()
            // SQL pre-filter: plain-text rows must LIKE-match (cheap, ASCII
            // case-insensitive); attributedBody-only rows all come through
            // and are decoded + matched in Swift.
            let sql =
                Self.messageSelect
                + " WHERE \(Self.contentPredicate) AND ((m.text IS NOT NULL AND m.text LIKE ? ESCAPE '\\') OR (m.text IS NULL AND m.attributedBody IS NOT NULL))"
                + Self.messageGroupBy + " ORDER BY m.date DESC LIMIT ? OFFSET ?"
            var hits: [MessagesMessage] = []
            var offset = 0
            while hits.count < limit, offset < Self.searchScanCap {
                try Task.checkCancellation()
                let page: [MessagesMessage] = try db.query(
                    sql, bind: [Self.likePattern(needle), Self.searchPageSize, offset]
                ) { Self.message($0) }.compactMap { $0 }
                for row in page where AppleServiceSupport.matches(row.text, query: needle) {
                    hits.append(row)
                    if hits.count >= limit { break }
                }
                if page.count < Self.searchPageSize { break }
                offset += Self.searchPageSize
            }
            return hits
        }
    }

    // MARK: Send

    /// Resolve a `chat_id` argument to the chat GUID Messages' `chat id`
    /// specifier expects. `chat_identifier` values (`chat123…`, a bare
    /// handle) are looked up in chat.db when readable; otherwise the value
    /// is used as given.
    private func resolveChatGuid(_ chatId: String) -> String {
        if chatId.contains(";") { return chatId }
        guard let db = try? open() else { return chatId }
        let rows: [String] = (try? db.query(
            "SELECT guid FROM chat WHERE chat_identifier = ? OR guid = ? ORDER BY ROWID DESC LIMIT 1", bind: [chatId, chatId]
        ) { Self.text($0, 0) ?? "" }) ?? []
        return rows.first.flatMap { $0.isEmpty ? nil : $0 } ?? chatId
    }

    /// Poll chat.db for the just-sent outgoing message. Returns `true` /
    /// `false` when a matching row appeared (and whether it carries an
    /// error), `nil` when nothing showed up within the window or the
    /// database is not readable.
    private func verifyDelivery(text: String, sentAfter: Date, timeout: TimeInterval = 6) async -> Bool? {
        guard canReadDatabase() else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let since = Self.appleTime(from: sentAfter.addingTimeInterval(-2))
        while Date() < deadline {
            if Task.isCancelled { return nil }
            let outcome: Bool? = try? await queue.run { [self] in
                let db = try open()
                // Newest outgoing rows since the send; attributedBody-only
                // rows are decoded for the comparison.
                let errors: [Int64] = try db.query(
                    "SELECT m.error, m.text, m.attributedBody FROM message m WHERE m.is_from_me = 1 AND m.date > ? ORDER BY m.date DESC LIMIT 10",
                    bind: [since]
                ) { s in
                    let body = Self.bodyText(text: Self.text(s, 1), attributedBody: Self.blob(s, 2), hasAttachments: false)
                    return body == text ? Self.int(s, 0) : -1
                }.filter { $0 >= 0 }
                if let error = errors.first { return error == 0 }
                return nil
            }
            if let outcome { return outcome }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    func send(to recipient: String?, chatId: String?, text: String, service: MessagesSendService) async throws
        -> MessagesSendResult
    {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages") else {
            throw AppleToolError.unavailable("Messages could not be launched on this Mac.", retryable: true)
        }
        let literalText = AppleScriptBridge.literal(text)
        if let chatId = chatId?.trimmingCharacters(in: .whitespacesAndNewlines), !chatId.isEmpty {
            let guid = resolveChatGuid(chatId)
            let started = Date()
            _ = try await AppleScriptBridge.run(
                """
                tell application "Messages"
                    send \(literalText) to chat id \(AppleScriptBridge.literal(guid))
                end tell
                """,
                permission: .automationMessages, appName: "Messages", isWrite: true
            )
            let delivered = await verifyDelivery(text: text, sentAfter: started)
            return MessagesSendResult(service: "chat", target: guid, delivered: delivered)
        }
        guard let recipient = recipient?.trimmingCharacters(in: .whitespacesAndNewlines), !recipient.isEmpty else {
            throw AppleToolError.invalidArgs("Provide `to` (phone number or email) or `chat_id`.", field: "to")
        }
        let handle = IMessageConnectionConfiguration.normalizedId(recipient)
        let order: [String]
        switch service {
        case .imessage: order = ["iMessage"]
        case .sms: order = ["SMS"]
        case .auto: order = ["iMessage", "SMS"]
        }
        var lastError: AppleToolError?
        for (index, serviceType) in order.enumerated() {
            let started = Date()
            do {
                _ = try await AppleScriptBridge.run(
                    """
                    tell application "Messages"
                        set targetService to first account whose service type = \(serviceType) and enabled is true
                        set targetBuddy to participant \(AppleScriptBridge.literal(handle)) of targetService
                        send \(literalText) to targetBuddy
                    end tell
                    """,
                    permission: .automationMessages, appName: "Messages", isWrite: true
                )
            } catch let error as AppleToolError {
                if case .permissionDenied = error { throw error }
                if case .timeout(_, let unknown) = error, unknown { throw error }
                lastError = error
                continue
            }
            // Messages accepts the Apple Event even when the recipient is
            // not reachable on this service (the bubble turns red a moment
            // later). Verify through chat.db before falling back so the
            // user does not get the same text twice, and never fall back
            // when the outcome is unknown.
            let delivered = await verifyDelivery(text: text, sentAfter: started)
            let hasFallback = index + 1 < order.count
            if delivered == false, hasFallback {
                lastError = .execution("Messages reported an error sending to \(handle) over \(serviceType).")
                continue
            }
            return MessagesSendResult(service: serviceType, target: handle, delivered: delivered)
        }
        throw lastError ?? AppleToolError.execution("Messages could not send to \(handle).")
    }
}
