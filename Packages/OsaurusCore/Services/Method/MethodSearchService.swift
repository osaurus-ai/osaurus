//
//  MethodSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search (BM25 + vector) over methods.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public actor MethodSearchService {
    public static let shared = MethodSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.methods().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try VecturaConfig(
                    name: "osaurus-methods",
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

                vectorDB = try await VecturaKit(config: config, embedder: EmbeddingService.sharedEmbedder)
                isInitialized = true
                rehydrateReverseIdMap()
                MethodLogger.search.info("VecturaKit initialized successfully for methods")
                break
            } catch {
                if attempt == 1 {
                    MethodLogger.search.warning(
                        "VecturaKit init failed for methods, deleting storage to recover: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    MethodLogger.search.error("VecturaKit init failed for methods (search unavailable): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    /// See `ToolSearchService.rehydrateReverseIdMap` for the rationale.
    /// Without this, search returns empty until `rebuildIndex()`
    /// completes, and callers like `PreflightCapabilitySearch.rankCatalog`
    /// fall back to over-large catalogs that overflow small-context
    /// LLMs.
    private func rehydrateReverseIdMap() {
        guard let methods = try? MethodDatabase.shared.loadAllMethods() else { return }
        for method in methods {
            _ = deterministicUUID(for: method.id)
        }
        MethodLogger.search.info("Method reverse-id map rehydrated with \(methods.count) entries")
    }

    // MARK: - Indexing

    public func indexMethod(_ method: Method) async {
        guard let db = vectorDB else { return }
        do {
            let toolDescs = Self.loadToolDescriptions()
            let id = deterministicUUID(for: method.id)
            let text = buildIndexText(for: method, toolDescriptions: toolDescs)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            MethodLogger.search.error("Failed to index method \(method.id): \(error)")
        }
    }

    public func removeMethod(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            MethodLogger.search.error("Failed to remove method \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [MethodSearchResult] {
        guard topK > 0 else { return [] }
        guard let db = vectorDB else { return [] }
        do {
            let fetchCount = topK * 3
            let results = try await db.search(
                query: .text(query),
                numResults: fetchCount,
                threshold: threshold ?? Self.defaultSearchThreshold
            )

            let scoreMap = Dictionary(
                results.map { ($0.id.uuidString, Float($0.score)) },
                uniquingKeysWith: { first, _ in first }
            )

            let methodIds = results.compactMap { reverseIdMap[$0.id.uuidString] }

            let methods = try MethodDatabase.shared.loadMethodsByIds(methodIds)
            let scores = try methodIds.compactMap { try MethodDatabase.shared.loadScore(methodId: $0) }
            let scoreByMethod = Dictionary(scores.map { ($0.methodId, $0) }, uniquingKeysWith: { first, _ in first })

            return Array(
                methods.compactMap { method -> MethodSearchResult? in
                    let uuid = deterministicUUID(for: method.id)
                    guard let searchScore = scoreMap[uuid.uuidString] else { return nil }
                    let methodScore = scoreByMethod[method.id]?.score ?? 0.0
                    return MethodSearchResult(method: method, searchScore: searchScore, score: methodScore)
                }
                .sorted { $0.searchScore > $1.searchScore }
                .prefix(topK)
            )
        } catch {
            MethodLogger.search.error("Method search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let toolDescs = Self.loadToolDescriptions()

            let methods = try MethodDatabase.shared.loadAllMethods()
            var texts: [String] = []
            var ids: [UUID] = []
            texts.reserveCapacity(methods.count)
            ids.reserveCapacity(methods.count)
            for method in methods {
                let id = deterministicUUID(for: method.id)
                texts.append(buildIndexText(for: method, toolDescriptions: toolDescs))
                ids.append(id)
            }
            if !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }
            MethodLogger.search.info("Method index rebuilt with \(methods.count) methods")
        } catch {
            MethodLogger.search.error("Failed to rebuild method index: \(error)")
        }
    }

    // MARK: - Helpers

    private var reverseIdMap: [String: String] = [:]

    private func buildIndexText(for method: Method, toolDescriptions: [String: String] = [:]) -> String {
        var text = method.description
        if let trigger = method.triggerText, !trigger.isEmpty {
            text += " " + trigger
        }
        for toolName in method.toolsUsed {
            text += " \(toolName)"
            if let desc = toolDescriptions[toolName] {
                text += " \(desc)"
            }
        }
        return text
    }

    private static func loadToolDescriptions() -> [String: String] {
        do {
            return try ToolDatabase.shared.loadAllEntries()
                .reduce(into: [String: String]()) { $0[$1.name] = $1.description }
        } catch {
            return [:]
        }
    }

    private func deterministicUUID(for methodId: String) -> UUID {
        let hash = SHA256.hash(data: Data("method:\(methodId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = methodId
        return uuid
    }
}
