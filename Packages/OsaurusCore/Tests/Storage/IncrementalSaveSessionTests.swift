//
//  IncrementalSaveSessionTests.swift
//  osaurusTests
//
//  Verifies that the post-encryption `saveSession` writes only the
//  rows that actually changed instead of `DELETE all + INSERT all`.
//  Uses the public `contentHash(for:)` helper to detect when a row
//  would be re-written.
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IncrementalSaveSessionTests {

    private func openInMemory() throws -> ChatHistoryDatabase {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test
    func reSavingUnchangedSessionIsContentHashStable() throws {
        let db = try openInMemory()
        defer { db.close() }

        let session = ChatSessionData(
            id: UUID(),
            title: "Stable",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: [
                ChatTurnData(role: .user, content: "hello"),
                ChatTurnData(role: .assistant, content: "hi"),
            ],
            agentId: nil,
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil
        )

        try db.saveSession(session)
        let firstHashes = readContentHashes(db: db, sessionId: session.id)
        try db.saveSession(session)
        let secondHashes = readContentHashes(db: db, sessionId: session.id)

        #expect(firstHashes == secondHashes)
        #expect(firstHashes.count == 2)
    }

    @Test
    func appendingOneTurnLeavesPriorTurnHashesUnchanged() throws {
        let db = try openInMemory()
        defer { db.close() }

        var session = ChatSessionData(
            id: UUID(),
            title: "Append",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: [
                ChatTurnData(role: .user, content: "first"),
                ChatTurnData(role: .assistant, content: "second"),
            ],
            agentId: nil,
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil
        )
        try db.saveSession(session)
        let initialHashes = readContentHashes(db: db, sessionId: session.id)

        session.turns.append(ChatTurnData(role: .user, content: "third"))
        try db.saveSession(session)

        let afterHashes = readContentHashes(db: db, sessionId: session.id)
        #expect(afterHashes.count == 3)
        // First two turns' content_hash columns should be unchanged.
        let initialIds = Set(initialHashes.keys)
        for id in initialIds {
            #expect(initialHashes[id] == afterHashes[id])
        }
    }

    @Test
    func contentHashChangesWhenTurnContentChanges() throws {
        let original = ChatTurnData(role: .user, content: "v1")
        let edited = ChatTurnData(id: original.id, role: .user, content: "v2")
        #expect(ChatHistoryDatabase.contentHash(for: original) != ChatHistoryDatabase.contentHash(for: edited))
    }

    // MARK: - Helpers

    private func readContentHashes(db: ChatHistoryDatabase, sessionId: UUID) -> [String: String] {
        var out: [String: String] = [:]
        try? db.executeReadInTest("SELECT id, content_hash FROM turns WHERE session_id = ?1") { stmt in
            // bind sessionId
            sqlite3_bind_text(
                stmt,
                1,
                (sessionId.uuidString as NSString).utf8String,
                -1,
                unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            )
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let hash = String(cString: sqlite3_column_text(stmt, 1))
                out[id] = hash
            }
        }
        return out
    }
}

// MARK: - Test hook

extension ChatHistoryDatabase {
    /// Test-only helper: prepare the supplied SQL on this instance's
    /// connection and let the caller bind + step. Mirrors the private
    /// `prepareAndExecute` shape but is `internal` so XCTest tests
    /// inside the same module can use it.
    fileprivate func executeReadInTest(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
        #if DEBUG
            try queueRunForTest { connection in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                    throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
                }
                defer { sqlite3_finalize(s) }
                body(s)
            }
        #endif
    }
}
