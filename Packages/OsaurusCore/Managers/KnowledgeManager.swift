//
//  KnowledgeManager.swift
//  osaurus
//
//  MainActor registry for knowledge collections. Owns collection
//  lifecycle (create / update / delete) and resolves agent grant id
//  lists to enabled collections. Indexing and search live in the
//  knowledge services; this manager only holds registry state.
//

import Foundation

extension Notification.Name {
    /// Posted after any knowledge collection mutation (create, update,
    /// delete) so views and the index service can react.
    public static let knowledgeCollectionsChanged = Notification.Name("knowledgeCollectionsChanged")
}

@MainActor
public final class KnowledgeManager: ObservableObject {
    public static let shared = KnowledgeManager()

    /// All registered collections, sorted by name.
    @Published public private(set) var collections: [KnowledgeCollection] = []

    private init() {
        collections = KnowledgeCollectionStore.loadAll()
    }

    // MARK: - Lookup

    public func collection(for id: UUID) -> KnowledgeCollection? {
        collections.first { $0.id == id }
    }

    /// Case-insensitive name lookup, used to resolve the model-supplied
    /// `collection` tool argument.
    public func collection(named name: String) -> KnowledgeCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return collections.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Resolve a grant id list to its enabled collections, preserving the
    /// grant order. Unknown ids (deleted collections still referenced by
    /// an agent's settings) and disabled collections are dropped.
    public func enabledCollections(withIds ids: [UUID]) -> [KnowledgeCollection] {
        ids.compactMap { id in
            guard let collection = collection(for: id), collection.isEnabled else { return nil }
            return collection
        }
    }

    // MARK: - Lifecycle

    public func reload() {
        collections = KnowledgeCollectionStore.loadAll()
    }

    @discardableResult
    public func create(name: String, summary: String = "", folderPath: String) async -> KnowledgeCollection {
        var collection = KnowledgeCollection(name: name, summary: summary, folderPath: folderPath)
        // Adopting a folder that is already a git repo: remember its
        // `origin` so the card shows the link and Sync can pull/push.
        // A repo without a remote stays local-only (gitRemoteURL nil).
        if collection.isGitRepository {
            collection.gitRemoteURL = await KnowledgeGitSyncService.shared.remoteURL(of: collection.folderURL)
        }
        KnowledgeCollectionStore.save(collection)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id)
        scheduleIndex(of: collection)
        return collection
    }

    public func update(_ collection: KnowledgeCollection) {
        var updated = collection
        updated.updatedAt = Date()
        KnowledgeCollectionStore.save(updated)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id)
        scheduleIndex(of: updated)
    }

    public func delete(id: UUID) {
        KnowledgeCollectionStore.delete(id: id)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: id)
        Task.detached(priority: .utility) {
            await KnowledgeIndexService.shared.removeCollectionArtifacts(collectionId: id)
            // A cloned collection's content lives in our managed
            // directory; remove it with the registration. User-chosen
            // folders are never touched.
            try? FileManager.default.removeItem(
                at: OsaurusPaths.knowledge().appendingPathComponent(id.uuidString, isDirectory: true)
            )
        }
    }

    // MARK: - Git sync

    /// Clone a git remote into the managed content directory and register
    /// it as a collection. Throws with git's error when the clone fails.
    @discardableResult
    public func createFromGit(
        name: String,
        summary: String = "",
        remoteURL: String
    ) async throws -> KnowledgeCollection {
        let id = UUID()
        let target = try await KnowledgeGitSyncService.shared.clone(
            remoteURL: remoteURL,
            collectionId: id
        )
        let collection = KnowledgeCollection(
            id: id,
            name: name,
            summary: summary,
            folderPath: target.path,
            gitRemoteURL: remoteURL
        )
        KnowledgeCollectionStore.save(collection)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id)
        scheduleIndex(of: collection)
        return collection
    }

    /// Pull + push a git-backed collection, re-indexing when the pull
    /// brought changes. Returns the outcome for the UI toast.
    public func syncNow(_ collection: KnowledgeCollection) async -> KnowledgeSyncOutcome {
        let outcome = await KnowledgeGitSyncService.shared.sync(collection)
        if case .updated = outcome {
            scheduleIndex(of: collection)
        }
        return outcome
    }

    /// Kick a background (re-)index of one collection. `force` bypasses
    /// the content-hash skip for a manual full rebuild.
    public func scheduleIndex(of collection: KnowledgeCollection, force: Bool = false) {
        guard collection.isEnabled else { return }
        Task.detached(priority: .utility) {
            await KnowledgeIndexService.shared.indexCollection(collection, force: force)
        }
    }

    /// Kick a background incremental pass over every enabled collection
    /// (app startup, deferred off the launch path).
    public func scheduleIndexAll() {
        let snapshot = collections
        Task.detached(priority: .utility) {
            await KnowledgeIndexService.shared.indexAll(snapshot)
        }
    }
}
