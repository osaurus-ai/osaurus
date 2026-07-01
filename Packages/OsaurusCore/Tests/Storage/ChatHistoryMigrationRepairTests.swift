//
//  ChatHistoryMigrationRepairTests.swift
//  osaurusTests
//
//  Regression coverage for the chat-history schema-migration repair.
//
//  Field reports surfaced stores stuck at `user_version = 1` whose columns
//  had already been added by a prior build (or reset by the encryption
//  convergence rebuild), missing only the newest column. With the old
//  non-idempotent migrations, `open()` re-ran `migrateToV2` and threw
//  `duplicate column name: content_hash`, never reaching the v8
//  `router_billing` ALTER. Because `selectTurnsSQL` / `insertTurnSQL`
//  reference `router_billing`, every `loadSession` then returned nil
//  (existing chats opened empty) and every `saveSession` threw (new chats
//  vanished on restart) — the "all my history is gone" symptom.
//
//  These tests pin the reproduced failure state and the partial variants,
//  asserting the now-idempotent migrations self-heal on the next `open()`:
//  columns that already exist are skipped, the missing ones are added, the
//  schema version reconciles to the latest, and existing + new data round
//  trips.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatHistoryMigrationRepairTests {

    // MARK: - Production v1 CREATE TABLE shapes

    private static let createSessionsV1 = """
        CREATE TABLE sessions (
            id                   TEXT PRIMARY KEY,
            title                TEXT NOT NULL,
            created_at           REAL NOT NULL,
            updated_at           REAL NOT NULL,
            selected_model       TEXT,
            agent_id             TEXT,
            source               TEXT NOT NULL DEFAULT 'chat',
            source_plugin_id     TEXT,
            external_session_key TEXT,
            dispatch_task_id     TEXT,
            turn_count           INTEGER NOT NULL DEFAULT 0
        )
        """

    private static let createTurnsV1 = """
        CREATE TABLE turns (
            id            TEXT PRIMARY KEY,
            session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq           INTEGER NOT NULL,
            role          TEXT NOT NULL,
            content       TEXT,
            attachments   TEXT,
            tool_calls    TEXT,
            tool_call_id  TEXT,
            tool_results  TEXT,
            thinking      TEXT NOT NULL DEFAULT ''
        )
        """

    // Per-version ALTERs mirroring `migrateToVN`, used to assemble
    // partially-migrated fixtures.
    private static let alterV2 = ["ALTER TABLE turns ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''"]
    private static let alterV3 = ["ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0"]
    private static let alterV4 = ["ALTER TABLE sessions ADD COLUMN capabilities TEXT NOT NULL DEFAULT ''"]
    private static let alterV5 = [
        "ALTER TABLE turns ADD COLUMN created_at REAL",
        "ALTER TABLE turns ADD COLUMN completed_at REAL",
        "ALTER TABLE turns ADD COLUMN generation_token_count INTEGER",
        "ALTER TABLE turns ADD COLUMN time_to_first_token REAL",
    ]
    private static let alterV6 = ["ALTER TABLE turns ADD COLUMN tool_call_durations TEXT"]
    private static let alterV7 = ["ALTER TABLE turns ADD COLUMN thinking_duration REAL"]
    private static let alterV8 = ["ALTER TABLE turns ADD COLUMN router_billing TEXT"]

    // MARK: - Reporter-exact: v1 stuck, every column except v8 router_billing

    /// The exact reproduced failure state: `user_version = 1`, all columns
    /// through v7 present, only `router_billing` missing. Opening must NOT
    /// throw, must add `router_billing`, must reconcile the version to 8,
    /// must return the pre-existing turns (not nil), and a fresh save must
    /// round-trip.
    @Test
    func stuckV1MissingRouterBillingHealsAndPreservesHistory() async throws {
        try await runWithPlaintextRoot {
            let sid = UUID()
            let userTurn = UUID()
            let assistantTurn = UUID()

            var statements = [Self.createSessionsV1]
            statements += Self.alterV3 + Self.alterV4
            statements.append(Self.createTurnsV1)
            statements += Self.alterV2 + Self.alterV5 + Self.alterV6 + Self.alterV7
            statements += [
                """
                INSERT INTO sessions (id, title, created_at, updated_at, source, turn_count, archived, capabilities)
                VALUES ('\(sid.uuidString)', 'Reporter chat', 1000, 2000, 'chat', 2, 0, '')
                """,
                """
                INSERT INTO turns (id, session_id, seq, role, content)
                VALUES ('\(userTurn.uuidString)', '\(sid.uuidString)', 0, 'user', 'hello from before the upgrade')
                """,
                """
                INSERT INTO turns (id, session_id, seq, role, content)
                VALUES ('\(assistantTurn.uuidString)', '\(sid.uuidString)', 1, 'assistant', 'hi, I remember our chat')
                """,
                "PRAGMA user_version = 1",
            ]
            try self.seedChatHistoryDB(statements)

            let db = ChatHistoryDatabase()
            try db.open()  // must not throw on the duplicate-column ALTER
            defer { db.close() }

            #expect(self.diskUserVersion() == 8)
            #expect(self.diskColumns(table: "turns").contains("router_billing"))

            let loaded = db.loadSession(id: sid)
            #expect(loaded != nil)
            #expect(loaded?.turns.count == 2)
            #expect(loaded?.turns.first?.role == .user)
            #expect(loaded?.turns.first?.content == "hello from before the upgrade")
            #expect(loaded?.turns.last?.role == .assistant)

            let newId = UUID()
            let newSession = ChatSessionData(
                id: newId,
                title: "New chat after repair",
                turns: [ChatTurnData(role: .user, content: "fresh turn after repair")]
            )
            try db.saveSession(newSession)
            let reloaded = db.loadSession(id: newId)
            #expect(reloaded?.turns.count == 1)
            #expect(reloaded?.turns.first?.content == "fresh turn after repair")
        }
    }

    // MARK: - v1 stuck, every v2-v8 column already present

    /// A store whose `user_version` is stuck at 1 but already carries every
    /// column (including v8). Every migration ALTER must be skipped, the
    /// version reconciled to 8, and data must still load + save.
    @Test
    func stuckV1WithAllColumnsPresentOpensCleanly() async throws {
        try await runWithPlaintextRoot {
            let sid = UUID()

            var statements = [Self.createSessionsV1]
            statements += Self.alterV3 + Self.alterV4
            statements.append(Self.createTurnsV1)
            statements += Self.alterV2 + Self.alterV5 + Self.alterV6 + Self.alterV7 + Self.alterV8
            statements += [
                """
                INSERT INTO sessions (id, title, created_at, updated_at, source, turn_count, archived, capabilities)
                VALUES ('\(sid.uuidString)', 'All columns', 1000, 2000, 'chat', 1, 0, '')
                """,
                """
                INSERT INTO turns (id, session_id, seq, role, content)
                VALUES ('\(UUID().uuidString)', '\(sid.uuidString)', 0, 'user', 'already fully columned')
                """,
                "PRAGMA user_version = 1",
            ]
            try self.seedChatHistoryDB(statements)

            let db = ChatHistoryDatabase()
            try db.open()
            defer { db.close() }

            #expect(self.diskUserVersion() == 8)
            let loaded = db.loadSession(id: sid)
            #expect(loaded?.turns.count == 1)
            #expect(loaded?.turns.first?.content == "already fully columned")

            let newId = UUID()
            try db.saveSession(
                ChatSessionData(
                    id: newId,
                    title: "Save works",
                    turns: [ChatTurnData(role: .assistant, content: "ok")]
                )
            )
            #expect(db.loadSession(id: newId)?.turns.count == 1)
        }
    }

    // MARK: - v1 stuck, missing the earlier v3/v4 session columns

    /// A store stalled before the v3/v4 session columns: `content_hash`
    /// present but `archived`/`capabilities` missing. Here it is the
    /// metadata path (`loadAllMetadata` / `saveSession`) that breaks
    /// pre-fix. Opening must add the columns, reconcile to 8, and both the
    /// sidebar metadata query and saves must succeed.
    @Test
    func stuckV1MissingArchivedAndCapabilitiesHeals() async throws {
        try await runWithPlaintextRoot {
            let sid = UUID()

            var statements = [Self.createSessionsV1, Self.createTurnsV1]
            statements += Self.alterV2  // content_hash only; no archived/capabilities, no v5-v8
            statements += [
                """
                INSERT INTO sessions (id, title, created_at, updated_at, source, turn_count)
                VALUES ('\(sid.uuidString)', 'Legacy partial', 1000, 2000, 'chat', 1)
                """,
                """
                INSERT INTO turns (id, session_id, seq, role, content)
                VALUES ('\(UUID().uuidString)', '\(sid.uuidString)', 0, 'user', 'partial migration row')
                """,
                "PRAGMA user_version = 1",
            ]
            try self.seedChatHistoryDB(statements)

            let db = ChatHistoryDatabase()
            try db.open()
            defer { db.close() }

            #expect(self.diskUserVersion() == 8)
            #expect(self.diskColumns(table: "sessions").contains("archived"))
            #expect(self.diskColumns(table: "sessions").contains("capabilities"))

            // Sidebar metadata query (references archived/capabilities) works.
            let metadata = db.loadAllMetadata()
            #expect(metadata.contains { $0.id == sid })
            // Full load + new save both succeed.
            #expect(db.loadSession(id: sid)?.turns.count == 1)
            let newId = UUID()
            try db.saveSession(
                ChatSessionData(id: newId, title: "post-heal", turns: [ChatTurnData(role: .user, content: "hi")])
            )
            #expect(db.loadSession(id: newId)?.turns.count == 1)
        }
    }

    // MARK: - Fresh database

    /// Guard against migration regressions: a brand-new (empty) database
    /// migrates 0 -> 8 cleanly and round-trips a session.
    @Test
    func freshDatabaseMigratesToLatestAndRoundTrips() async throws {
        try await runWithPlaintextRoot {
            let db = ChatHistoryDatabase()
            try db.open()
            defer { db.close() }

            #expect(self.diskUserVersion() == 8)

            let id = UUID()
            try db.saveSession(
                ChatSessionData(
                    id: id,
                    title: "Fresh",
                    turns: [
                        ChatTurnData(role: .user, content: "q"),
                        ChatTurnData(role: .assistant, content: "a"),
                    ]
                )
            )
            #expect(db.loadSession(id: id)?.turns.count == 2)
        }
    }

    // MARK: - Helpers

    /// Run `body` with an isolated temp root in plaintext storage posture,
    /// matching the reporter's `mode = plaintext` so a pre-seeded plaintext
    /// file opens via detection without touching the Keychain.
    private func runWithPlaintextRoot(_ body: @Sendable () throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-migration-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()
            try body()
        }
    }

    /// Create the chat-history DB file (plaintext) at the overridden path
    /// and run the given raw SQL statements in order.
    private func seedChatHistoryDB(_ statements: [String]) throws {
        let path = OsaurusPaths.chatHistoryDatabaseFile().path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: nil)
        defer { sqlite3_close(conn) }
        for sql in statements {
            try exec(conn, sql)
        }
    }

    private func exec(_ conn: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(conn, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(
                domain: "ChatHistoryMigrationRepairTests",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    /// Run `body` against an independent read-only connection to the on-disk
    /// chat-history file, returning `fallback` if it can't be opened. WAL mode
    /// is a persistent property of the file, so this second connection reads
    /// the committed migration result while the primary handle is still open.
    private func withDiskConnection<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        guard
            let conn = try? EncryptedSQLiteOpener.open(
                path: OsaurusPaths.chatHistoryDatabaseFile().path,
                key: nil,
                applyPerfPragmas: false,
                applyForeignKeys: false
            )
        else { return fallback }
        defer { sqlite3_close(conn) }
        return body(conn)
    }

    /// Read `PRAGMA user_version` from disk.
    private func diskUserVersion() -> Int {
        withDiskConnection(-1) { conn in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
        }
    }

    /// The column names currently on `table`, read from disk.
    private func diskColumns(table: String) -> Set<String> {
        withDiskConnection([]) { conn in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(conn, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            var columns: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) {
                    columns.insert(String(cString: c))
                }
            }
            return columns
        }
    }
}
