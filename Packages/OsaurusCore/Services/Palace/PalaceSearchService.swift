//
//  PalaceSearchService.swift
//  osaurus
//
//  Scoped retrieval for Palace. Phase 0 strategy:
//    1. vector: embed the query, brute-force cosine over stored embeddings
//       (fine well past the <1k-drawer Phase 0 target; VecturaKit or an
//       ANN index replaces this in Phase 1 behind a PalaceVectorStore
//       protocol).
//    2. fallback: FTS5 MATCH when the backend is "none", the query embed
//       fails, or no drawer has a vector yet.
//  Pure functions are static so ranking is unit-testable without a model.
//

import Foundation

public enum PalaceSearchService {

    /// Top-level search. Never throws: retrieval degradation (no model, no
    /// vectors) falls back to FTS; a scoping miss returns [].
    public static func search(
        query: String,
        wing wingName: String?,
        room roomName: String?,
        limit: Int,
        db: PalaceDatabase,
        config: PalaceConfiguration
    ) async -> [PalaceSearchHit] {
        // Resolve scope names → ids (and bail early on unknown scope).
        var wingId: String?
        var roomId: String?
        if let wingName {
            guard let wing = ((try? db.getWing(name: wingName)) ?? nil) else { return [] }
            wingId = wing.id
            if let roomName {
                guard let room = ((try? db.getRoom(wingId: wing.id, name: roomName)) ?? nil) else {
                    return []
                }
                roomId = room.id
            }
        }

        let limit = max(1, min(limit, 50))

        if config.embeddingBackend == "mlx" {
            if let hits = await vectorSearch(
                query: query,
                wingId: wingId,
                roomId: roomId,
                limit: limit,
                maxDistance: config.maxDistance,
                db: db
            ),
                !hits.isEmpty
            {
                return resolveNames(hits: hits, db: db)
            }
        }
        let ftsHits =
            (try? db.ftsSearch(query: query, wingId: wingId, roomId: roomId, limit: limit)) ?? []
        let mapped = ftsHits.map { hit in
            // bm25 rank is lower-is-better (typically negative). Negate for
            // a uniform higher-is-better score in the envelope.
            RankedDrawer(drawerId: hit.drawer.id, drawer: hit.drawer, score: -hit.rank, matchType: .fts)
        }
        return resolveNames(hits: mapped, db: db)
    }

    // MARK: - Vector path

    private static func vectorSearch(
        query: String,
        wingId: String?,
        roomId: String?,
        limit: Int,
        maxDistance: Double,
        db: PalaceDatabase
    ) async -> [RankedDrawer]? {
        guard
            let queryVector = try? await EmbeddingService.shared.embed(texts: [query]).first,
            !queryVector.isEmpty
        else { return nil }
        guard
            let candidates = try? db.loadEmbeddings(wingId: wingId, roomId: roomId),
            !candidates.isEmpty
        else { return nil }

        let ranked = rank(
            queryVector: queryVector,
            candidates: candidates,
            limit: limit,
            maxDistance: maxDistance
        )
        return ranked.compactMap { scored in
            guard let drawer = ((try? db.getDrawer(id: scored.drawerId)) ?? nil) else { return nil }
            return RankedDrawer(
                drawerId: scored.drawerId,
                drawer: drawer,
                score: scored.score,
                matchType: .vector
            )
        }
    }

    struct ScoredId: Sendable {
        let drawerId: String
        let score: Double
    }

    struct RankedDrawer: Sendable {
        let drawerId: String
        let drawer: PalaceDrawer
        let score: Double
        let matchType: PalaceSearchHit.MatchType
    }

    /// Brute-force cosine ranking. `maxDistance` uses cosine distance
    /// (1 - similarity); 2.0 admits everything. Dimension-mismatched
    /// candidates (stale rows from a different embedding model) are
    /// excluded outright before scoring — see the inline note on why a
    /// 0 score is NOT safe to rely on under the default maxDistance.
    static func rank(
        queryVector: [Float],
        candidates: [PalaceDatabase.EmbeddingRow],
        limit: Int,
        maxDistance: Double
    ) -> [ScoredId] {
        candidates
            // Dimension-mismatched vectors (stale rows from a different
            // embedding model) are excluded outright rather than scored 0 —
            // a zero score passes the default maxDistance (1.5) and the
            // junk hits would suppress the FTS fallback entirely.
            .filter { $0.vector.count == queryVector.count }
            .map { ScoredId(drawerId: $0.drawerId, score: cosineSimilarity(queryVector, $0.vector)) }
            .filter { (1.0 - $0.score) <= maxDistance }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Plain-Swift cosine similarity. 128-dim × ≤1k candidates is
    /// microseconds; no Accelerate dependency needed in Phase 0.
    /// Returns 0 for zero vectors or dimension mismatch (skip, don't crash).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0 ..< a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / ((normA * normB).squareRoot())
    }

    // MARK: - Name resolution

    /// Attach wing/room names to hits (taxonomy is small; a two-map lookup
    /// beats a three-way join here).
    private static func resolveNames(hits: [RankedDrawer], db: PalaceDatabase) -> [PalaceSearchHit] {
        guard !hits.isEmpty else { return [] }
        let wings = (try? db.listWings()) ?? []
        let wingById = Dictionary(uniqueKeysWithValues: wings.map { ($0.id, $0) })
        var roomNameById: [String: String] = [:]
        for wing in wings {
            for room in (try? db.listRooms(wingId: wing.id)) ?? [] {
                roomNameById[room.id] = room.name
            }
        }
        return hits.map { hit in
            PalaceSearchHit(
                drawer: hit.drawer,
                wingName: wingById[hit.drawer.wingId]?.name ?? "?",
                roomName: roomNameById[hit.drawer.roomId] ?? "?",
                score: hit.score,
                matchType: hit.matchType
            )
        }
    }
}
