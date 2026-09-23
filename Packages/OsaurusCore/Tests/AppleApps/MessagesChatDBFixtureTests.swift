//
//  MessagesChatDBFixtureTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Drives `ChatDBMessagesService` against a synthetic chat.db (same tables
//  and columns Messages uses) so the read paths are pinned without Full
//  Disk Access: attributedBody-only rows are searchable, tapbacks and
//  system items are filtered, attachment-only rows read `[attachment]`,
//  LIKE metacharacters are escaped, and a missing database is `unavailable`
//  rather than `permission_denied`.
//

import Foundation
import SQLite3
import Testing

@testable import OsaurusCore

private enum ChatDBFixture {
    /// Build the typedstream-ish blob `decodeAttributedBody` understands.
    static func attributedBody(_ text: String) -> Data {
        var data = Data([0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64])
        data.append(contentsOf: Array("NSString".utf8))
        data.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])
        let bytes = Array(text.utf8)
        if bytes.count < 0x80 {
            data.append(UInt8(bytes.count))
        } else {
            data.append(0x81)
            data.append(UInt8(bytes.count & 0xFF))
            data.append(UInt8((bytes.count >> 8) & 0xFF))
        }
        data.append(contentsOf: bytes)
        data.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x49])
        return data
    }

    struct Row {
        var guid: String
        var chat: Int
        var handle: Int?
        var fromMe: Bool
        var minutesAgo: Int
        var text: String?
        var body: Data?
        var isRead: Bool = true
        var itemType: Int = 0
        var associated: Int = 0
        var attachments: Bool = false
        var error: Int = 0
    }

    static func make(rows: [Row]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-chatdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chat.db")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "rc \(rc)"
                sqlite3_free(err)
                Issue.record("sqlite: \(message) — \(sql)")
                throw AppleToolError.execution(message)
            }
        }
        try exec(
            """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, service TEXT,
                date INTEGER, is_from_me INTEGER, is_read INTEGER, item_type INTEGER, associated_message_type INTEGER,
                cache_has_attachments INTEGER, error INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO handle VALUES (1, '+14155550100', 'iMessage');
            INSERT INTO handle VALUES (2, 'bob@example.com', 'iMessage');
            INSERT INTO chat VALUES (1, 'iMessage;-;+14155550100', '+14155550100', NULL, 'iMessage', 45);
            INSERT INTO chat VALUES (2, 'iMessage;+;chat777', 'chat777', 'Weekend crew', 'iMessage', 43);
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO chat_handle_join VALUES (2, 1);
            INSERT INTO chat_handle_join VALUES (2, 2);
            """
        )
        let now = Date()
        for (i, row) in rows.enumerated() {
            let rowid = i + 1
            let date = ChatDBMessagesService.appleTime(from: now.addingTimeInterval(TimeInterval(-60 * row.minutesAgo)))
            var stmt: OpaquePointer?
            let sql =
                "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, service, date, is_from_me, is_read, item_type, associated_message_type, cache_has_attachments, error) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
            try #require(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(stmt, 1, Int64(rowid))
            sqlite3_bind_text(stmt, 2, row.guid, -1, transient)
            if let text = row.text { sqlite3_bind_text(stmt, 3, text, -1, transient) } else { sqlite3_bind_null(stmt, 3) }
            if let body = row.body {
                body.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(body.count), transient) }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let handle = row.handle { sqlite3_bind_int64(stmt, 5, Int64(handle)) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_text(stmt, 6, "iMessage", -1, transient)
            sqlite3_bind_int64(stmt, 7, date)
            sqlite3_bind_int64(stmt, 8, row.fromMe ? 1 : 0)
            sqlite3_bind_int64(stmt, 9, row.isRead ? 1 : 0)
            sqlite3_bind_int64(stmt, 10, Int64(row.itemType))
            sqlite3_bind_int64(stmt, 11, Int64(row.associated))
            sqlite3_bind_int64(stmt, 12, row.attachments ? 1 : 0)
            sqlite3_bind_int64(stmt, 13, Int64(row.error))
            try #require(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
            try exec("INSERT INTO chat_message_join VALUES (\(row.chat), \(rowid))")
        }
        return url
    }
}

@Suite("Apple tools: Messages over a synthetic chat.db", .serialized)
struct MessagesChatDBFixtureTests {
    private func fixture() throws -> ChatDBMessagesService {
        let url = try ChatDBFixture.make(rows: [
            // Plain-text legacy row.
            .init(guid: "m-old", chat: 1, handle: 1, fromMe: false, minutesAgo: 600, text: "lunch tomorrow?"),
            // Modern rows: text NULL, body only in attributedBody.
            .init(guid: "m-body", chat: 1, handle: 1, fromMe: false, minutesAgo: 30, text: nil, body: ChatDBFixture.attributedBody("Dentist at 3pm, 50% off"), isRead: false),
            .init(guid: "m-mine", chat: 1, handle: nil, fromMe: true, minutesAgo: 20, text: nil, body: ChatDBFixture.attributedBody("ok see you at the dentist")),
            // Tapback referencing m-body (associated 2000 = love).
            .init(guid: "m-tapback", chat: 1, handle: 1, fromMe: false, minutesAgo: 19, text: "Loved “Dentist at 3pm”", isRead: false, associated: 2000),
            // Group rename system item.
            .init(guid: "m-rename", chat: 2, handle: 1, fromMe: false, minutesAgo: 15, text: nil, itemType: 2),
            // Attachment-only message (placeholder text).
            .init(guid: "m-photo", chat: 2, handle: 2, fromMe: false, minutesAgo: 10, text: "\u{FFFC}", isRead: false, attachments: true),
            .init(guid: "m-group", chat: 2, handle: 2, fromMe: false, minutesAgo: 5, text: nil, body: ChatDBFixture.attributedBody("who's bringing snacks_?"), isRead: false),
        ])
        return ChatDBMessagesService(databaseURL: url)
    }

    @Test("search finds attributedBody-only messages and ignores tapbacks")
    func searchDecodesBodies() async throws {
        let service = try fixture()
        let hits = try await service.search("dentist", limit: 10)
        #expect(hits.map(\.id) == ["m-mine", "m-body"], "\(hits.map(\.id))")
        #expect(hits.last?.text == "Dentist at 3pm, 50% off")
    }

    @Test("search escapes LIKE metacharacters and matches literally")
    func searchEscapesLike() async throws {
        let service = try fixture()
        #expect(try await service.search("50% off", limit: 10).map(\.id) == ["m-body"])
        #expect(try await service.search("snacks_?", limit: 10).map(\.id) == ["m-group"])
        #expect(try await service.search("50%_off", limit: 10).isEmpty, "`_` must not act as a wildcard")
        #expect(ChatDBMessagesService.likePattern("a%b_c\\") == "%a\\%b\\_c\\\\%")
    }

    @Test("read filters system items and tapbacks, renders attachment-only rows, oldest first")
    func readFilters() async throws {
        let service = try fixture()
        var query = MessagesReadQuery()
        query.chatId = " iMessage;+;chat777 "
        let rows = try await service.read(query)
        #expect(rows.map(\.id) == ["m-photo", "m-group"])
        #expect(rows.first?.text == "[attachment]")
        #expect(rows.first?.hasAttachments == true)

        var byHandle = MessagesReadQuery()
        byHandle.handle = "(415) 555-0100"
        let handleRows = try await service.read(byHandle)
        #expect(!handleRows.map(\.id).contains("m-tapback"))
        #expect(handleRows.map(\.id).contains("m-body"))
    }

    @Test("unread uses the same content predicate everywhere")
    func unreadPredicate() async throws {
        let service = try fixture()
        let unread = try await service.unread(limit: 10)
        #expect(Set(unread.map(\.id)) == ["m-body", "m-photo", "m-group"])
        let convos = try await service.conversations(limit: 10)
        #expect(convos.first?.id == "iMessage;+;chat777")
        #expect(convos.first?.unreadCount == 2)
        #expect(convos.first?.participants == ["+14155550100", "bob@example.com"])
        #expect(convos.first?.isGroup == true)
        #expect(convos.first?.lastMessagePreview == "who's bringing snacks_?")
        #expect(convos.last?.unreadCount == 1, "the tapback is not counted as unread")
        #expect(convos.last?.lastMessagePreview == "ok see you at the dentist", "the tapback is not the preview")
    }

    @Test("a missing database is `unavailable`, not a Full Disk Access denial")
    func missingDatabase() async throws {
        let service = ChatDBMessagesService(
            databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-missing-\(UUID().uuidString)/chat.db"))
        do {
            _ = try await service.unread(limit: 1)
            Issue.record("expected an error")
        } catch let error as AppleToolError {
            guard case .unavailable(let message, let retryable) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(message.contains("No Messages database"))
            #expect(retryable == false)
        }
    }

    @Test("bodyText strips U+FFFC and falls back to [attachment]")
    func bodyText() {
        #expect(ChatDBMessagesService.bodyText(text: "\u{FFFC}", attributedBody: nil, hasAttachments: true) == "[attachment]")
        #expect(ChatDBMessagesService.bodyText(text: "\u{FFFC}", attributedBody: nil, hasAttachments: false) == "")
        #expect(ChatDBMessagesService.bodyText(text: "hi \u{FFFC}there", attributedBody: nil, hasAttachments: true) == "hi there")
        #expect(ChatDBMessagesService.bodyText(text: nil, attributedBody: ChatDBFixture.attributedBody("x"), hasAttachments: false) == "x")
    }
}
