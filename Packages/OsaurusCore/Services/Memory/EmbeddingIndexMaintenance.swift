//
//  EmbeddingIndexMaintenance.swift
//  osaurus
//
//  Each semantic index lives in a directory named after the embedding
//  profile, and a state file records which model each one was last fully
//  built with. When the launch profile differs from that record, the index
//  is rebuilt from its source of truth after launch; until then search
//  falls back to text matching for that store.
//

import Foundation
import os

enum EmbeddingIndexStore: String, CaseIterable, Codable, Sendable {
    case tools, skills, methods, memory, knowledge

    var title: String {
        switch self {
        case .tools: return L("Tools")
        case .skills: return L("Skills")
        case .methods: return L("Methods")
        case .memory: return L("Memory")
        case .knowledge: return L("Knowledge")
        }
    }
}

/// `config/embedding-index-state.json`: store → model id of its last
/// complete build. A store with no entry was built by the built-in model,
/// which is the only model earlier versions used.
enum EmbeddingIndexStateStore {
    private static let overrideDirectory = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private static let writeLock = NSLock()
    private static let fileName = "embedding-index-state.json"
    private static let rebuildingPrefix = "rebuilding:"

    static func setOverrideDirectory(_ url: URL?) {
        overrideDirectory.withLock { $0 = url }
    }

    static func indexedModelId(for store: EmbeddingIndexStore) -> String {
        load()[store.rawValue] ?? EmbeddingProfile.builtInModelId
    }

    static func needsRebuild(_ store: EmbeddingIndexStore, modelId: String) -> Bool {
        indexedModelId(for: store).caseInsensitiveCompare(modelId) != .orderedSame
    }

    /// Recorded before a rebuild starts, so a rebuild cut short by quitting
    /// still reads as stale on the next launch.
    static func markRebuilding(_ store: EmbeddingIndexStore, modelId: String) {
        update(store, value: rebuildingPrefix + modelId)
    }

    static func markComplete(_ store: EmbeddingIndexStore, modelId: String) {
        update(store, value: modelId)
    }

    private static func update(_ store: EmbeddingIndexStore, value: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        var state = load()
        state[store.rawValue] = value
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save embedding index state: \(error)")
        }
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL()),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func fileURL() -> URL {
        (overrideDirectory.withLock { $0 } ?? OsaurusPaths.config()).appendingPathComponent(fileName)
    }
}

@MainActor
final class EmbeddingIndexMaintenance: ObservableObject {
    static let shared = EmbeddingIndexMaintenance()

    enum Phase: Equatable {
        case queued
        case rebuilding
        /// Vector work is deferred (a local model is resident, or the store
        /// isn't open yet). Retried while the app runs.
        case deferred
        case done
    }

    @Published private(set) var phases: [EmbeddingIndexStore: Phase] = [:]
    private var isRunning = false

    private static let retryInterval: Duration = .seconds(60)
    private static let maxRetries = 60
    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingIndex")

    private init() {}

    /// Stores still waiting for a complete build under the launch profile.
    var pendingStores: [EmbeddingIndexStore] {
        EmbeddingIndexStore.allCases.filter { phases[$0] != nil && phases[$0] != .done }
    }

    var activeStore: EmbeddingIndexStore? {
        EmbeddingIndexStore.allCases.first { phases[$0] == .rebuilding }
    }

    func runAfterLaunch() async {
        guard !isRunning, let profile = EmbeddingService.activeProfile else { return }
        var stale = EmbeddingIndexStore.allCases.filter {
            EmbeddingIndexStateStore.needsRebuild($0, modelId: profile.modelId)
        }
        guard !stale.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        for store in stale { phases[store] = .queued }
        Self.logger.info(
            "Rebuilding \(stale.map(\.rawValue).joined(separator: ","), privacy: .public) for \(profile.modelId, privacy: .public)"
        )

        var attempt = 0
        while !stale.isEmpty {
            var remaining: [EmbeddingIndexStore] = []
            for store in stale {
                phases[store] = .rebuilding
                EmbeddingIndexStateStore.markRebuilding(store, modelId: profile.modelId)
                if await rebuild(store) {
                    EmbeddingIndexStateStore.markComplete(store, modelId: profile.modelId)
                    phases[store] = .done
                } else {
                    phases[store] = .deferred
                    remaining.append(store)
                }
            }
            stale = remaining
            attempt += 1
            guard !stale.isEmpty, attempt < Self.maxRetries else { break }
            try? await Task.sleep(for: Self.retryInterval)
        }
    }

    private func rebuild(_ store: EmbeddingIndexStore) async -> Bool {
        switch store {
        case .tools:
            return await ToolSearchService.shared.rebuildIndex()
        case .skills:
            return await SkillSearchService.shared.rebuildIndex()
        case .methods:
            return await MethodSearchService.shared.rebuildIndex()
        case .memory:
            return await MemorySearchService.shared.rebuildIndexFromScratch()
        case .knowledge:
            // Per-chunk receipts drive the re-embed and resume it after a
            // restart, so the store is complete once every collection is queued.
            await KnowledgeManager.shared.ensureLoaded()
            for collection in KnowledgeManager.shared.collections {
                await KnowledgeSearchService.shared.rebuildCollection(collectionId: collection.id.uuidString)
            }
            return true
        }
    }
}
