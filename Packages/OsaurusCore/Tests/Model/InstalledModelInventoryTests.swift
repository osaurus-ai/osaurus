//
//  InstalledModelInventoryTests.swift
//  osaurusTests
//
//  One installed-models inventory. The sidebar Local Models badge, the Models
//  page header / On Device tab, the Catalog cards and the config catalog all
//  read `ModelManager.installedModels()`; these tests pin that the inventory
//  does not depend on whether the local scan or the OsaurusAI org fetch
//  lands first, and that an externally installed bundle whose id is also a
//  curated or org suggestion is counted and shown as installed everywhere.
//
//  Reported shape: sidebar "Local Models 91" beside a page header "63
//  downloaded". The 28 missing were installed external bundles whose ids were
//  also suggestions; the page's representative for each was the suggestion,
//  which probes the managed models directory.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct InstalledModelInventoryTests {

    /// Suppress the background OsaurusAI HF org fetch that `ModelManager.init()`
    /// kicks off, so a live listing cannot replace the injected entries
    /// between an `applyOsaurusOrgFetch(...)` call and its assertion.
    init() {
        ModelManager.skipBackgroundOrgFetchForTests = true
    }

    /// `ModelManager.loadAvailableModels()` overlays cached download sizes
    /// onto curated entries. Keep this suite on a throwaway root so nothing
    /// here depends on a developer or CI machine's persisted `ModelSizeCache`.
    @MainActor
    private func withIsolatedModelSizeCache(
        _ body: @MainActor @Sendable () throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let previous = OsaurusPaths.overrideRoot
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("osaurus-installed-inventory-\(UUID().uuidString)", isDirectory: true)
                OsaurusPaths.overrideRoot = root
                ModelSizeCache.invalidateInMemory()
                defer {
                    OsaurusPaths.overrideRoot = previous
                    ModelSizeCache.invalidateInMemory()
                    try? FileManager.default.removeItem(at: root)
                }
                try body()
            }
        }
    }

    // MARK: - Fixtures

    /// A fresh root for this test's external bundles; removed by the caller.
    private static func makeBundleRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-external-bundles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A complete bundle (config + tokenizer + weights) at an external path,
    /// returned as the entry `ExternalModelLocator` produces for it: a
    /// `bundleDirectory`, external provenance, and the bundle's byte size
    /// (nil when the size could not be read).
    private static func installedExternalBundle(
        id: String,
        under root: URL,
        sizeBytes: Int64? = 1
    ) throws -> MLXModel {
        let dir = root.appendingPathComponent(
            id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data().write(to: dir.appendingPathComponent("model.safetensors"))
        return MLXModel(
            id: id,
            name: ModelMetadataParser.friendlyName(from: id),
            description: "Found in Custom folder.",
            downloadURL: "https://huggingface.co/\(id)",
            downloadSizeBytes: sizeBytes,
            bundleDirectory: dir,
            externalSource: "Custom folder"
        )
    }

    /// A curated entry as `ModelManager.init` seeds it into both arrays:
    /// editorial fields, no bundle path. (`curatedSuggestedModels` itself is
    /// file-private; the seeded copy is the same struct.)
    @MainActor
    private static func seededCuratedEntry(of manager: ModelManager) -> MLXModel? {
        manager.suggestedModels.first {
            ModelManager.curatedSuggestedIds.contains($0.id.lowercased())
        }
    }

    /// What the OsaurusAI org auto-fetch builds for a repo: editorial data,
    /// no installation metadata.
    private static func orgCard(_ id: String) -> MLXModel {
        MLXModel(
            id: id,
            name: ModelMetadataParser.friendlyName(from: id),
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/\(id)",
            releasedAt: Date()
        )
    }

    /// Every surface's installed count from one main-actor snapshot of the
    /// manager: the sidebar badge, the Models page On Device list, and the
    /// inventory itself. `ids` restricts the per-surface counts to the
    /// fixture so a developer machine's own installed models cannot skew
    /// them; the totals are compared unrestricted.
    private struct SurfaceCounts {
        let badge: Int
        let page: Int
        let inventory: Int
        let badgeTotal: Int
        let pageTotal: Int
        let inventoryTotal: Int
    }

    @MainActor
    private static func surfaceCounts(_ manager: ModelManager, ids: Set<String>) -> SurfaceCounts {
        let candidates = manager.deduplicatedModels()
        let badge = ModelManager.installedModels(among: candidates).filter { ids.contains($0.id) }
        let input = ModelDownloadView.GridListInput(
            availableModels: manager.availableModels,
            suggestedModels: manager.suggestedModels,
            deduplicatedModels: candidates,
            downloadStates: [:],
            searchText: "",
            filterState: ModelManager.ModelFilterState(),
            selectedTab: .downloaded,
            sortOption: .recommended,
            totalMemoryGB: 128
        )
        let lists = ModelDownloadView.makeGridLists(input)
        let inventory = manager.installedModels()
        return SurfaceCounts(
            badge: badge.count,
            page: lists.downloaded.filter { ids.contains($0.id) }.count,
            inventory: inventory.filter { ids.contains($0.id) }.count,
            badgeTotal: ManagementBadgeStore.modelsBadgeCount(inventoryCandidates: candidates),
            pageTotal: lists.downloaded.count,
            inventoryTotal: inventory.count
        )
    }

    // MARK: - Order independence

    /// The observed launch order: the local scan merged first, then the org
    /// listing landed and rebuilt `suggestedModels` from fresh entries. The
    /// page's representative became the fresh org card and reported
    /// not-downloaded while the badge still counted the bundle.
    @Test @MainActor func localMergeThenOrgFetch_keepsTheInstalledExternalInTheInventory() async throws {
        try await withIsolatedModelSizeCache {
            let root = try Self.makeBundleRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = "OsaurusAI/Inventory-Order-Local-First-JANG_4M"
            let external = try Self.installedExternalBundle(id: id, under: root)
            let card = Self.orgCard(id)

            let manager = ModelManager()
            manager.mergeAvailable(with: [external], refreshLocalInstallationMetadata: true)
            manager.applyOsaurusOrgFetch(autoFetched: [card])

            // Installation evidence survived the org refresh on the suggestion…
            let suggestion = manager.suggestedModels.first { $0.id == id }
            #expect(suggestion?.bundleDirectory == external.bundleDirectory)
            #expect(suggestion?.externalSource == external.externalSource)
            // …with the org card's editorial fields kept.
            #expect(suggestion?.description == card.description)

            // One entry per list, and one inventory representative that is installed.
            #expect(manager.availableModels.filter { $0.id == id }.count == 1)
            #expect(manager.suggestedModels.filter { $0.id == id }.count == 1)
            let representative = manager.deduplicatedModels().filter { $0.id == id }
            #expect(representative.count == 1)
            #expect(representative.first?.isDownloaded == true)
            #expect(representative.first?.description == card.description)

            let counts = Self.surfaceCounts(manager, ids: [id])
            #expect(counts.badge == 1)
            #expect(counts.page == 1)
            #expect(counts.inventory == 1)
            #expect(counts.badgeTotal == counts.pageTotal)
            #expect(counts.pageTotal == counts.inventoryTotal)
        }
    }

    /// The reverse order (org fetch first, local scan second), which the
    /// `mergeAvailable` fix on the base branch already handled for the badge.
    /// Both orders must give the same page count.
    @Test @MainActor func orgFetchThenLocalMerge_keepsTheInstalledExternalInTheInventory() async throws {
        try await withIsolatedModelSizeCache {
            let root = try Self.makeBundleRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = "OsaurusAI/Inventory-Order-Org-First-JANG_4M"
            let external = try Self.installedExternalBundle(id: id, under: root)
            let card = Self.orgCard(id)

            let manager = ModelManager()
            manager.applyOsaurusOrgFetch(autoFetched: [card])
            #expect(!manager.availableModels.contains { $0.id == id })
            manager.mergeAvailable(with: [external], refreshLocalInstallationMetadata: true)

            #expect(manager.availableModels.filter { $0.id == id }.count == 1)
            #expect(manager.availableModels.first { $0.id == id }?.bundleDirectory == external.bundleDirectory)
            #expect(manager.suggestedModels.first { $0.id == id }?.bundleDirectory == external.bundleDirectory)
            let representative = manager.deduplicatedModels().filter { $0.id == id }
            #expect(representative.count == 1)
            #expect(representative.first?.isDownloaded == true)

            let counts = Self.surfaceCounts(manager, ids: [id])
            #expect(counts.badge == 1)
            #expect(counts.page == 1)
            #expect(counts.inventory == 1)
            #expect(counts.badgeTotal == counts.pageTotal)
            #expect(counts.pageTotal == counts.inventoryTotal)

            // A second org refresh (the Catalog tab's refresh button) does not
            // knock the bundle back out of the page's inventory.
            manager.applyOsaurusOrgFetch(autoFetched: [card])
            let after = Self.surfaceCounts(manager, ids: [id])
            #expect(after.page == 1)
            #expect(after.badgeTotal == after.pageTotal)
        }
    }

    /// A curated id (seeded into both arrays at init without a bundle path)
    /// installed externally: the exact-id merge folds the path into both
    /// entries, and the org refresh — which rebuilds the curated entry from
    /// the static catalog — must not drop it again.
    @Test @MainActor func curatedIdInstalledExternally_survivesAnOrgRefresh() async throws {
        try await withIsolatedModelSizeCache {
            let root = try Self.makeBundleRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = ModelManager()
            let curated = try #require(Self.seededCuratedEntry(of: manager))
            let external = try Self.installedExternalBundle(id: curated.id, under: root)

            manager.mergeAvailable(with: [external], refreshLocalInstallationMetadata: true)
            manager.applyOsaurusOrgFetch(autoFetched: [])

            let suggestion = manager.suggestedModels.first { $0.id == curated.id }
            #expect(suggestion?.bundleDirectory == external.bundleDirectory)
            // Curated editorial fields are intact on the sticky entry.
            #expect(suggestion?.name == curated.name)
            #expect(suggestion?.description == curated.description)
            #expect(suggestion?.isTopSuggestion == curated.isTopSuggestion)
            #expect(suggestion?.useCase == curated.useCase)

            let representative = manager.deduplicatedModels().first { $0.id == curated.id }
            #expect(representative?.isDownloaded == true)
            #expect(representative?.bundleDirectory == external.bundleDirectory)
            #expect(Self.surfaceCounts(manager, ids: [curated.id]).page == 1)
        }
    }

    /// Badge == page over a mixed inventory: externals colliding with org
    /// cards, one colliding with a curated id, externals with no collision, a
    /// tail collision (`JANGQ-AI/<tail>` installed vs `OsaurusAI/<tail>`
    /// suggested), and an org card that is not installed, with the org fetch
    /// applied last as observed on the reported Mac.
    @Test @MainActor func badgeAndPageCountTheSameInventory() async throws {
        try await withIsolatedModelSizeCache {
            let root = try Self.makeBundleRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = ModelManager()
            let curated = try #require(Self.seededCuratedEntry(of: manager))

            let orgCollisionIds = [
                "OsaurusAI/Inventory-Mix-A-JANG_4M",
                "OsaurusAI/Inventory-Mix-B-JANG_6M",
                "OsaurusAI/Inventory-Mix-C-JANGH2",
            ]
            let freeIds = [
                "dealignai/Inventory-Mix-Free-A",
                "some-org/Inventory-Mix-Free-B",
            ]
            let tailInstalledId = "JANGQ-AI/Inventory-Mix-Tail"
            let tailSuggestedId = "OsaurusAI/Inventory-Mix-Tail"
            let notInstalledId = "OsaurusAI/Inventory-Mix-Not-Installed"

            var externals: [MLXModel] = []
            for id in orgCollisionIds + freeIds + [tailInstalledId, curated.id] {
                externals.append(try Self.installedExternalBundle(id: id, under: root))
            }
            let installedIds = Set(externals.map { $0.id })
            let fixtureIds = installedIds.union([tailSuggestedId, notInstalledId])

            manager.mergeAvailable(with: externals, refreshLocalInstallationMetadata: true)
            manager.applyOsaurusOrgFetch(
                autoFetched: (orgCollisionIds + [tailSuggestedId, notInstalledId]).map(Self.orgCard))

            let counts = Self.surfaceCounts(manager, ids: fixtureIds)
            // 3 org collisions + 1 curated collision + 2 free + 1 tail = 7.
            #expect(installedIds.count == 7)
            #expect(counts.badge == 7)
            #expect(counts.page == 7)
            #expect(counts.inventory == 7)
            #expect(counts.badgeTotal == counts.pageTotal)
            #expect(counts.pageTotal == counts.inventoryTotal)

            let installed = Set(manager.installedModels().map { $0.id })
            #expect(installed.isSuperset(of: installedIds))
            // The not-installed org card and the suggested tail twin stay out.
            #expect(!installed.contains(notInstalledId))
            #expect(!installed.contains(tailSuggestedId))
        }
    }

    // MARK: - Catalog cards

    /// The Catalog tab's card for an installed id is the installed entry: it
    /// reports downloaded and carries the bundle path. A card for an id that
    /// is not installed is exactly the suggestion it always was.
    @Test @MainActor func catalogCardForAnInstalledExternalShowsInstalled() async throws {
        let root = try Self.makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installedId = "OsaurusAI/Inventory-Card-Installed-JANG_4M"
        let notInstalledId = "OsaurusAI/Inventory-Card-Not-Installed-JANG_4M"
        let external = try Self.installedExternalBundle(id: installedId, under: root)
        let installedCard = Self.orgCard(installedId)
        let notInstalledCard = Self.orgCard(notInstalledId)

        let suggested = [installedCard, notInstalledCard]
        let available = [external]
        let input = ModelDownloadView.GridListInput(
            availableModels: available,
            suggestedModels: suggested,
            deduplicatedModels: ModelManager.deduplicatedModels(suggested: suggested, available: available),
            downloadStates: [:],
            searchText: "",
            filterState: ModelManager.ModelFilterState(),
            selectedTab: .all,
            sortOption: .recommended,
            totalMemoryGB: 128
        )
        let lists = ModelDownloadView.makeGridLists(input)

        let installedCards = lists.others.filter { $0.id == installedId }
        #expect(installedCards.count == 1)
        #expect(installedCards.first?.isDownloaded == true)
        #expect(installedCards.first?.bundleDirectory == external.bundleDirectory)
        // Editorial fields come from the suggestion.
        #expect(installedCards.first?.description == installedCard.description)

        let notInstalledCards = lists.others.filter { $0.id == notInstalledId }
        #expect(notInstalledCards.count == 1)
        #expect(notInstalledCards.first?.isDownloaded == false)
        #expect(notInstalledCards.first?.bundleDirectory == nil)
        #expect(notInstalledCards.first?.description == notInstalledCard.description)

        // The On Device list from the same input agrees with the badge count.
        #expect(lists.downloaded.map { $0.id } == [installedId])
        #expect(ManagementBadgeStore.modelsBadgeCount(inventoryCandidates: input.deduplicatedModels) == 1)
    }

    // MARK: - Dedupe and merge contracts

    @Test func deduplicatedModels_prefersTheEntryWithInstallationEvidence() throws {
        let root = try Self.makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "OsaurusAI/Inventory-Dedupe-JANG_4M"
        let external = try Self.installedExternalBundle(id: id, under: root, sizeBytes: 42)
        let suggestion = MLXModel(
            id: id,
            name: "Curated Name",
            description: "Curated description",
            downloadURL: "https://huggingface.co/\(id)",
            isTopSuggestion: true,
            downloadSizeBytes: 7,
            useCase: .general
        )

        // Suggestion first, installed entry second: the slot keeps the
        // suggestion's editorial fields and takes the bundle's metadata.
        let merged = ModelManager.deduplicatedModels(suggested: [suggestion], available: [external])
        #expect(merged.count == 1)
        #expect(merged.first?.name == "Curated Name")
        #expect(merged.first?.description == "Curated description")
        #expect(merged.first?.isTopSuggestion == true)
        #expect(merged.first?.useCase == .general)
        #expect(merged.first?.bundleDirectory == external.bundleDirectory)
        #expect(merged.first?.externalSource == external.externalSource)
        #expect(merged.first?.downloadSizeBytes == 42)
        #expect(merged.first?.isDownloaded == true)

        // Evidence already in the slot is kept as is.
        let sticky = suggestion.mergingLocalInstallationMetadata(from: external)
        let kept = ModelManager.deduplicatedModels(suggested: [sticky], available: [suggestion])
        #expect(kept.count == 1)
        #expect(kept.first?.bundleDirectory == external.bundleDirectory)

        // Neither entry carries evidence: first occurrence wins, as before.
        let other = MLXModel(
            id: id, name: "Other", description: "Discovered on Hugging Face", downloadURL: "")
        let plain = ModelManager.deduplicatedModels(suggested: [suggestion], available: [other])
        #expect(plain.count == 1)
        #expect(plain.first?.name == "Curated Name")
        #expect(plain.first?.bundleDirectory == nil)
    }

    /// The bundle path and provenance carry even when the bundle's weight
    /// size could not be read; only the byte count is gated on it.
    @Test func mergingLocalInstallationMetadata_carriesThePathWhenTheSizeIsUnknown() throws {
        let root = try Self.makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "OsaurusAI/Inventory-Unknown-Size-JANG_4M"
        let suggestion = MLXModel(
            id: id,
            name: "Curated",
            description: "Curated",
            downloadURL: "https://huggingface.co/\(id)",
            downloadSizeBytes: 9
        )

        let unsized = try Self.installedExternalBundle(id: id, under: root, sizeBytes: nil)
        let mergedUnsized = suggestion.mergingLocalInstallationMetadata(from: unsized)
        #expect(mergedUnsized.bundleDirectory == unsized.bundleDirectory)
        #expect(mergedUnsized.externalSource == unsized.externalSource)
        #expect(mergedUnsized.downloadSizeBytes == 9)
        #expect(mergedUnsized.isDownloaded == true)

        let zeroSized = try Self.installedExternalBundle(id: id, under: root, sizeBytes: 0)
        let mergedZero = suggestion.mergingLocalInstallationMetadata(from: zeroSized)
        #expect(mergedZero.bundleDirectory == zeroSized.bundleDirectory)
        #expect(mergedZero.downloadSizeBytes == 9)

        let sized = try Self.installedExternalBundle(id: id, under: root, sizeBytes: 5)
        #expect(suggestion.mergingLocalInstallationMetadata(from: sized).downloadSizeBytes == 5)

        // A different id is never merged.
        let foreign = try Self.installedExternalBundle(id: "OsaurusAI/Inventory-Other", under: root)
        #expect(suggestion.mergingLocalInstallationMetadata(from: foreign).bundleDirectory == nil)
    }
}
