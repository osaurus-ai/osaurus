//
//  PalaceSearchServiceTests.swift
//  osaurusTests
//
//  Pure ranking tests (hand-made vectors, no embedding model) + the FTS
//  fallback path with embeddingBackend "none" (no model needed in CI).
//  The vector path with a real model is exercised only in dev builds
//  where potion-base-4M is installed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PalaceSearchServiceTests {

    @Test func cosineSimilarity_ordersAndNormalizes() {
        // Identical direction → 1; orthogonal → 0; opposite → -1.
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [2, 0]) - 1.0) < 1e-6)
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [0, 3])) < 1e-6)
        #expect(abs(PalaceSearchService.cosineSimilarity([1, 0], [-1, 0]) + 1.0) < 1e-6)
        // Zero vector → 0 (not NaN).
        #expect(PalaceSearchService.cosineSimilarity([0, 0], [1, 0]) == 0)
        // Dimension mismatch → 0 (skipped, not crashed).
        #expect(PalaceSearchService.cosineSimilarity([1, 0, 0], [1, 0]) == 0)
    }

    @Test func rank_returnsTopKAboveThreshold() {
        let candidates: [PalaceDatabase.EmbeddingRow] = [
            .init(drawerId: "far", model: "t", vector: [-1, 0]),
            .init(drawerId: "near", model: "t", vector: [1, 0]),
            .init(drawerId: "mid", model: "t", vector: [0.7, 0.7]),
        ]
        let ranked = PalaceSearchService.rank(
            queryVector: [1, 0],
            candidates: candidates,
            limit: 2,
            maxDistance: 1.5
        )
        #expect(ranked.map(\.drawerId) == ["near", "mid"])
        // maxDistance 1.5 → similarity ≥ -0.5 → "far" (sim -1, distance 2)
        // is excluded even when the limit permits.
        let rankedAll = PalaceSearchService.rank(
            queryVector: [1, 0],
            candidates: candidates,
            limit: 10,
            maxDistance: 1.5
        )
        #expect(!rankedAll.map(\.drawerId).contains("far"))
    }

    /// Stale rows from a different embedding model (wrong dimension) are
    /// excluded outright — a zero score would pass the default maxDistance
    /// and the junk hits would suppress the FTS fallback.
    @Test func rank_excludesDimensionMismatchedCandidates() {
        let candidates: [PalaceDatabase.EmbeddingRow] = [
            .init(drawerId: "stale-256d", model: "old", vector: [1, 0, 0]),
            .init(drawerId: "current", model: "new", vector: [1, 0]),
        ]
        let ranked = PalaceSearchService.rank(
            queryVector: [1, 0],
            candidates: candidates,
            limit: 10,
            maxDistance: 2.0  // admits everything that gets scored
        )
        #expect(ranked.map(\.drawerId) == ["current"])
    }

    @Test func search_fallsBackToFTS_whenBackendNone() async throws {
        let db = PalaceDatabase()
        try db.openInMemory()
        let wing = try db.ensureWing(name: "w")
        let room = try db.ensureRoom(wingId: wing.id, name: "r")
        let content = "verbatim quote about lucid dreaming"
        let drawer = PalaceDrawer(
            wingId: wing.id,
            roomId: room.id,
            content: content,
            contentHash: PalaceDatabase.contentHash(content),
            createdAt: "2026-07-02T00:00:00Z"
        )
        try db.insertDrawer(drawer)

        var config = PalaceConfiguration()
        config.embeddingBackend = "none"
        let hits = await PalaceSearchService.search(
            query: "lucid dreaming",
            wing: nil,
            room: nil,
            limit: 5,
            db: db,
            config: config
        )
        #expect(hits.count == 1)
        #expect(hits.first?.matchType == .fts)
        #expect(hits.first?.drawer.id == drawer.id)
        #expect(hits.first?.wingName == "w")
        #expect(hits.first?.roomName == "r")
    }

    @Test func search_scopesByWing() async throws {
        let db = PalaceDatabase()
        try db.openInMemory()
        for wingName in ["alpha", "beta"] {
            let wing = try db.ensureWing(name: wingName)
            let room = try db.ensureRoom(wingId: wing.id, name: "r")
            let content = "shared topic banana in \(wingName)"
            try db.insertDrawer(
                PalaceDrawer(
                    wingId: wing.id,
                    roomId: room.id,
                    content: content,
                    contentHash: PalaceDatabase.contentHash(content),
                    createdAt: "2026-07-02T00:00:00Z"
                )
            )
        }
        var config = PalaceConfiguration()
        config.embeddingBackend = "none"
        let scoped = await PalaceSearchService.search(
            query: "banana",
            wing: "alpha",
            room: nil,
            limit: 10,
            db: db,
            config: config
        )
        #expect(scoped.count == 1)
        #expect(scoped.first?.wingName == "alpha")
        // Unknown wing → empty, not a global leak.
        let unknown = await PalaceSearchService.search(
            query: "banana",
            wing: "nope",
            room: nil,
            limit: 10,
            db: db,
            config: config
        )
        #expect(unknown.isEmpty)
    }
}
