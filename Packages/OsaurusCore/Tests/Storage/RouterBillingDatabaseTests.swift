//
//  RouterBillingDatabaseTests.swift
//  osaurusTests
//
//  Round-trip + prune + migration coverage for the on-device, metadata-only
//  router billing ledger. Runs against an in-memory SQLCipher database so it
//  doesn't touch the user's Keychain, the real `~/.osaurus` tree, or
//  `StorageMutationGate`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RouterBillingDatabaseTests {

    /// Whole-second "now". `createdAt` is persisted as a SQLite REAL via
    /// `timeIntervalSince1970`; the epoch shift loses sub-second precision on a
    /// Double, so truncating to whole seconds keeps the round-trip bit-exact for
    /// strict `Equatable` comparisons (and stays inside the retention window).
    private static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    private func makeDB() throws -> RouterBillingDatabase {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        return db
    }

    private func makeEntry(
        id: String = UUID().uuidString,
        requestId: String? = "router-request-1",
        createdAt: Date = RouterBillingDatabaseTests.now,
        outcome: RouterBillingOutcome = .pending,
        cost: String = "1234",
        outputTokens: Int = 3
    ) -> RouterBillingEntry {
        RouterBillingEntry(
            id: id,
            requestId: requestId,
            createdAt: createdAt,
            sessionId: UUID().uuidString,
            turnId: UUID().uuidString,
            model: "venice/minimax-m3",
            tokenSource: "provider",
            inputTokens: 11,
            outputTokens: outputTokens,
            costMicro: cost,
            status: "completed",
            outcome: outcome,
            appVersion: "1.2.3"
        )
    }

    @Test func openInMemory_startsEmpty() throws {
        let db = try makeDB()
        #expect(try db.count() == 0)
        #expect(try db.recent(limit: 10).isEmpty)
    }

    @Test func insert_thenRecent_roundTripsAllFields() throws {
        let db = try makeDB()
        let entry = makeEntry()
        try db.insert(entry)

        let rows = try db.recent(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first == entry)
    }

    @Test func recent_ordersNewestFirst() throws {
        let db = try makeDB()
        let older = makeEntry(createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeEntry(createdAt: Date(timeIntervalSince1970: 2_000))
        try db.insert(older)
        try db.insert(newer)

        let rows = try db.recent(limit: 10)
        #expect(rows.map(\.id) == [newer.id, older.id])
    }

    @Test func recent_supportsOffsetPagination() throws {
        let db = try makeDB()
        let oldest = makeEntry(createdAt: Date(timeIntervalSince1970: 1_000))
        let middle = makeEntry(createdAt: Date(timeIntervalSince1970: 2_000))
        let newest = makeEntry(createdAt: Date(timeIntervalSince1970: 3_000))
        try db.insert(oldest)
        try db.insert(middle)
        try db.insert(newest)

        let rows = try db.recent(limit: 1, offset: 1)
        #expect(rows.map(\.id) == [middle.id])
    }

    @Test func updateOutcome_finalizesPendingRow() throws {
        let db = try makeDB()
        let entry = makeEntry(outcome: .pending)
        try db.insert(entry)

        try db.updateOutcome(entryId: entry.id, outcome: .empty)

        let row = try #require(try db.recent(limit: 1).first)
        #expect(row.outcome == .empty)
        // Only the outcome changes — the charge is immutable.
        #expect(row.costMicro == entry.costMicro)
        #expect(row.outputTokens == entry.outputTokens)
    }

    @Test func insert_sameEntryId_upsertsInsteadOfDuplicating() throws {
        let db = try makeDB()
        let entry = makeEntry(outcome: .pending)
        try db.insert(entry)
        var updated = entry
        updated.outcome = .rendered
        try db.insert(updated)

        #expect(try db.count() == 1)
        #expect(try db.recent(limit: 1).first?.outcome == .rendered)
    }

    @Test func pruneIfNeeded_dropsRowsOlderThanRetentionWindow() throws {
        let db = try makeDB()
        let stale = makeEntry(
            createdAt: Self.now.addingTimeInterval(
                -Double(RouterBillingDatabase.maxRetentionDays + 1) * 86_400
            )
        )
        let fresh = makeEntry(createdAt: Self.now)
        try db.insert(stale)
        try db.insert(fresh)

        try db.pruneIfNeeded()

        let rows = try db.recent(limit: 10)
        #expect(rows.map(\.id) == [fresh.id])
    }

    @Test func pruneIfNeeded_keepsRowsUnderCap() throws {
        let db = try makeDB()
        for i in 0 ..< 5 {
            try db.insert(makeEntry(createdAt: Self.now.addingTimeInterval(Double(i))))
        }

        try db.pruneIfNeeded()

        #expect(try db.count() == 5)
    }
}
