//
//  KnowledgeSearchService.swift
//  osaurus
//
//  Hybrid search (BM25 + vector) over knowledge collection chunks.
//  Falls back to SQLite FTS text matching when VecturaKit is
//  unavailable or vector work is not allowed (MLX model resident).
//
//  Partitioning mirrors the per-agent memory layout: each collection's
//  vectors live in their own VecturaKit instance under
//  `~/.osaurus/knowledge/vectura/<collectionId>/`, so a search scoped
//  to an agent's granted collections structurally cannot return
//  another collection's vectors — it never opens those indexes.
//
//  The vector index is a derived artifact: `knowledge.sqlite` (itself
//  derived from the markdown folders) is the rebuild source, so a
//  degraded or deleted vector directory only costs a rebuild.
//

import Foundation
import VecturaKit
import os

public actor KnowledgeSearchService {
    public static let shared = KnowledgeSearchService()

    private static let defaultSearchThreshold: Float = 0.10
    private static let defaultFetchMultiplier: Double = 2.0

    /// Per-collection VecturaKit instances, keyed by collection id string.
    /// Created lazily on first index/search for that collection.
    private var vectorDBs: [String: VecturaKit] = [:]

    /// Reverse map from VecturaKit UUID → chunk composite key
    /// (collectionId, relPath, chunkIndex). Populated on indexing and
    /// rebuilt lazily on a map miss.
    private var chunkKeyMap: [String: (collectionId: String, relPath: String, chunkIndex: Int)] = [:]

    private init() {}

    // MARK: - Vector identity

    /// Deterministic vector id for a chunk so re-indexing a document
    /// overwrites its previous vectors instead of duplicating them.
    static func vectorId(collectionId: String, relPath: String, chunkIndex: Int) -> UUID {
        TextSimilarity.deterministicUUID(from: "knowledge:\(collectionId):\(relPath):\(chunkIndex)")
    }

    private static func storageDir(for collectionId: String) -> URL {
        guard let uuid = UUID(uuidString: collectionId) else {
            return OsaurusPaths.knowledge()
                .appendingPathComponent("vectura", isDirectory: true)
                .appendingPathComponent(collectionId, isDirectory: true)
        }
        return OsaurusPaths.knowledgeVecturaDirectory(for: uuid)
    }

    private func ensureVectorDB(for collectionId: String) async -> VecturaKit? {
        if let existing = vectorDBs[collectionId] { return existing }

        let storageDir = Self.storageDir(for: collectionId)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)
                let config = try VecturaConfig(
                    name: "osaurus-knowledge-\(collectionId)",
                    directoryURL: storageDir,
                    dimension: EmbeddingService.embeddingDimension,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.3,
                        hybridWeight: 0.5,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )
                let db = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                vectorDBs[collectionId] = db
                KnowledgeLogger.search.info("VecturaKit ready for collection=\(collectionId)")
                return db
            } catch {
                if attempt == 1 {
                    KnowledgeLogger.search.warning(
                        "VecturaKit init failed for \(collectionId), deleting + retrying: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    KnowledgeLogger.search.error(
                        "VecturaKit init failed (text fallback active): \(error)"
                    )
                }
            }
        }
        return nil
    }

    /// Same residency guard as memory: never compete with a resident MLX
    /// model for GPU memory; the FTS path still serves search meanwhile.
    private func vectorWorkAllowed(_ operation: String) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["OSAURUS_DISABLE_KNOWLEDGE_VECTOR_SEARCH"] == "1"
            || env["OSAURUS_DISABLE_KNOWLEDGE_VECTOR_SEARCH"]?.lowercased() == "true"
        {
            KnowledgeLogger.search.warning("Skipping VecturaKit \(operation); disabled by environment")
            return false
        }

        let residentModels = await ModelRuntime.shared.cachedModelSummaries()
        guard residentModels.isEmpty else {
            let names = residentModels.map(\.name).joined(separator: ",")
            KnowledgeLogger.search.warning(
                "Skipping VecturaKit \(operation) while MLX model resident (\(names)); using FTS fallback"
            )
            return false
        }
        return true
    }

    // MARK: - Indexing

    /// Index (or overwrite) the vectors for a document's chunks.
    public func indexChunks(_ hits: [KnowledgeChunkHit]) async {
        guard !hits.isEmpty, await vectorWorkAllowed("indexChunks") else { return }
        for hit in hits {
            guard let db = await ensureVectorDB(for: hit.collectionId) else { return }
            let id = Self.vectorId(
                collectionId: hit.collectionId,
                relPath: hit.relPath,
                chunkIndex: hit.chunkIndex
            )
            do {
                let text = hit.headingPath.isEmpty ? hit.content : hit.headingPath + "\n" + hit.content
                _ = try await db.addDocument(text: text, id: id)
                chunkKeyMap[id.uuidString] = (hit.collectionId, hit.relPath, hit.chunkIndex)
            } catch {
                KnowledgeLogger.search.error("indexChunks failed for \(hit.compositeKey): \(error)")
            }
        }
    }

    /// Remove the vectors of a deleted or shrunk document. `chunkCount`
    /// is the previous chunk count; ids are deterministic so removal
    /// needs no lookup.
    public func removeChunks(collectionId: String, relPath: String, chunkCount: Int) async {
        guard chunkCount > 0, let db = vectorDBs[collectionId] else { return }
        var ids: [UUID] = []
        for index in 0 ..< chunkCount {
            let id = Self.vectorId(collectionId: collectionId, relPath: relPath, chunkIndex: index)
            ids.append(id)
            chunkKeyMap.removeValue(forKey: id.uuidString)
        }
        try? await db.deleteDocuments(ids: ids)
    }

    /// Drop a collection's vector index entirely (registry delete).
    public func removeCollection(collectionId: String) async {
        if let db = vectorDBs.removeValue(forKey: collectionId) {
            try? await db.reset()
        }
        chunkKeyMap = chunkKeyMap.filter { $0.value.collectionId != collectionId }
        try? FileManager.default.removeItem(at: Self.storageDir(for: collectionId))
    }

    /// Discard and regenerate a collection's vectors from the SQLite
    /// index rows (e.g. after a storage key rotation or index failure).
    public func rebuildCollection(collectionId: String) async {
        await removeCollection(collectionId: collectionId)
        guard await vectorWorkAllowed("rebuildCollection") else { return }
        let chunks = (try? KnowledgeDatabase.shared.allChunks(collectionId: collectionId)) ?? []
        await indexChunks(chunks)
        KnowledgeLogger.search.info(
            "Rebuilt knowledge vectors for collection=\(collectionId): \(chunks.count) chunks"
        )
    }

    // MARK: - Search

    /// Hybrid search across the supplied collections (the caller passes
    /// only the agent's granted, enabled collections — scoping is
    /// structural). Vector+BM25 per collection bucket, merged by score;
    /// SQLite FTS fallback when vectors are unavailable.
    public func search(
        query: String,
        collectionIds: [String],
        topK: Int = 8
    ) async -> [KnowledgeChunkHit] {
        guard topK > 0, !collectionIds.isEmpty else { return [] }

        if await vectorWorkAllowed("search") {
            var scored: [(hit: KnowledgeChunkHit, score: Double)] = []
            var sawVectorResults = false
            let fetchCount = Int(Double(topK) * Self.defaultFetchMultiplier)

            for collectionId in collectionIds {
                guard let db = await ensureVectorDB(for: collectionId) else { continue }
                do {
                    let results = try await db.search(
                        query: .text(query),
                        numResults: fetchCount,
                        threshold: Self.defaultSearchThreshold
                    )
                    sawVectorResults = sawVectorResults || !results.isEmpty

                    var keys: [(collectionId: String, relPath: String, chunkIndex: Int)] = []
                    var scores: [String: Double] = [:]
                    var missedMap = false
                    for r in results {
                        if let key = chunkKeyMap[r.id.uuidString] {
                            keys.append(key)
                            scores["\(key.collectionId):\(key.relPath):\(key.chunkIndex)"] = Double(r.score)
                        } else {
                            missedMap = true
                        }
                    }
                    if missedMap {
                        rebuildChunkKeyMap(collectionId: collectionId)
                        keys.removeAll()
                        scores.removeAll()
                        for r in results {
                            if let key = chunkKeyMap[r.id.uuidString] {
                                keys.append(key)
                                scores["\(key.collectionId):\(key.relPath):\(key.chunkIndex)"] = Double(r.score)
                            }
                        }
                    }

                    let hits = (try? KnowledgeDatabase.shared.loadChunksByCompositeKeys(keys)) ?? []
                    for hit in hits {
                        if let score = scores[hit.compositeKey] {
                            scored.append((hit, score))
                        }
                    }
                } catch {
                    KnowledgeLogger.search.error(
                        "vector search failed for collection=\(collectionId): \(error)"
                    )
                }
            }

            if sawVectorResults, !scored.isEmpty {
                var seen: Set<String> = []
                var merged: [KnowledgeChunkHit] = []
                for entry in scored.sorted(by: { $0.score > $1.score }) {
                    guard seen.insert(entry.hit.compositeKey).inserted else { continue }
                    merged.append(entry.hit)
                    if merged.count == topK { break }
                }
                return merged
            }
        }

        do {
            return try KnowledgeDatabase.shared.searchChunksText(
                query: query,
                collectionIds: collectionIds,
                limit: topK
            )
        } catch {
            KnowledgeLogger.search.error("FTS fallback failed: \(error)")
            return []
        }
    }

    // MARK: - Lazy reverse-map building

    private func rebuildChunkKeyMap(collectionId: String) {
        let chunks = (try? KnowledgeDatabase.shared.allChunks(collectionId: collectionId)) ?? []
        for chunk in chunks {
            let id = Self.vectorId(
                collectionId: chunk.collectionId,
                relPath: chunk.relPath,
                chunkIndex: chunk.chunkIndex
            )
            chunkKeyMap[id.uuidString] = (chunk.collectionId, chunk.relPath, chunk.chunkIndex)
        }
    }
}
