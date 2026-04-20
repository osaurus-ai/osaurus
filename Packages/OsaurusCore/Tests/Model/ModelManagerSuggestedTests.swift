//
//  ModelManagerSuggestedTests.swift
//  osaurusTests
//
//  Covers the curated suggested-models catalog and the OsaurusAI HF org
//  auto-discovery merge that powers the Recommended tab.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelManagerSuggestedTests {

    // MARK: - Curated catalog

    @Test func curatedSuggestedIds_includesNewMiniMaxEntries() {
        let ids = ModelManager.curatedSuggestedIds
        #expect(ids.contains("osaurusai/minimax-m2.7-jangtq4"))
        #expect(ids.contains("osaurusai/minimax-m2.7-jangtq"))
    }

    @Test func curatedSuggestedIds_matchInitialSuggestedModels() async {
        let suggested = await MainActor.run { ModelManager().suggestedModels }
        let curatedIds = ModelManager.curatedSuggestedIds
        let suggestedIds = Set(suggested.map { $0.id.lowercased() })
        // On a fresh manager (before any HF fetch resolves), `suggestedModels`
        // is exactly the curated catalog.
        #expect(suggestedIds == curatedIds)
    }

    @Test func curatedOsaurusEntries_haveValidReleaseDates() async {
        let suggested = await MainActor.run { ModelManager().suggestedModels }
        let osaurusEntries = suggested.filter { $0.id.hasPrefix("OsaurusAI/") }

        // All curated OsaurusAI entries should carry a release date and it
        // should be after the project's epoch (2025-01-01) — guards against
        // the date helper silently falling back to `Date(timeIntervalSince1970: 0)`.
        let projectEpoch = Date(timeIntervalSince1970: 1_735_689_600)  // 2025-01-01
        for model in osaurusEntries {
            #expect(model.releasedAt != nil, "Missing releasedAt for \(model.id)")
            if let d = model.releasedAt {
                #expect(d > projectEpoch, "Suspicious releasedAt for \(model.id): \(d)")
            }
        }
    }

    @Test func miniMaxEntries_haveExpectedMetadata() async {
        let suggested = await MainActor.run { ModelManager().suggestedModels }
        let jangtq4 = suggested.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ4" }
        let jangtq = suggested.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ" }

        #expect(jangtq4 != nil)
        #expect(jangtq != nil)

        // Sizes from HF `safetensors.totalFileSize`. Locked in so accidental
        // edits to the curated entries are caught.
        #expect(jangtq4?.downloadSizeBytes == 116_874_305_053)
        #expect(jangtq?.downloadSizeBytes == 60_705_324_126)

        // model_type drives pre-download routing through the JANGTQ loader.
        #expect(jangtq4?.modelType == "minimax_m2")
        #expect(jangtq?.modelType == "minimax_m2")

        #expect(jangtq4?.releasedAt != nil)
        #expect(jangtq?.releasedAt != nil)
    }

    // MARK: - OsaurusAI org auto-discovery merge

    @Test func applyOsaurusOrgFetch_addsNewEntriesAfterCurated() async {
        let manager = await MainActor.run { ModelManager() }
        let curatedCount = ModelManager.curatedSuggestedIds.count

        let fresh = MLXModel(
            id: "OsaurusAI/Brand-New-Repo-XYZ",
            name: "Brand New Repo XYZ",
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/OsaurusAI/Brand-New-Repo-XYZ",
            releasedAt: Date()
        )

        await MainActor.run {
            manager.applyOsaurusOrgFetch(autoFetched: [fresh])
        }

        let after = await MainActor.run { manager.suggestedModels }
        #expect(after.count == curatedCount + 1)
        #expect(after.contains { $0.id == fresh.id })
    }

    @Test func applyOsaurusOrgFetch_curatedEntryWinsOnDuplicateId() async {
        let manager = await MainActor.run { ModelManager() }

        // Try to clobber a curated entry with auto-fetched metadata.
        let imposter = MLXModel(
            id: "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            name: "Should Not Replace",
            description: "from auto-fetch",
            downloadURL: "https://huggingface.co/OsaurusAI/MiniMax-M2.7-JANGTQ4"
        )

        await MainActor.run {
            manager.applyOsaurusOrgFetch(autoFetched: [imposter])
        }

        let curated = await MainActor.run {
            manager.suggestedModels.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ4" }
        }
        #expect(curated != nil)
        // Curated metadata should be intact.
        #expect(curated?.modelType == "minimax_m2")
        #expect(curated?.downloadSizeBytes == 116_874_305_053)
        #expect(curated?.description.contains("MiniMax M2.7") == true)
    }

    @Test func applyOsaurusOrgFetch_dropsStaleAutoFetchedOnReapply() async {
        let manager = await MainActor.run { ModelManager() }

        let stale = MLXModel(
            id: "OsaurusAI/Stale-Repo",
            name: "Stale Repo",
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/OsaurusAI/Stale-Repo"
        )
        let kept = MLXModel(
            id: "OsaurusAI/Kept-Repo",
            name: "Kept Repo",
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/OsaurusAI/Kept-Repo"
        )

        await MainActor.run {
            manager.applyOsaurusOrgFetch(autoFetched: [stale])
        }
        await MainActor.run {
            manager.applyOsaurusOrgFetch(autoFetched: [kept])
        }

        let after = await MainActor.run { manager.suggestedModels }
        #expect(after.contains { $0.id == kept.id })
        #expect(!after.contains { $0.id == stale.id })
    }

    @Test func applyOsaurusOrgFetch_preservesNonOsaurusInjectedEntries() async {
        let manager = await MainActor.run { ModelManager() }

        let foreign = MLXModel(
            id: "some-org/unrelated-model",
            name: "Unrelated",
            description: "manual",
            downloadURL: "https://huggingface.co/some-org/unrelated-model"
        )

        await MainActor.run {
            manager.suggestedModels.append(foreign)
            manager.applyOsaurusOrgFetch(autoFetched: [])
        }

        let after = await MainActor.run { manager.suggestedModels }
        #expect(after.contains { $0.id == foreign.id })
    }
}
