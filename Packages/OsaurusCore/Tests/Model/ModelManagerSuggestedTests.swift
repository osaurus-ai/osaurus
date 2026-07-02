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

@Suite(.serialized)
struct ModelManagerSuggestedTests {

    /// Suppress the background OsaurusAI HF org fetch that `ModelManager.init()`
    /// kicks off — without this knob, the async network response can land
    /// between a test's `applyOsaurusOrgFetch(...)` call and its assertion,
    /// replacing the injected entries with whatever HF currently lists and
    /// flaking the suite (CI > local because CI consistently has network).
    init() {
        ModelManager.skipBackgroundOrgFetchForTests = true
    }

    /// `ModelManager.loadAvailableModels()` intentionally overlays cached
    /// download sizes onto curated entries. Keep this suite on a throwaway
    /// root so catalog metadata assertions do not depend on a developer or CI
    /// machine's persisted `ModelSizeCache`.
    @MainActor
    private func withIsolatedModelSizeCache(_ body: @MainActor @Sendable () -> Void) async {
        await StoragePathsTestLock.shared.run {
            await MainActor.run {
                let previous = OsaurusPaths.overrideRoot
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("osaurus-suggested-models-\(UUID().uuidString)", isDirectory: true)
                OsaurusPaths.overrideRoot = root
                ModelSizeCache.invalidateInMemory()
                defer {
                    OsaurusPaths.overrideRoot = previous
                    ModelSizeCache.invalidateInMemory()
                    try? FileManager.default.removeItem(at: root)
                }
                body()
            }
        }
    }

    // MARK: - Curated catalog

    @Test func curatedSuggestedIds_includesNewMiniMaxEntries() {
        let ids = ModelManager.curatedSuggestedIds
        #expect(ids.contains("osaurusai/minimax-m2.7-jangtq4"))
        #expect(ids.contains("osaurusai/minimax-m2.7-jangtq"))
    }

    @Test func curatedSuggestedIds_includesLingEntries() {
        let ids = ModelManager.curatedSuggestedIds
        #expect(ids.contains("osaurusai/ling-2.6-flash-mxfp4"))
        #expect(ids.contains("osaurusai/ling-2.6-flash-jangtq"))
    }

    @Test @MainActor func curatedSuggestedIds_matchInitialSuggestedModels() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let curatedIds = ModelManager.curatedSuggestedIds
            let suggestedIds = Set(suggested.map { $0.id.lowercased() })
            // On a fresh manager (before any HF fetch resolves), `suggestedModels`
            // is exactly the curated catalog.
            #expect(suggestedIds == curatedIds)
        }
    }

    @Test @MainActor func curatedOsaurusEntries_haveValidReleaseDates() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
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
    }

    @Test @MainActor func miniMaxEntries_haveExpectedMetadata() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let jangtq4 = suggested.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ4" }
            let jangtq = suggested.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ" }

            #expect(jangtq4 != nil)
            #expect(jangtq != nil)

            // Download sizes are no longer hand-coded; they're sourced from the
            // revision-gated `ModelSizeCache` (empty in a fresh test run), so the
            // curated entry carries no size until the org refresh fills it in.
            #expect(jangtq4?.downloadSizeBytes == nil)
            #expect(jangtq?.downloadSizeBytes == nil)

            // model_type drives pre-download routing through the JANGTQ loader.
            #expect(jangtq4?.modelType == "minimax_m2")
            #expect(jangtq?.modelType == "minimax_m2")

            #expect(jangtq4?.releasedAt != nil)
            #expect(jangtq?.releasedAt != nil)
        }
    }

    @Test @MainActor func lingEntries_haveExpectedMetadata() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let mxfp4 = suggested.first { $0.id == "OsaurusAI/Ling-2.6-flash-MXFP4" }
            let jangtq = suggested.first { $0.id == "OsaurusAI/Ling-2.6-flash-JANGTQ" }

            #expect(mxfp4 != nil)
            #expect(jangtq != nil)
            #expect(mxfp4?.modelType == "bailing_hybrid")
            #expect(jangtq?.modelType == "bailing_hybrid")
            #expect(mxfp4?.releasedAt != nil)
            #expect(jangtq?.releasedAt != nil)
        }
    }

    @Test @MainActor func lfm25Entry_haveExpectedMetadata() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let mxfp8 = suggested.first { $0.id == "OsaurusAI/LFM2.5-8B-A1B-MXFP8" }

            #expect(mxfp8 != nil)
            #expect(mxfp8?.modelType == "lfm2_moe")
            #expect(mxfp8?.isTopSuggestion == true)
            // Sizes now come from `ModelSizeCache` (empty here), not literals.
            #expect(mxfp8?.downloadSizeBytes == nil)
            #expect(mxfp8?.releasedAt != nil)
        }
    }

    // MARK: - OsaurusAI org auto-discovery merge

    @Test @MainActor func applyOsaurusOrgFetch_addsNewEntriesAfterCurated() async {
        await withIsolatedModelSizeCache {
            let manager = ModelManager()
            let curatedCount = ModelManager.curatedSuggestedIds.count

            let fresh = MLXModel(
                id: "OsaurusAI/Brand-New-Repo-XYZ",
                name: "Brand New Repo XYZ",
                description: "From OsaurusAI on Hugging Face.",
                downloadURL: "https://huggingface.co/OsaurusAI/Brand-New-Repo-XYZ",
                releasedAt: Date()
            )

            manager.applyOsaurusOrgFetch(autoFetched: [fresh])

            let after = manager.suggestedModels
            #expect(after.count == curatedCount + 1)
            #expect(after.contains { $0.id == fresh.id })
        }
    }

    @Test @MainActor func applyOsaurusOrgFetch_curatedEntryWinsOnDuplicateId() async {
        await withIsolatedModelSizeCache {
            let manager = ModelManager()

            // Try to clobber a curated entry with auto-fetched metadata.
            let imposter = MLXModel(
                id: "OsaurusAI/MiniMax-M2.7-JANGTQ4",
                name: "Should Not Replace",
                description: "from auto-fetch",
                downloadURL: "https://huggingface.co/OsaurusAI/MiniMax-M2.7-JANGTQ4"
            )

            manager.applyOsaurusOrgFetch(autoFetched: [imposter])

            let curated = manager.suggestedModels.first { $0.id == "OsaurusAI/MiniMax-M2.7-JANGTQ4" }
            #expect(curated != nil)
            // Curated metadata should be intact.
            #expect(curated?.modelType == "minimax_m2")
            #expect(curated?.description.contains("MiniMax M2.7") == true)
        }
    }

    @Test @MainActor func applyOsaurusOrgFetch_dropsStaleAutoFetchedOnReapply() async {
        await withIsolatedModelSizeCache {
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
            let manager = ModelManager()
            manager.applyOsaurusOrgFetch(autoFetched: [stale])
            manager.applyOsaurusOrgFetch(autoFetched: [kept])
            let after = manager.suggestedModels
            #expect(after.contains { $0.id == kept.id })
            #expect(!after.contains { $0.id == stale.id })
        }
    }

    @Test @MainActor func applyOsaurusOrgFetch_preservesNonOsaurusInjectedEntries() async {
        await withIsolatedModelSizeCache {
            let manager = ModelManager()

            let foreign = MLXModel(
                id: "some-org/unrelated-model",
                name: "Unrelated",
                description: "manual",
                downloadURL: "https://huggingface.co/some-org/unrelated-model"
            )

            manager.suggestedModels.append(foreign)
            manager.applyOsaurusOrgFetch(autoFetched: [])

            let after = manager.suggestedModels
            #expect(after.contains { $0.id == foreign.id })
        }
    }

    // MARK: - Top-pick reorg (precision-first)

    @Test @MainActor func topPicks_includeGemmaQATSpineAndPrecisionFirstFlagships() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let topIds = Set(suggested.filter(\.isTopSuggestion).map { $0.id })
            for id in [
                "OsaurusAI/gemma-4-12B-it-qat-MXFP4",
                "OsaurusAI/gemma-4-31B-it-qat-MXFP4",
                "OsaurusAI/gemma-4-26B-A4B-it-qat-MXFP4",
                "OsaurusAI/gemma-4-E4B-it-8bit",
                "OsaurusAI/gemma-4-E2B-it-8bit",
                "OsaurusAI/Qwen3.6-27B-MXFP4",
                "OsaurusAI/Qwen3.6-35B-A3B-MXFP8-MTP",
            ] {
                #expect(topIds.contains(id), "expected \(id) to be a Top Pick")
            }
        }
    }

    @Test @MainActor func lowerPrecisionSiblings_demotedFromTopPicks() async {
        await withIsolatedModelSizeCache {
            let suggested = ModelManager().suggestedModels
            let e4b4 = suggested.first { $0.id == "OsaurusAI/gemma-4-E4B-it-4bit" }
            #expect(e4b4 != nil)
            #expect(e4b4?.isTopSuggestion == false)
            // The MXFP4 35B MoE is kept in the catalog but demoted in favour of
            // its MXFP8-MTP sibling.
            let qwen35mxfp4 = suggested.first { $0.id == "OsaurusAI/Qwen3.6-35B-A3B-mxfp4" }
            #expect(qwen35mxfp4 != nil)
            #expect(qwen35mxfp4?.isTopSuggestion == false)
        }
    }

    @Test func retiredModels_absentFromCuratedCatalog() {
        let ids = ModelManager.curatedSuggestedIds
        for retired in [
            "liquidai/lfm2-24b-a2b-mlx-8bit",
            "lmstudio-community/gpt-oss-20b-mlx-8bit",
            "lmstudio-community/gpt-oss-120b-mlx-8bit",
            "osaurusai/diffusiongemma-26b-a4b-it-mxfp8",
            "osaurusai/gemma-4-26b-a4b-it-mxfp4",
            "osaurusai/gemma-4-26b-a4b-it-4bit",
            "osaurusai/gemma-4-31b-it-jang_4m",
            "osaurusai/qwen3.5-122b-a10b-jang_4k",
            "osaurusai/qwen3.5-35b-a3b-jang_2s",
        ] {
            #expect(!ids.contains(retired), "expected \(retired) to be removed")
        }
    }

    @Test func staleCuratedIds_fixedToJANGTQ() {
        let ids = ModelManager.curatedSuggestedIds
        #expect(ids.contains("osaurusai/laguna-xs.2-jangtq"))
        #expect(!ids.contains("osaurusai/laguna-xs.2-jangtq2"))
        #expect(ids.contains("osaurusai/mistral-medium-3.5-128b-jangtq"))
        #expect(!ids.contains("osaurusai/mistral-medium-3.5-128b-jangtq2"))
    }

    @Test @MainActor func retiredOrgRepos_droppedFromAutoFetchMerge() async {
        await withIsolatedModelSizeCache {
            let manager = ModelManager()
            // A retired repo reappearing via the org listing must not surface.
            let retired = MLXModel(
                id: "OsaurusAI/gemma-4-26B-A4B-it-4bit",
                name: "x",
                description: "from auto-fetch",
                downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-26B-A4B-it-4bit"
            )
            // DiffusionGemma was retired from suggestions; the org auto-fetch
            // must not re-surface it as a plain non-curated row either.
            let diffusionGemma = MLXModel(
                id: "OsaurusAI/diffusiongemma-26B-A4B-it-MXFP8",
                name: "x",
                description: "from auto-fetch",
                downloadURL: "https://huggingface.co/OsaurusAI/diffusiongemma-26B-A4B-it-MXFP8"
            )
            manager.applyOsaurusOrgFetch(autoFetched: [retired, diffusionGemma])
            #expect(!manager.suggestedModels.contains { $0.id == retired.id })
            #expect(!manager.suggestedModels.contains { $0.id == diffusionGemma.id })
        }
    }

    // MARK: - Non-chat repo gate (rampart, embeddings, image/speech pipelines)

    @Test func chatCatalogEligibility_rejectsNonChatPipelinesAndPanelOwnedRepos() {
        // Rampart is owned by Settings → Privacy; excluded even without a tag.
        #expect(
            !ModelManager.isChatCatalogEligible(id: "OsaurusAI/rampart-mlx", pipelineTag: nil)
        )
        // Non-chat pipeline tags never surface as chat cards.
        for tag in [
            "token-classification", "feature-extraction", "sentence-similarity",
            "text-to-image", "image-to-image", "automatic-speech-recognition",
            "text-to-speech",
        ] {
            #expect(
                !ModelManager.isChatCatalogEligible(id: "OsaurusAI/some-utility", pipelineTag: tag),
                "expected pipeline tag \(tag) to be rejected"
            )
        }
        // Chat-capable pipelines pass.
        for tag in ["text-generation", "image-text-to-text", "any-to-any"] {
            #expect(
                ModelManager.isChatCatalogEligible(id: "OsaurusAI/some-chat-model", pipelineTag: tag),
                "expected pipeline tag \(tag) to be accepted"
            )
        }
        // Untagged MLX conversions stay eligible (nil is not evidence of non-chat).
        #expect(
            ModelManager.isChatCatalogEligible(id: "OsaurusAI/Untagged-Chat-Model", pipelineTag: nil)
        )
    }

    @Test @MainActor func panelOwnedRepos_droppedFromAutoFetchMerge() async {
        await withIsolatedModelSizeCache {
            let manager = ModelManager()
            let rampart = MLXModel(
                id: "OsaurusAI/rampart-mlx",
                name: "rampart mlx",
                description: "From OsaurusAI on Hugging Face.",
                downloadURL: "https://huggingface.co/OsaurusAI/rampart-mlx"
            )
            manager.applyOsaurusOrgFetch(autoFetched: [rampart])
            #expect(!manager.suggestedModels.contains { $0.id == rampart.id })
        }
    }

    // MARK: - Onboarding default scenario matrix (Phase 4c)

    @Test @MainActor func onboardingDefault_landsOnGemmaQATSpinePerRAMTier() async {
        await withIsolatedModelSizeCache {
            // Fetch candidates under the isolated (empty) size cache so estimates
            // come from the deterministic param heuristic, not a machine's cached
            // on-disk sizes.
            let candidates = ModelManager().suggestedModels.filter(\.isTopSuggestion)
            let pick: (Double) -> String? = { gb in
                ConfigureAIState.recommendedLocalPick(from: candidates, totalMemoryGB: gb)?.id
            }
            // Small tier stays on the 8-bit retention build (gated until the
            // QAT-4bit-vs-8bit bounce A/B clears).
            #expect(pick(8) == "OsaurusAI/gemma-4-E4B-it-8bit")
            // Mainstream tiers: the dense 12B QAT default.
            #expect(pick(16) == "OsaurusAI/gemma-4-12B-it-qat-MXFP4")
            #expect(pick(18) == "OsaurusAI/gemma-4-12B-it-qat-MXFP4")
            #expect(pick(24) == "OsaurusAI/gemma-4-12B-it-qat-MXFP4")
            // Large tiers: the dense 31B QAT ceiling.
            #expect(pick(32) == "OsaurusAI/gemma-4-31B-it-qat-MXFP4")
            #expect(pick(36) == "OsaurusAI/gemma-4-31B-it-qat-MXFP4")
            #expect(pick(48) == "OsaurusAI/gemma-4-31B-it-qat-MXFP4")
            #expect(pick(64) == "OsaurusAI/gemma-4-31B-it-qat-MXFP4")
        }
    }

    @Test @MainActor func onboardingDefault_neverAutoSelectsMoEorLargerFlagship() async {
        await withIsolatedModelSizeCache {
            let candidates = ModelManager().suggestedModels.filter(\.isTopSuggestion)
            let excluded: Set<String> = [
                "OsaurusAI/gemma-4-26B-A4B-it-qat-MXFP4",
                "OsaurusAI/Qwen3.6-35B-A3B-MXFP8-MTP",
                "OsaurusAI/Qwen3.6-27B-MXFP8-MTP",
            ]
            for gb in stride(from: 8.0, through: 128.0, by: 2.0) {
                let id = ConfigureAIState.recommendedLocalPick(
                    from: candidates,
                    totalMemoryGB: gb
                )?.id
                if let id {
                    #expect(!excluded.contains(id), "auto-default \(id) at \(gb)GB must not be a MoE/flagship")
                }
            }
        }
    }
}
