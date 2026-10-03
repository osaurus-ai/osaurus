//
//  FavoriteModelsStoreStarterSeedTests.swift
//  osaurusTests
//
//  Pins the one-time Osaurus Cloud starter favourites: new users start with
//  DeepSeek V4.1 Flash, Claude Opus 5.5, and GPT-6 Astra; users who already
//  curated favourites are never touched; models the Router adds later still
//  land; a removed starter is not re-seeded.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct FavoriteModelsStoreStarterSeedTests {

    private static let routerSourceKey =
        "remote-\(RemoteProviderManager.osaurusRouterProviderId.uuidString)"

    private static let fullCatalog = [
        "osaurus/gpt-6-astra",
        "osaurus/claude-opus-5-5",
        "osaurus/deepseek-v4-1-flash",
        "osaurus/claude-sonnet-5",
    ]

    private func makeStore() -> (FavoriteModelsStore, UserDefaults) {
        let suite = "ai.osaurus.tests.favorites-seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FavoriteModelsStore(userDefaults: defaults), defaults)
    }

    private func key(_ modelId: String) -> String {
        FavoriteModelsStore.key(sourceKey: Self.routerSourceKey, modelId: modelId)
    }

    @Test func starterSlugsLeadWithFirstRunModel() {
        #expect(
            FavoriteModelsStore.starterOsaurusCloudSlugs == [
                "deepseek-v4-1-flash", "claude-opus-5-5", "gpt-6-astra",
            ]
        )
        #expect(
            FavoriteModelsStore.starterOsaurusCloudSlugs.first
                == RemoteProviderManager.firstRunOsaurusModelSlug
        )
    }

    /// Empty store + full catalog: all three seeded in starter order (not
    /// catalog order), keyed to the Router source.
    @Test func emptyStoreSeedsAllStartersInOrder() {
        let (store, _) = makeStore()
        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )

        #expect(
            store.favoriteKeys == [
                key("osaurus/deepseek-v4-1-flash"),
                key("osaurus/claude-opus-5-5"),
                key("osaurus/gpt-6-astra"),
            ]
        )
        #expect(store.seededStarterSlugs == FavoriteModelsStore.starterOsaurusCloudSlugs)

        // Idempotent.
        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(store.favoriteKeys.count == 3)
    }

    /// An existing user with their own favourites is left alone, and the
    /// ledger is fully populated so a later catalog never seeds either.
    @Test func existingFavoritesAreNeverTouched() {
        let (store, _) = makeStore()
        let mine = key("osaurus/claude-sonnet-5")
        store.add(mine)

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(store.favoriteKeys == [mine])
        #expect(store.seededStarterSlugs == FavoriteModelsStore.starterOsaurusCloudSlugs)

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(store.favoriteKeys == [mine])
    }

    /// A starter the Router does not offer yet stays pending and is appended
    /// exactly once when a later catalog includes it.
    @Test func missingStarterLandsOnLaterCatalog() {
        let (store, _) = makeStore()
        let withoutOpus = Self.fullCatalog.filter { !$0.contains("opus") }

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: withoutOpus,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(
            store.favoriteKeys == [
                key("osaurus/deepseek-v4-1-flash"),
                key("osaurus/gpt-6-astra"),
            ]
        )
        #expect(store.seededStarterSlugs == ["deepseek-v4-1-flash", "gpt-6-astra"])

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(
            store.favoriteKeys == [
                key("osaurus/deepseek-v4-1-flash"),
                key("osaurus/gpt-6-astra"),
                key("osaurus/claude-opus-5-5"),
            ]
        )
        #expect(store.seededStarterSlugs == ["deepseek-v4-1-flash", "gpt-6-astra", "claude-opus-5-5"])

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(store.favoriteKeys.count == 3)
    }

    /// Once seeded, a starter the user removed is not re-added by the next
    /// catalog arrival — the ledger, not the favourites list, is the gate.
    @Test func removedStarterIsNotReseeded() {
        let (store, _) = makeStore()
        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        store.remove(key("osaurus/gpt-6-astra"))
        #expect(store.favoriteKeys.count == 2)

        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(!store.isFavorite(key("osaurus/gpt-6-astra")))
        #expect(store.favoriteKeys.count == 2)
    }

    /// Matching is by final path component, case-insensitively, so both the
    /// picker-prefixed id and a bare id resolve; the favourite key keeps the
    /// id exactly as the catalog spelled it.
    @Test func slugMatchingIgnoresPrefixAndCase() {
        let (store, _) = makeStore()
        store.seedStarterFavoritesIfNeeded(
            routerModelIds: ["GPT-6-Astra", "osaurus/venice/Deepseek-V4-1-Flash"],
            routerSourceKey: Self.routerSourceKey
        )
        #expect(store.isFavorite(key("GPT-6-Astra")))
        #expect(store.isFavorite(key("osaurus/venice/Deepseek-V4-1-Flash")))
        #expect(store.seededStarterSlugs == ["deepseek-v4-1-flash", "gpt-6-astra"])

        #expect(FavoriteModelsStore.slug(of: "osaurus/deepseek-v4-1-flash") == "deepseek-v4-1-flash")
        #expect(FavoriteModelsStore.slug(of: "gpt-6-astra") == "gpt-6-astra")
    }

    /// The ledger survives a store re-init on the same defaults, so a relaunch
    /// does not seed again.
    @Test func ledgerPersistsAcrossStoreInstances() {
        let (store, defaults) = makeStore()
        store.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        store.remove(key("osaurus/claude-opus-5-5"))

        let relaunched = FavoriteModelsStore(userDefaults: defaults)
        relaunched.seedStarterFavoritesIfNeeded(
            routerModelIds: Self.fullCatalog,
            routerSourceKey: Self.routerSourceKey
        )
        #expect(relaunched.favoriteKeys.count == 2)
        #expect(!relaunched.isFavorite(key("osaurus/claude-opus-5-5")))
    }
}
