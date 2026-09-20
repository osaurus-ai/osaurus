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

protocol MessagesServicing: Sendable {
    func conversations(limit: Int) async throws -> [MessagesConversation]
    func read(_ query: MessagesReadQuery) async throws -> [MessagesMessage]
    func unread(limit: Int) async throws -> [MessagesMessage]
    func search(_ text: String, limit: Int) async throws -> [MessagesMessage]
    func send(to recipient: String?, chatId: String?, text: String, service: MessagesSendService) async throws -> (
        service: String, target: String
    )
}

final class ChatDBMessagesService: MessagesServicing, @unchecked Sendable {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
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
                if let handle { sqlite3_close(handle) }
                if rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM
                    || message.localizedCaseInsensitiveContains("unable to open")
                    || message.localizedCaseInsensitiveContains("authorization")
                {
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

        /// Run `sql` with `?` bindings and map every row.
        func query<T>(_ sql: String, bind: [Any?] = [], map: (OpaquePointer) -> T) throws -> [T] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                let message = String(cString: sqlite3_errmsg(db))
                if message.localizedCaseInsensitiveContains("authorization") || message.localizedCaseInsensitiveContains("not a database") {
                    throw AppleToolError.permissionDenied(.disk, detail: "chat.db is not readable: \(message).")
                }
                throw AppleToolError.execution("Messages query failed to prepare: \(message)")
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
                    let message = String(cString: sqlite3_errmsg(db))
                    if message.localizedCaseInsensitiveContains("authorization") {
                        throw AppleToolError.permissionDenied(.disk, detail: "chat.db is not readable: \(message).")
                    }
                    throw AppleToolError.execution("Messages query failed: \(message)")
                }
            }
            return rows
        }
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

    private func open() throws -> Connection {
        let url = Self.databaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Without Full Disk Access `fileExists` itself is false for ~/Library/Messages.
            if !FileManager.default.isReadableFile(atPath: url.deletingLastPathComponent().path) {
                throw AppleToolError.permissionDenied(.disk, detail: "Reading Messages requires Full Disk Access for Osaurus.")
            }
            throw AppleToolError.unavailable("No Messages database found at \(url.path). Has Messages been set up on this Mac?", retryable: false)
        }
        return try Connection(url: url)
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

    // MARK: Queries

    private static let messageSelect = """
        SELECT m.guid, c.guid, h.id, m.is_from_me, m.date, m.text, m.attributedBody, m.is_read, m.service, m.cache_has_attachments
        FROM message m
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        """

    private static func message(_ stmt: OpaquePointer) -> MessagesMessage? {
        let guid = text(stmt, 0) ?? ""
        let body = text(stmt, 5) ?? decodeAttributedBody(blob(stmt, 6)) ?? ""
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
            hasAttachments: int(stmt, 9) == 1
        )
    }

    func conversations(limit: Int) async throws -> [MessagesConversation] {
        try await AppleServiceQueue.run { [self] in
            let db = try open()
            struct Row { let rowid: Int64; let guid: String; let identifier: String; let display: String?; let service: String?; let style: Int64 }
            let chats: [Row] = try db.query(
                """
                SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
                       (SELECT MAX(m.date) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = c.ROWID) AS last_date
                FROM chat c
                ORDER BY last_date DESC
                LIMIT ?
                """,
                bind: [limit]
            ) { s in
                Row(rowid: Self.int(s, 0), guid: Self.text(s, 1) ?? "", identifier: Self.text(s, 2) ?? "", display: Self.text(s, 3), service: Self.text(s, 4), style: Self.int(s, 5))
            }
            return try chats.map { chat in
                let participants: [String] = try db.query(
                    "SELECT h.id FROM handle h JOIN chat_handle_join chj ON chj.handle_id = h.ROWID WHERE chj.chat_id = ? ORDER BY h.id",
                    bind: [chat.rowid]
                ) { Self.text($0, 0) ?? "" }
                let last: [MessagesMessage] = try db.query(
                    Self.messageSelect + " WHERE cmj.chat_id = ? ORDER BY m.date DESC LIMIT 1", bind: [chat.rowid]
                ) { Self.message($0) }.compactMap { $0 }
                let unread: Int = try db.query(
                    "SELECT COUNT(*) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = ? AND m.is_read = 0 AND m.is_from_me = 0",
                    bind: [chat.rowid]
                ) { Int(Self.int($0, 0)) }.first ?? 0
                let display = chat.display?.isEmpty == false ? chat.display : nil
                return MessagesConversation(
                    id: chat.guid, chatIdentifier: chat.identifier, displayName: display, participants: participants,
                    service: chat.service, isGroup: chat.style == 43 || participants.count > 1,
                    lastMessageDate: last.first?.date, lastMessagePreview: last.first.map { String($0.text.prefix(120)) },
                    unreadCount: unread
                )
            }
        }
    }

    func read(_ query: MessagesReadQuery) async throws -> [MessagesMessage] {
        try await AppleServiceQueue.run { [self] in
            let db = try open()
            var clauses: [String] = []
            var binds: [Any?] = []
            if let chatId = query.chatId, !chatId.isEmpty {
                clauses.append("(c.guid = ? OR c.chat_identifier = ?)")
                binds += [chatId, chatId]
            }
            if let handle = query.handle, !handle.isEmpty {
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
            let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            binds.append(query.limit)
            let rows: [MessagesMessage] = try db.query(
                Self.messageSelect + whereSQL + " ORDER BY m.date DESC LIMIT ?", bind: binds
            ) { Self.message($0) }.compactMap { $0 }
            return rows.reversed()
        }
    }

    func unread(limit: Int) async throws -> [MessagesMessage] {
        try await AppleServiceQueue.run { [self] in
            let db = try open()
            return try db.query(
                Self.messageSelect + " WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 ORDER BY m.date DESC LIMIT ?",
                bind: [limit]
            ) { Self.message($0) }.compactMap { $0 }
        }
    }

    func search(_ text: String, limit: Int) async throws -> [MessagesMessage] {
        try await AppleServiceQueue.run { [self] in
            let db = try open()
            let pattern = "%\(text)%"
            let rows: [MessagesMessage] = try db.query(
                Self.messageSelect + " WHERE (m.text LIKE ? OR CAST(m.attributedBody AS TEXT) LIKE ?) ORDER BY m.date DESC LIMIT ?",
                bind: [pattern, pattern, limit * 3]
            ) { Self.message($0) }.compactMap { $0 }
            return Array(rows.filter { AppleServiceSupport.matches($0.text, query: text) }.prefix(limit))
        }
    }

    // MARK: Send

    func send(to recipient: String?, chatId: String?, text: String, service: MessagesSendService) async throws -> (
        service: String, target: String
    ) {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages") else {
            throw AppleToolError.unavailable("Messages could not be launched on this Mac.", retryable: true)
        }
        let literalText = AppleScriptBridge.literal(text)
        if let chatId, !chatId.isEmpty {
            _ = try await AppleScriptBridge.run(
                """
                tell application "Messages"
                    send \(literalText) to chat id \(AppleScriptBridge.literal(chatId))
                end tell
                """,
                permission: .automationMessages, appName: "Messages"
            )
            return ("chat", chatId)
        }
        guard let recipient, !recipient.isEmpty else {
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
        for serviceType in order {
            do {
                _ = try await AppleScriptBridge.run(
                    """
                    tell application "Messages"
                        set targetService to first account whose service type = \(serviceType) and enabled is true
                        set targetBuddy to participant \(AppleScriptBridge.literal(handle)) of targetService
                        send \(literalText) to targetBuddy
                    end tell
                    """,
                    permission: .automationMessages, appName: "Messages"
                )
                return (serviceType, handle)
            } catch let error as AppleToolError {
                if case .permissionDenied = error { throw error }
                lastError = error
            }
        }
        throw lastError ?? AppleToolError.execution("Messages could not send to \(handle).")
    }
}
