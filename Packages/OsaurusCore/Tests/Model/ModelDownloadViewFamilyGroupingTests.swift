//
//  ModelDownloadViewFamilyGroupingTests.swift
//  osaurusTests
//
//  Covers the catalog's family grouping: precision/quant variants collapse
//  into one card whose representative ("default variant") is the build that
//  suits the current Mac best.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelDownloadViewFamilyGroupingTests {

    private static let gb: Int64 = 1024 * 1024 * 1024

    private func model(
        id: String,
        sizeGB: Int64? = nil,
        isTopSuggestion: Bool = false,
        releasedAt: Date? = nil
    ) -> MLXModel {
        MLXModel(
            id: id,
            name: ModelMetadataParser.friendlyName(from: id),
            description: "test",
            downloadURL: "https://huggingface.co/\(id)",
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: sizeGB.map { $0 * Self.gb },
            releasedAt: releasedAt,
            // Pin to a directory that never exists so `isDownloaded` is
            // deterministically false — otherwise a dev machine that
            // actually has one of these repos on disk skews the ranking.
            rootDirectory: URL(fileURLWithPath: "/nonexistent/osaurus-grouping-tests")
        )
    }

    @Test func precisionVariantsCollapseToOneCard() {
        let variants = [
            model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 13),
            model(id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4", sizeGB: 8),
            model(id: "OsaurusAI/gemma-4-31B-it-qat-MXFP4", sizeGB: 18),
        ]
        let cards = ModelDownloadView.groupIntoFamilyCards(
            variants,
            totalMemoryGB: 48,
            downloadStates: [:]
        )
        // 12B family collapses; 31B is its own card.
        #expect(cards.count == 2)
        #expect(
            cards.contains { ModelMetadataParser.familyKey(from: $0.id) == "osaurusai/gemma-4-12b-it" }
        )
    }

    @Test func groupingPreservesFirstSeenOrder() {
        let variants = [
            model(id: "OsaurusAI/Qwen3.6-27B-MXFP4", sizeGB: 15),
            model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 13),
            model(id: "OsaurusAI/Qwen3.6-27B-MXFP8-MTP", sizeGB: 28),
        ]
        let cards = ModelDownloadView.groupIntoFamilyCards(
            variants,
            totalMemoryGB: 128,
            downloadStates: [:]
        )
        #expect(cards.count == 2)
        // Qwen family card keeps position 0 (its first-listed variant's slot).
        #expect(ModelMetadataParser.familyKey(from: cards[0].id) == "osaurusai/qwen3.6-27b")
    }

    @Test func defaultVariant_prefersHighestPrecisionThatFits() {
        // On a 48 GB Mac both fit → prefer the larger (higher precision) build.
        let small = model(id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4", sizeGB: 8)
        let large = model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 13)
        let pick = ModelDownloadView.defaultFamilyVariant(
            among: [small, large],
            totalMemoryGB: 48,
            downloadStates: [:]
        )
        #expect(pick.id == large.id)
    }

    @Test func defaultVariant_fallsBackToBuildThatFitsOnSmallMacs() {
        // On a 16 GB Mac the 20 GB build is too large → the 8 GB build wins
        // despite lower precision.
        let small = model(id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4", sizeGB: 8)
        let large = model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 20)
        let pick = ModelDownloadView.defaultFamilyVariant(
            among: [small, large],
            totalMemoryGB: 16,
            downloadStates: [:]
        )
        #expect(pick.id == small.id)
    }

    @Test func defaultVariant_prefersActiveDownload() {
        let idle = model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 13)
        let downloading = model(id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4", sizeGB: 8)
        let pick = ModelDownloadView.defaultFamilyVariant(
            among: [idle, downloading],
            totalMemoryGB: 48,
            downloadStates: [downloading.id: .downloading(progress: 0.4)]
        )
        #expect(pick.id == downloading.id)
    }

    @Test func makeGridLists_collapsesCatalogFamiliesAndExposesVariantMap() {
        let mxfp8 = model(id: "OsaurusAI/gemma-4-12B-it-MXFP8", sizeGB: 13)
        let qat = model(id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4", sizeGB: 8)
        let big = model(id: "OsaurusAI/gemma-4-31B-it-qat-MXFP4", sizeGB: 18)

        let input = ModelDownloadView.GridListInput(
            availableModels: [],
            suggestedModels: [mxfp8, qat, big],
            deduplicatedModels: [],
            downloadStates: [:],
            searchText: "",
            filterState: ModelManager.ModelFilterState(),
            selectedTab: .all,
            sortOption: .recommended,
            totalMemoryGB: 48
        )
        let lists = ModelDownloadView.makeGridLists(input)

        // Two family cards: the 12B precision pair collapses, 31B stands alone.
        #expect(lists.displayed.count == 2)
        // On a 48 GB Mac the 12B card fronts the higher-precision MXFP8 build.
        #expect(lists.displayed.contains { $0.id == mxfp8.id })
        #expect(!lists.displayed.contains { $0.id == qat.id })
        // The variant map still carries both builds for the detail sheet.
        #expect(lists.variantsByFamily["osaurusai/gemma-4-12b-it"]?.count == 2)
    }

    @Test func defaultVariant_prefersCuratedOverAutoFetched() {
        // Same fit and size class: the curated build beats the auto-fetched
        // one so editorial descriptions/Top Pick flags surface on the card.
        let curated = model(id: "OsaurusAI/Qwen3.6-27B-MXFP4", sizeGB: 15)
        let autoFetched = model(id: "OsaurusAI/Qwen3.6-27B-JANG_4M", sizeGB: 15)
        let pick = ModelDownloadView.defaultFamilyVariant(
            among: [autoFetched, curated],
            totalMemoryGB: 64,
            downloadStates: [:]
        )
        #expect(pick.id == curated.id)
    }
}
