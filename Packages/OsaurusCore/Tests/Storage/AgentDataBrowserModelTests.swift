//
//  AgentDataBrowserModelTests.swift
//  OsaurusCoreTests
//
//  Paging-behavior tests for the Database workspace's row browser model,
//  driven against an in-memory SQLCipher `AgentDatabase` through the
//  model's injectable backend (no bridge singleton involved).
//
//  Coverage:
//   - First page + filtered COUNT land together; `hasMore` reflects the
//     query's truncation flag, not a hardcoded LIMIT.
//   - Incremental `loadMoreIfNeeded` walks the keyset cursor to the end
//     without duplicating or skipping rows (including rows that share
//     one `_updated_at` second).
//   - Active / Deleted / All filter modes produce the matching row sets
//     and counts.
//   - Resetting onto another table mid-flight discards stale results
//     (generation guard) instead of mixing two tables' rows.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentDataBrowserModelTests {

    // MARK: - Harness

    /// In-memory database plus the backend closure the model uses to
    /// query it. Mirrors `AgentDataBrowserModel.liveBackend`, minus the
    /// bridge.
    private func makeDatabase() throws -> (db: AgentDatabase, backend: AgentDataBrowserModel.Backend) {
        let db = AgentDatabase(agentId: UUID())
        try db.openInMemory()
        let backend = AgentDataBrowserModel.Backend { sql, params, limit, offset in
            try db.query(sql: sql, params: params, limit: limit, offset: offset)
        }
        return (db, backend)
    }

    @discardableResult
    private func seedNotes(_ db: AgentDatabase, count: Int, table: String = "notes") throws -> [Int64] {
        try db.createTable(
            name: table,
            purpose: "browser paging fixture",
            columns: [AgentColumnSpec(name: "title", type: "TEXT", nullable: false)],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        var ids: [Int64] = []
        for i in 0 ..< count {
            ids.append(
                try db.insert(
                    table: table,
                    row: ["title": .text("row \(i)")],
                    actor: .agent,
                    runId: nil
                )
            )
        }
        return ids
    }

    /// Schema columns as the workspace would pass them (from the schema
    /// snapshot). Derived from a live probe so the order matches `SELECT *`.
    private func schemaColumns(_ db: AgentDatabase, table: String = "notes") throws -> [AgentColumnInfo] {
        let probe = try db.query(sql: "SELECT * FROM \(table)", limit: 1)
        return probe.columns.map {
            AgentColumnInfo(name: $0, type: "TEXT", nullable: true, defaultValue: nil, primaryKey: $0 == "id")
        }
    }

    /// Polls until `condition` holds (the model resolves pages on detached
    /// tasks, so tests wait for the published state to settle).
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ what: String,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForSettle(_ model: AgentDataBrowserModel) async throws {
        try await waitUntil("page + count to settle") {
            !model.isLoadingFirstPage && !model.isLoadingMore
                && (model.totalCount != nil || model.loadError != nil)
        }
    }

    private func loadedIds(_ model: AgentDataBrowserModel) -> [Int64] {
        guard let idIdx = model.idColumnIndex else { return [] }
        return model.rows.compactMap { row in
            if case .integer(let n) = row[idIdx] { return n }
            return nil
        }
    }

    // MARK: - First page + count

    @Test func firstPageLoadsWithFilteredCount() async throws {
        let (db, backend) = try makeDatabase()
        try seedNotes(db, count: 25)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)

        model.load(table: "notes", schemaColumns: try schemaColumns(db), filter: .live)
        try await waitForSettle(model)

        #expect(model.rows.count == 10)
        #expect(model.totalCount == 25)
        #expect(model.hasMore)
        #expect(model.loadError == nil)
    }

    @Test func lastPageClearsHasMore() async throws {
        let (db, backend) = try makeDatabase()
        try seedNotes(db, count: 7)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)

        model.load(table: "notes", schemaColumns: try schemaColumns(db), filter: .live)
        try await waitForSettle(model)

        #expect(model.rows.count == 7)
        #expect(model.totalCount == 7)
        #expect(!model.hasMore)
    }

    // MARK: - Incremental paging

    @Test func loadMoreWalksToEndWithoutDuplicatesOrGaps() async throws {
        let (db, backend) = try makeDatabase()
        // Inserted in one burst, so many rows share a `_updated_at` second —
        // the `(_updated_at, id)` keyset tiebreaker must still visit each
        // row exactly once.
        let seeded = try seedNotes(db, count: 25)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)

        model.load(table: "notes", schemaColumns: try schemaColumns(db), filter: .live)
        try await waitForSettle(model)

        var guardRail = 0
        while model.hasMore, guardRail < 10 {
            guardRail += 1
            model.loadMoreIfNeeded()
            try await waitUntil("next page") { !model.isLoadingMore }
        }

        #expect(model.rows.count == 25)
        let ids = loadedIds(model)
        #expect(Set(ids) == Set(seeded), "keyset paging must visit every row exactly once")
        #expect(ids.count == Set(ids).count, "no row may be loaded twice")
    }

    @Test func loadMoreIsSingleFlight() async throws {
        let (db, backend) = try makeDatabase()
        try seedNotes(db, count: 25)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)
        model.load(table: "notes", schemaColumns: try schemaColumns(db), filter: .live)
        try await waitForSettle(model)

        // Burst of scroll-boundary triggers must coalesce into one request.
        model.loadMoreIfNeeded()
        model.loadMoreIfNeeded()
        model.loadMoreIfNeeded()
        try await waitUntil("burst page") { !model.isLoadingMore }

        #expect(model.rows.count == 20, "three overlapping triggers must fetch exactly one page")
    }

    // MARK: - Filter modes

    @Test func filterModesMatchSoftDeleteState() async throws {
        let (db, backend) = try makeDatabase()
        let ids = try seedNotes(db, count: 6)
        for id in ids.prefix(2) {
            _ = try db.softDelete(
                table: "notes",
                whereClause: ["id": .integer(id)],
                actor: .agent,
                runId: nil
            )
        }
        let columns = try schemaColumns(db)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)

        model.load(table: "notes", schemaColumns: columns, filter: .live)
        try await waitForSettle(model)
        #expect(model.rows.count == 4)
        #expect(model.totalCount == 4)

        model.load(table: "notes", schemaColumns: columns, filter: .deleted)
        try await waitForSettle(model)
        #expect(model.rows.count == 2)
        #expect(model.totalCount == 2)
        #expect(Set(loadedIds(model)) == Set(ids.prefix(2)))

        model.load(table: "notes", schemaColumns: columns, filter: .all)
        try await waitForSettle(model)
        #expect(model.rows.count == 6)
        #expect(model.totalCount == 6)
    }

    // MARK: - Stale-request handling

    @Test func resetMidFlightDiscardsStaleResults() async throws {
        let (db, backend) = try makeDatabase()
        try seedNotes(db, count: 15, table: "first")
        try seedNotes(db, count: 3, table: "second")
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)

        // Load the first table and immediately reset onto the second —
        // whichever async results arrive for the first generation must be
        // dropped, never appended to the second table's rows.
        model.load(table: "first", schemaColumns: try schemaColumns(db, table: "first"), filter: .live)
        model.load(table: "second", schemaColumns: try schemaColumns(db, table: "second"), filter: .live)
        try await waitForSettle(model)

        #expect(model.tableName == "second")
        #expect(model.rows.count == 3)
        #expect(model.totalCount == 3)
        #expect(!model.hasMore)
    }

    @Test func clearResetsAllState() async throws {
        let (db, backend) = try makeDatabase()
        try seedNotes(db, count: 5)
        let model = AgentDataBrowserModel(backend: backend, pageSize: 10)
        model.load(table: "notes", schemaColumns: try schemaColumns(db), filter: .live)
        try await waitForSettle(model)
        #expect(!model.rows.isEmpty)

        model.clear()
        #expect(model.tableName == nil)
        #expect(model.rows.isEmpty)
        #expect(model.totalCount == nil)
        #expect(!model.hasMore)

        // Give any in-flight generation a beat to land; it must be dropped.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.rows.isEmpty)
    }
}
