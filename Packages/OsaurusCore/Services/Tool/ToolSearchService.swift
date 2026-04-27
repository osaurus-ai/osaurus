//
//  ToolSearchService.swift
//  osaurus
//
//  Wraps VecturaKit for hybrid search over the unified tool index.
//  Falls back gracefully when VecturaKit is unavailable.
//

import CryptoKit
import Foundation
import VecturaKit
import os

public enum ToolIndexLogger {
    static let search = Logger(subsystem: "ai.osaurus", category: "toolindex.search")
    static let service = Logger(subsystem: "ai.osaurus", category: "toolindex.service")
}

public struct ToolSearchResult: Sendable {
    public let entry: ToolIndexEntry
    public let searchScore: Float

    public init(entry: ToolIndexEntry, searchScore: Float) {
        self.entry = entry
        self.searchScore = searchScore
    }
}

public actor ToolSearchService {
    public static let shared = ToolSearchService()

    private static let defaultSearchThreshold: Float = 0.10

    private var vectorDB: VecturaKit?
    private var isInitialized = false
    private var reverseIdMap: [String: String] = [:]

    private init() {}

    // MARK: - Initialization

    public func initialize() async {
        guard !isInitialized else { return }

        let storageDir = OsaurusPaths.toolIndex().appendingPathComponent("vectura", isDirectory: true)

        for attempt in 1 ... 2 {
            do {
                OsaurusPaths.ensureExistsSilent(storageDir)

                let config = try VecturaConfig(
                    name: "osaurus-tools",
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
                ToolIndexLogger.search.info("VecturaKit initialized successfully for tools")
                break
            } catch {
                if attempt == 1 {
                    ToolIndexLogger.search.warning(
                        "VecturaKit init failed for tools, deleting storage to recover: \(error)"
                    )
                    try? FileManager.default.removeItem(at: storageDir)
                } else {
                    ToolIndexLogger.search.error("VecturaKit init failed for tools (search unavailable): \(error)")
                    vectorDB = nil
                }
            }
        }
    }

    /// Populate `reverseIdMap` from the SQL source of truth. Without
    /// this, a fresh launch opens the persistent VecturaKit dir but
    /// the in-memory `UUID → toolId` map is empty until the next
    /// `rebuildIndex()` runs. Search calls in that window get hits
    /// from VecturaKit, fail to map them back to tool IDs, and
    /// return `[]` — which then sends `PreflightCapabilitySearch`
    /// down the "fall back to full catalog" path that overflows
    /// Apple Foundation Models' 4K context window.
    ///
    /// Cheap: just iterates `ToolDatabase.loadAllEntries()` and
    /// derives the deterministic UUID for each entry. No network,
    /// no embeds, no VecturaKit calls.
    private func rehydrateReverseIdMap() {
        guard let entries = try? ToolDatabase.shared.loadAllEntries() else { return }
        for entry in entries {
            _ = deterministicUUID(for: entry.id)
        }
        ToolIndexLogger.search.info("Tool reverse-id map rehydrated with \(entries.count) entries")
    }

    // MARK: - Indexing

    public func indexEntry(_ entry: ToolIndexEntry, parameters: JSONValue? = nil) async {
        guard let db = vectorDB else { return }
        do {
            let id = deterministicUUID(for: entry.id)
            let text = buildIndexText(name: entry.name, description: entry.description, parameters: parameters)
            _ = try await db.addDocument(text: text, id: id)
        } catch {
            ToolIndexLogger.search.error("Failed to index tool \(entry.id): \(error)")
        }
    }

    public func removeEntry(id: String) async {
        guard let db = vectorDB else { return }
        do {
            let uuid = deterministicUUID(for: id)
            try await db.deleteDocuments(ids: [uuid])
            reverseIdMap.removeValue(forKey: uuid.uuidString)
        } catch {
            ToolIndexLogger.search.error("Failed to remove tool \(id) from index: \(error)")
        }
    }

    // MARK: - Search

    public func search(
        query: String,
        topK: Int = 10,
        threshold: Float? = nil
    ) async -> [ToolSearchResult] {
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

            let toolIds = results.compactMap { reverseIdMap[$0.id.uuidString] }
            guard !toolIds.isEmpty else { return [] }

            let enabledNames = await MainActor.run {
                Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
            }

            let toolIdSet = Set(toolIds)
            let entries = try ToolDatabase.shared.loadAllEntries()
                .filter { toolIdSet.contains($0.id) && enabledNames.contains($0.name) }
            let entryById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            return Array(
                toolIds.compactMap { toolId -> ToolSearchResult? in
                    guard let entry = entryById[toolId] else { return nil }
                    let uuid = deterministicUUID(for: toolId)
                    guard let score = scoreMap[uuid.uuidString] else { return nil }
                    return ToolSearchResult(entry: entry, searchScore: score)
                }
                .sorted { $0.searchScore > $1.searchScore }
                .prefix(topK)
            )
        } catch {
            ToolIndexLogger.search.error("Tool search failed: \(error)")
            return []
        }
    }

    // MARK: - Rebuild

    public func rebuildIndex() async {
        guard let db = vectorDB else { return }
        do {
            try await db.reset()
            reverseIdMap.removeAll()

            let toolParams: [String: JSONValue] = await MainActor.run {
                var result = [String: JSONValue]()
                for tool in ToolRegistry.shared.listTools() {
                    if let params = tool.parameters { result[tool.name] = params }
                }
                return result
            }

            let entries = try ToolDatabase.shared.loadAllEntries()
            var texts: [String] = []
            var ids: [UUID] = []
            texts.reserveCapacity(entries.count)
            ids.reserveCapacity(entries.count)
            for entry in entries {
                let id = deterministicUUID(for: entry.id)
                texts.append(
                    buildIndexText(
                        name: entry.name,
                        description: entry.description,
                        parameters: toolParams[entry.name]
                    )
                )
                ids.append(id)
            }
            if !texts.isEmpty {
                _ = try await db.addDocuments(texts: texts, ids: ids)
            }
            ToolIndexLogger.search.info("Tool index rebuilt with \(entries.count) entries")
        } catch {
            ToolIndexLogger.search.error("Failed to rebuild tool index: \(error)")
        }
    }

    // MARK: - Helpers

    private func buildIndexText(name: String, description: String, parameters: JSONValue?) -> String {
        let paramText = extractParameterText(from: parameters)
        if paramText.isEmpty {
            return "\(name) \(description)"
        }
        return "\(name) \(description) \(paramText)"
    }

    private func extractParameterText(from params: JSONValue?) -> String {
        guard case .object(let schema) = params,
            case .object(let properties) = schema["properties"]
        else { return "" }
        var parts: [String] = []
        for (key, value) in properties {
            parts.append(key)
            if case .object(let propSchema) = value,
                case .string(let desc) = propSchema["description"]
            {
                parts.append(desc)
            }
        }
        return parts.joined(separator: " ")
    }

    private func deterministicUUID(for toolId: String) -> UUID {
        let hash = SHA256.hash(data: Data("tool:\(toolId)".utf8))
        let bytes = Array(hash)
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        reverseIdMap[uuid.uuidString] = toolId
        return uuid
    }
}
