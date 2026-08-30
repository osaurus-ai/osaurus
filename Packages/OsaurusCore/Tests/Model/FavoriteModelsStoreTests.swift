//
//  FavoriteModelsStoreTests.swift
//  osaurusTests
//
//  Verifies persisted favourite model keys used by both the model picker and
//  model management grid.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FavoriteModelsStoreTests {

    @Test @MainActor func addToggleAndRemoveMaintainOrderedUniqueKeys() {
        let (store, _, cleanup) = makeStore()
        defer { cleanup() }

        let first = FavoriteModelsStore.key(sourceKey: "local", modelId: "OsaurusAI/a")
        let second = FavoriteModelsStore.key(sourceKey: "remote-provider", modelId: "openai/gpt")

        store.add(first)
        store.add(first)
        store.add(second)

        #expect(store.favoriteKeys == [first, second])
        #expect(store.isFavorite(first))
        #expect(store.isFavorite(second))

        store.toggle(first)

        #expect(store.favoriteKeys == [second])
        #expect(!store.isFavorite(first))
        #expect(store.isFavorite(second))

        store.remove(second)

        #expect(store.favoriteKeys.isEmpty)
    }

    @Test @MainActor func reloadPreservesFavoritesFromUserDefaults() {
        let (store, defaults, cleanup) = makeStore()
        defer { cleanup() }

        let key = FavoriteModelsStore.key(sourceKey: "local", modelId: "OsaurusAI/gemma")
        store.add(key)

        let reloaded = FavoriteModelsStore(userDefaults: defaults)

        #expect(reloaded.favoriteKeys == [key])
        #expect(reloaded.isFavorite(key))
    }

    @MainActor
    private func makeStore() -> (FavoriteModelsStore, UserDefaults, () -> Void) {
        let suite = "favorite-models-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (
            FavoriteModelsStore(userDefaults: defaults),
            defaults,
            { defaults.removePersistentDomain(forName: suite) }
        )
    }
}
