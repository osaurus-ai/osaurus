//
//  PalaceDatabaseTests.swift
//  osaurusTests
//
//  Schema, CRUD, dedup, scoping, and FTS-sync coverage for PalaceDatabase.
//  Runs against in-memory databases — never touches ~/.osaurus. The one
//  on-disk test (forward-version refusal) uses its own temp directory
//  with an explicit path, not OsaurusPaths.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PalaceDatabaseTests {

    private func makeDB() throws -> PalaceDatabase {
        let db = PalaceDatabase()
        try db.openInMemory()
        return db
    }

    /// Insert helper: ensures taxonomy then files one drawer.
    @discardableResult
    private func addDrawer(
        _ db: PalaceDatabase,
        wing: String = "test_wing",
        room: String = "general",
        content: String
    ) throws -> PalaceDrawer {
        let wingRow = try db.ensureWing(name: wing)
        let roomRow = try db.ensureRoom(wingId: wingRow.id, name: room)
        let drawer = PalaceDrawer(
            wingId: wingRow.id,
            roomId: roomRow.id,
            content: content,
            contentHash: PalaceDatabase.contentHash(content),
            createdAt: "2026-07-02T00:00:00Z"
        )
        try db.insertDrawer(drawer)
        return drawer
    }

    @Test func openInMemory_startsEmpty() throws {
        let db = try makeDB()
        #expect(try db.countDrawers() == 0)
        #expect(try db.listWings().isEmpty)
    }

    @Test func ensureWing_isIdempotent() throws {
        let db = try makeDB()
        let a = try db.ensureWing(name: "vault")
        let b = try db.ensureWing(name: "vault")
        #expect(a.id == b.id)
        #expect(try db.listWings().count == 1)
    }

    @Test func ensureRoom_isIdempotent_perWing() throws {
        let db = try makeDB()
        let wing = try db.ensureWing(name: "vault")
        let other = try db.ensureWing(name: "other")
        let r1 = try db.ensureRoom(wingId: wing.id, name: "dreams")
        let r2 = try db.ensureRoom(wingId: wing.id, name: "dreams")
        let r3 = try db.ensureRoom(wingId: other.id, name: "dreams")
        #expect(r1.id == r2.id)
        #expect(r1.id != r3.id)  // same name, different wing → different room
    }

    @Test func insert_get_roundTrip_isVerbatim() throws {
        let db = try makeDB()
        let content = "  Verbatim!  \n\twith whitespace preserved \u{1F409}  "
        let inserted = try addDrawer(db, content: content)
        let fetched = try db.getDrawer(id: inserted.id)
        #expect(fetched?.content == content)  // byte-for-byte, no trimming
        #expect(fetched?.contentHash == PalaceDatabase.contentHash(content))
    }

    @Test func findDrawerByHash_dedup() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "same content")
        let hash = PalaceDatabase.contentHash("same content")
        let hit = try db.findDrawer(
            wingId: drawer.wingId,
            roomId: drawer.roomId,
            contentHash: hash
        )
        #expect(hit?.id == drawer.id)
        let miss = try db.findDrawer(
            wingId: drawer.wingId,
            roomId: drawer.roomId,
            contentHash: PalaceDatabase.contentHash("different")
        )
        #expect(miss == nil)
    }

    @Test func insertDrawer_uniqueConstraint_dedupsAtDBLevel() throws {
        let db = try makeDB()
        let wing = try db.ensureWing(name: "w")
        let room = try db.ensureRoom(wingId: wing.id, name: "r")
        let content = "identical verbatim content"
        let hash = PalaceDatabase.contentHash(content)

        func drawer() -> PalaceDrawer {
            // Distinct ids — the dedup key is (wing, room, content_hash).
            PalaceDrawer(
                wingId: wing.id,
                roomId: room.id,
                content: content,
                contentHash: hash,
                createdAt: "2026-07-03T00:00:00Z"
            )
        }

        #expect(try db.insertDrawer(drawer()) == true)
        // Second identical-content insert collides with the UNIQUE
        // constraint → ON CONFLICT DO NOTHING → returns false, no new row.
        #expect(try db.insertDrawer(drawer()) == false)
        #expect(try db.countDrawers() == 1)
        // FTS mirror stayed consistent (trigger only fires on real insert).
        #expect(try db.ftsSearch(query: "verbatim", wingId: nil, roomId: nil, limit: 10).count == 1)

        // Same content in a DIFFERENT room is a distinct drawer.
        let room2 = try db.ensureRoom(wingId: wing.id, name: "r2")
        let other = PalaceDrawer(
            wingId: wing.id,
            roomId: room2.id,
            content: content,
            contentHash: hash,
            createdAt: "2026-07-03T00:00:00Z"
        )
        #expect(try db.insertDrawer(other) == true)
        #expect(try db.countDrawers() == 2)
    }

    @Test func updateDrawer_rewritesContentAndHash() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "before")
        let updated = try db.updateDrawerContent(id: drawer.id, content: "after")
        #expect(updated)
        let fetched = try db.getDrawer(id: drawer.id)
        #expect(fetched?.content == "after")
        #expect(fetched?.contentHash == PalaceDatabase.contentHash("after"))
        #expect(!(try db.updateDrawerContent(id: "nonexistent", content: "x")))
    }

    @Test func deleteDrawer_removesRowAndEmbedding() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "to be deleted")
        try db.storeEmbedding(drawerId: drawer.id, vector: [0.1, 0.2], model: "test")
        #expect(try db.deleteDrawer(id: drawer.id))
        #expect(try db.getDrawer(id: drawer.id) == nil)
        #expect(try db.loadEmbeddings(wingId: nil, roomId: nil).isEmpty)
        #expect(!(try db.deleteDrawer(id: drawer.id)))  // second delete: no row
    }

    @Test func listDrawers_scopesByWingAndRoom() throws {
        let db = try makeDB()
        try addDrawer(db, wing: "a", room: "r1", content: "one")
        try addDrawer(db, wing: "a", room: "r2", content: "two")
        try addDrawer(db, wing: "b", room: "r1", content: "three")

        let wingA = try #require(try db.getWing(name: "a"))
        let all = try db.listDrawers(wingId: nil, roomId: nil, limit: 100, offset: 0)
        let onlyA = try db.listDrawers(wingId: wingA.id, roomId: nil, limit: 100, offset: 0)
        let roomR1 = try db.ensureRoom(wingId: wingA.id, name: "r1")
        let onlyAR1 = try db.listDrawers(wingId: wingA.id, roomId: roomR1.id, limit: 100, offset: 0)

        #expect(all.count == 3)
        #expect(onlyA.count == 2)
        #expect(onlyAR1.count == 1)
        #expect(onlyAR1.first?.content == "one")
        // Scoped results are a subset of the global list (spec §13.1).
        let allIds = Set(all.map(\.id))
        #expect(Set(onlyA.map(\.id)).isSubset(of: allIds))
    }

    @Test func ftsSearch_findsInsertedContent_andTracksUpdatesDeletes() throws {
        let db = try makeDB()
        let drawer = try addDrawer(db, content: "the GraphQL migration decision")
        try addDrawer(db, content: "an unrelated note about swimming")

        let hits = try db.ftsSearch(query: "graphql", wingId: nil, roomId: nil, limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.drawer.id == drawer.id)

        // Update re-syncs the FTS mirror (au trigger).
        _ = try db.updateDrawerContent(id: drawer.id, content: "now about kubernetes")
        #expect(try db.ftsSearch(query: "graphql", wingId: nil, roomId: nil, limit: 10).isEmpty)
        #expect(try db.ftsSearch(query: "kubernetes", wingId: nil, roomId: nil, limit: 10).count == 1)

        // Delete drops it from the index (ad trigger).
        _ = try db.deleteDrawer(id: drawer.id)
        #expect(try db.ftsSearch(query: "kubernetes", wingId: nil, roomId: nil, limit: 10).isEmpty)
    }

    @Test func ftsSearch_isSafeWithQuotesAndOperators() throws {
        let db = try makeDB()
        try addDrawer(db, content: "content with \"quotes\" and AND OR NOT operators")
        // Must not throw an FTS5 syntax error — the query is token-quoted.
        let hits = try db.ftsSearch(
            query: "\"quotes\" AND(",
            wingId: nil,
            roomId: nil,
            limit: 10
        )
        #expect(hits.count == 1)
    }

    /// A model-hallucinated pagination value must not crash the app:
    /// `Int32(_: Int)` traps above Int32.max, so offset binds as int64.
    @Test func listDrawers_hugeOffset_doesNotTrap() throws {
        let db = try makeDB()
        try addDrawer(db, content: "only drawer")
        let drawers = try db.listDrawers(
            wingId: nil,
            roomId: nil,
            limit: 10,
            offset: 3_000_000_000
        )
        #expect(drawers.isEmpty)
    }

    @Test func ftsQuote_scrubsOperatorsAndQuotesTokens() {
        #expect(PalaceDatabase.ftsQuote("hello world") == "\"hello\" \"world\"")
        #expect(PalaceDatabase.ftsQuote("a AND (b OR c)") == "\"a\" \"AND\" \"b\" \"OR\" \"c\"")
        #expect(PalaceDatabase.ftsQuote("!!! ***") == "")
        #expect(PalaceDatabase.ftsQuote("semi-structured_data") == "\"semi-structured_data\"")
    }

    @Test func embeddings_roundTrip_andScoping() throws {
        let db = try makeDB()
        let d1 = try addDrawer(db, wing: "a", content: "first")
        let d2 = try addDrawer(db, wing: "b", content: "second")
        try db.storeEmbedding(drawerId: d1.id, vector: [1, 0, 0], model: "test")
        try db.storeEmbedding(drawerId: d2.id, vector: [0, 1, 0], model: "test")

        let all = try db.loadEmbeddings(wingId: nil, roomId: nil)
        #expect(all.count == 2)
        let wingA = try #require(try db.getWing(name: "a"))
        let scoped = try db.loadEmbeddings(wingId: wingA.id, roomId: nil)
        #expect(scoped.count == 1)
        #expect(scoped.first?.drawerId == d1.id)
        #expect(scoped.first?.vector == [1, 0, 0])

        // Upsert replaces.
        try db.storeEmbedding(drawerId: d1.id, vector: [0.5, 0.5, 0], model: "test2")
        let replaced = try db.loadEmbeddings(wingId: wingA.id, roomId: nil)
        #expect(replaced.first?.vector == [0.5, 0.5, 0])
        #expect(replaced.first?.model == "test2")
    }

    @Test func status_counts() throws {
        let db = try makeDB()
        let d = try addDrawer(db, wing: "a", room: "r1", content: "x")
        try addDrawer(db, wing: "a", room: "r2", content: "y")
        try db.storeEmbedding(drawerId: d.id, vector: [1], model: "test")
        #expect(try db.countWings() == 1)
        #expect(try db.countRooms() == 2)
        #expect(try db.countDrawers() == 2)
        #expect(try db.countEmbeddedDrawers() == 1)
    }

    @Test func forwardVersion_isRefused() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palace-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("palace.sqlite").path

        let first = PalaceDatabase()
        try first.open(atPath: path)
        try first.debugSetSchemaVersion(999)
        first.close()

        let second = PalaceDatabase()
        #expect(throws: (any Error).self) {
            try second.open(atPath: path)
        }
    }
}
