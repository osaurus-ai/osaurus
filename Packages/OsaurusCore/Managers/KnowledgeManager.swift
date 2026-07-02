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
    public func create(name: String, summary: String = "", folderPath: String) -> KnowledgeCollection {
        let collection = KnowledgeCollection(name: name, summary: summary, folderPath: folderPath)
        KnowledgeCollectionStore.save(collection)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id)
        return collection
    }

    public func update(_ collection: KnowledgeCollection) {
        var updated = collection
        updated.updatedAt = Date()
        KnowledgeCollectionStore.save(updated)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: collection.id)
    }

    public func delete(id: UUID) {
        KnowledgeCollectionStore.delete(id: id)
        collections = KnowledgeCollectionStore.loadAll()
        NotificationCenter.default.post(name: .knowledgeCollectionsChanged, object: id)
    }
}
