//
//  MemorySearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search (BM25 + vector) over the memory database.
//  Falls back to SQLite LIKE-based search when VecturaKit is unavailable.
//  The VecturaKit index is derived from SQLite data and can be rebuilt at any time.
//

import CryptoKit
import Foundation
import VecturaKit

public actor MemorySearchService {
    public static let shared = MemorySearchService()

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    /// Initialize the VecturaKit index. Called once at app startup.
    /// Non-fatal — search falls back to text if this fails.
    public func initialize() async {
        guard !isInitialized else { return }

        do {
            let storageDir = OsaurusPaths.memory().appendingPathComponent("vectura", isDirectory: true)
            OsaurusPaths.ensureExistsSilent(storageDir)

            let config = try VecturaConfig(
                name: "osaurus-memory",
                directoryURL: storageDir,
                searchOptions: VecturaConfig.SearchOptions(
                    defaultNumResults: 10,
                    minThreshold: 0.3,
                    hybridWeight: 0.5,
                    k1: 1.2,
                    b: 0.75
                )
            )

            let embedder = SwiftEmbedder(modelSource: .default)
            vectorDB = try await VecturaKit(config: config, embedder: embedder)
            isInitialized = true
            print("[Memory] VecturaKit initialized successfully")
        } catch {
            print("[Memory] VecturaKit initialization failed (text search fallback active): \(error)")
            vectorDB = nil
        }
    }

    // MARK: - Indexing

    /// Index a memory entry for hybrid search.
    public func indexMemoryEntry(_ entry: MemoryEntry) async {
        guard let db = vectorDB else { return }
        do {
            let id = UUID(uuidString: entry.id) ?? UUID()
            _ = try await db.addDocument(text: "[\(entry.type.rawValue)] \(entry.content)", id: id)
        } catch {
            print("[Memory] Failed to index entry \(entry.id): \(error)")
        }
    }

    /// Index a conversation chunk for hybrid search.
    public func indexConversationChunk(_ chunk: ConversationChunk) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(from: "chunk:\(chunk.conversationId):\(chunk.chunkIndex)")
            _ = try await db.addDocument(text: chunk.content, id: id)
        } catch {
            print("[Memory] Failed to index chunk: \(error)")
        }
    }

    /// Index a conversation summary for hybrid search.
    public func indexSummary(_ summary: ConversationSummary) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(from: "summary:\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)")
            _ = try await db.addDocument(text: summary.summary, id: id)
        } catch {
            print("[Memory] Failed to index summary: \(error)")
        }
    }

    /// Remove a document from the index.
    public func removeDocument(id: String) async {
        guard let db = vectorDB, let uuid = UUID(uuidString: id) else { return }
        do {
            try await db.deleteDocuments(ids: [uuid])
        } catch {
            print("[Memory] Failed to remove document \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    /// Search memory entries using hybrid search (vector + BM25).
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchMemoryEntries(
        query: String,
        agentId: String? = nil,
        topK: Int = 10
    ) async -> [MemoryEntry] {
        if let db = vectorDB {
            do {
                let results = try await db.search(query: .text(query), numResults: topK, threshold: 0.3)
                let matchedIds = Set(results.map { $0.id.uuidString })
                let allEntries = (try? MemoryDatabase.shared.loadAllActiveEntries()) ?? []
                return allEntries.filter { entry in
                    let idMatch = matchedIds.contains(entry.id)
                    let agentMatch = agentId == nil || entry.agentId == agentId
                    return idMatch && agentMatch
                }
            } catch {
                print("[Memory] Vector search failed, falling back to text: \(error)")
            }
        }

        return (try? MemoryDatabase.shared.searchMemoryEntries(query: query, agentId: agentId)) ?? []
    }

    /// Search conversation chunks using hybrid search (vector + BM25).
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchConversations(
        query: String,
        agentId: String? = nil,
        days: Int = 30
    ) async -> [ConversationChunk] {
        if let db = vectorDB {
            do {
                let results = try await db.search(query: .text(query), numResults: 20, threshold: 0.3)
                let matchedIds = Set(results.map { $0.id })
                let allChunks = (try? MemoryDatabase.shared.loadAllChunks(agentId: agentId, days: days)) ?? []
                let matched = allChunks.filter { chunk in
                    let chunkUUID = deterministicUUID(from: "chunk:\(chunk.conversationId):\(chunk.chunkIndex)")
                    return matchedIds.contains(chunkUUID)
                }
                if !matched.isEmpty { return matched }
            } catch {
                print("[Memory] Vector search for chunks failed, falling back to text: \(error)")
            }
        }

        return (try? MemoryDatabase.shared.searchChunks(query: query, agentId: agentId, days: days)) ?? []
    }

    /// Search conversation summaries using hybrid search (vector + BM25).
    /// Falls back to SQLite text search when VecturaKit is unavailable.
    public func searchSummaries(
        query: String,
        agentId: String? = nil,
        days: Int = 30
    ) async -> [ConversationSummary] {
        if let db = vectorDB {
            do {
                let results = try await db.search(query: .text(query), numResults: 20, threshold: 0.3)
                let matchedIds = Set(results.map { $0.id })
                let allSummaries = (try? MemoryDatabase.shared.loadAllSummaries(days: days)) ?? []
                let matched = allSummaries.filter { summary in
                    let summaryUUID = deterministicUUID(from: "summary:\(summary.agentId):\(summary.conversationId):\(summary.conversationAt)")
                    let agentMatch = agentId == nil || summary.agentId == agentId
                    return matchedIds.contains(summaryUUID) && agentMatch
                }
                if !matched.isEmpty { return matched }
            } catch {
                print("[Memory] Vector search for summaries failed, falling back to text: \(error)")
            }
        }

        return (try? MemoryDatabase.shared.searchSummaries(query: query, agentId: agentId, days: days)) ?? []
    }

    // MARK: - Index Management

    /// Rebuild the entire VecturaKit index from SQLite data.
    public func rebuildIndex() async {
        guard let db = vectorDB else { return }

        do {
            try await db.reset()

            let entries = (try? MemoryDatabase.shared.loadAllActiveEntries()) ?? []
            let texts = entries.map { "[\($0.type.rawValue)] \($0.content)" }
            let ids = entries.compactMap { UUID(uuidString: $0.id) }
            if texts.count == ids.count && !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }

            print("[Memory] Index rebuilt with \(entries.count) entries")
        } catch {
            print("[Memory] Index rebuild failed: \(error)")
        }
    }

    public var isVecturaAvailable: Bool {
        vectorDB != nil
    }

    // MARK: - Helpers

    /// Generate a deterministic UUID from a string using SHA-256.
    private func deterministicUUID(from string: String) -> UUID {
        let hash = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
