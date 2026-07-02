//
//  ConfigureAIStateResourceTests.swift
//  osaurusTests
//
//  Coverage for the explicit resource-cost surfaces on the Configure AI
//  onboarding step: the CTA disk-space preflight that keeps low-disk users
//  off the dead "Preparing download..." screen, the machine-context stat
//  lines (memory / disk read against this Mac's specs), the "picked for
//  your Mac's specs" render rule (which must only claim we chose the model
//  when the selection really is the hardware-recommended pick), and the
//  chooser's same-family variant dedupe that collapses quant builds to one
//  hardware-chosen row per model.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigureAIStateResourceTests {

    private let gb: Int64 = 1024 * 1024 * 1024

    /// Synthetic in-memory model. Tags are fixed descriptive words (not
    /// UUIDs) because several assertions depend on the id carrying *no*
    /// parseable parameter token — a random hex UUID can accidentally
    /// contain one (e.g. "…3f4b…" reads as "4B params").
    private func makeModel(
        tag: String,
        name: String? = nil,
        sizeBytes: Int64? = nil,
        isTopSuggestion: Bool = false,
        useCase: ModelUseCase? = nil
    ) -> MLXModel {
        MLXModel(
            id: "cfg-ai-res/test-\(tag)",
            name: name ?? "Test \(tag)",
            description: "",
            downloadURL: "https://example.com/\(tag)",
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: sizeBytes,
            useCase: useCase,
            rootDirectory: FileManager.default.temporaryDirectory
        )
    }

    // MARK: - Disk-space preflight

    @Test func downloadFitsWhenFreeSpaceCoversSizePlusMargin() {
        let needed = 8 * gb
        let margin = ModelDownloadService.storageSafetyMarginBytes
        // Exactly at the boundary and comfortably above both pass — mirrors
        // `storageRefusalMessage`, which only refuses when needed + margin
        // exceeds the free bytes.
        #expect(
            ConfigureAIState.downloadWontFit(neededBytes: needed, freeBytes: needed + margin)
                == false
        )
        #expect(
            ConfigureAIState.downloadWontFit(neededBytes: needed, freeBytes: needed + margin + gb)
                == false
        )
    }

    @Test func downloadRefusedOnShortfall() {
        let needed = 8 * gb
        let margin = ModelDownloadService.storageSafetyMarginBytes
        #expect(ConfigureAIState.downloadWontFit(neededBytes: needed, freeBytes: 3 * gb) == true)
        // One byte short of the margin still refuses.
        #expect(
            ConfigureAIState.downloadWontFit(
                neededBytes: needed,
                freeBytes: needed + margin - 1
            ) == true
        )
    }

    /// Unknown sizes on either side fail open — the downloader's own in-task
    /// preflight stays authoritative, and onboarding must never block a
    /// download it can't prove won't fit.
    @Test func unknownSizesFailOpen() {
        #expect(ConfigureAIState.downloadWontFit(neededBytes: nil, freeBytes: gb) == false)
        #expect(ConfigureAIState.downloadWontFit(neededBytes: 8 * gb, freeBytes: nil) == false)
        #expect(ConfigureAIState.downloadWontFit(neededBytes: 0, freeBytes: 0) == false)
    }

    /// Pressing the CTA with a selection that can't possibly fit the real
    /// volume must stay on home with an inline warning — not flip to the
    /// downloading screen, not commit the brain source, not call onComplete.
    /// Choosing a different model clears the warning.
    @Test func ctaPreflightBlocksOversizedDownloadInline() {
        // If the volume can't be statted in this environment the preflight
        // fails open by design and there is nothing to verify.
        guard ConfigureAIState.queryFreeDiskBytes() != nil else { return }

        let state = ConfigureAIState()
        // ~2.3 exabytes: guaranteed shortfall on any real volume.
        state.selectedModel = makeModel(tag: "huge", sizeBytes: Int64.max / 4)

        var completed = false
        state.startLocalDownloadOrContinue(onComplete: { completed = true })

        #expect(completed == false)
        #expect(state.screen == .home)
        #expect(state.diskSpaceWarning != nil)
        #expect(state.selectedBrainSource == nil)

        state.selectLocalModel(makeModel(tag: "small-after-huge", sizeBytes: gb))
        #expect(state.diskSpaceWarning == nil)
    }

    // MARK: - "Picked for your Mac's specs" render rule

    @Test func recommendedSelectionRuleMatchesRecommendedPickOnly() {
        let small = makeModel(tag: "small", sizeBytes: 4 * gb, isTopSuggestion: true)
        let large = makeModel(tag: "large", sizeBytes: 8 * gb, isTopSuggestion: true)
        let candidates = [large, small]

        // Neither candidate is a dense Gemma QAT / E-series build, so the
        // policy lands on the smallest comfortable pick.
        let recommended = ConfigureAIState.recommendedLocalPick(
            from: candidates,
            totalMemoryGB: 16
        )
        #expect(recommended?.id == small.id)

        #expect(
            ConfigureAIState.isRecommendedSelection(
                small,
                candidates: candidates,
                totalMemoryGB: 16
            ) == true
        )
        // A manual chooser pick that differs from the recommendation must
        // not claim "picked for your specs".
        #expect(
            ConfigureAIState.isRecommendedSelection(
                large,
                candidates: candidates,
                totalMemoryGB: 16
            ) == false
        )
        #expect(
            ConfigureAIState.isRecommendedSelection(
                nil,
                candidates: candidates,
                totalMemoryGB: 16
            ) == false
        )
    }

    // MARK: - Stat-line formatting

    @Test func memoryStatIncludesMachineTotalWhenKnown() {
        let model = makeModel(tag: "sized", sizeBytes: 8 * gb)
        let text = ConfigureAIState.memoryStatText(for: model, totalMemoryGB: 16)
        #expect(text != nil)
        #expect(text?.contains("16") == true)
    }

    @Test func memoryStatDropsTotalWhenMonitorHasNotReported() {
        let model = makeModel(tag: "sized", sizeBytes: 8 * gb)
        let text = ConfigureAIState.memoryStatText(for: model, totalMemoryGB: 0)
        #expect(text != nil)
        #expect(text?.contains("16") == false)
    }

    @Test func memoryStatHiddenWithoutEstimate() {
        let model = makeModel(tag: "plain")
        #expect(model.formattedEstimatedMemory == nil)
        #expect(ConfigureAIState.memoryStatText(for: model, totalMemoryGB: 16) == nil)
    }

    @Test func diskStatShowsFreeSpaceContextWhenKnown() {
        let model = makeModel(tag: "sized", sizeBytes: 8 * gb)
        let text = ConfigureAIState.diskStatText(for: model, freeDiskBytes: 200 * gb)
        #expect(text?.contains("download") == true)
        #expect(text?.contains("free") == true)
    }

    /// An unknown free-space query drops the "you have N free" suffix rather
    /// than rendering a bogus 0.
    @Test func diskStatDropsFreeSuffixWhenQueryFailed() {
        let model = makeModel(tag: "sized", sizeBytes: 8 * gb)
        let text = ConfigureAIState.diskStatText(for: model, freeDiskBytes: nil)
        #expect(text?.contains("download") == true)
        #expect(text?.contains("free") == false)
    }

    @Test func diskStatHiddenWithoutSize() {
        let model = makeModel(tag: "plain")
        #expect(ConfigureAIState.diskStatText(for: model, freeDiskBytes: 200 * gb) == nil)
    }

    @Test func chooserStatsLineListsDownloadAndMemory() {
        let line = ConfigureAIState.chooserStatsLine(
            for: makeModel(tag: "sized", sizeBytes: 8 * gb)
        )
        #expect(line?.contains("download") == true)
        #expect(line?.contains("memory") == true)
    }

    @Test func chooserStatsLineNilWhenNothingKnown() {
        #expect(ConfigureAIState.chooserStatsLine(for: makeModel(tag: "plain")) == nil)
    }

    // MARK: - Chooser row simplification

    /// Chooser subtitles come from the curated use case, not the catalog
    /// description — the descriptions are Models-tab copy full of the
    /// vocabulary onboarding is supposed to hide.
    @Test func chooserSubtitleDerivedFromUseCase() {
        for useCase in ModelUseCase.allCases {
            let subtitle = ConfigureAIState.chooserSubtitle(
                for: makeModel(tag: "cased-\(useCase.rawValue)", useCase: useCase)
            )
            #expect(subtitle?.isEmpty == false)
        }
    }

    /// No use case means no subtitle — never fall back to the raw description.
    @Test func chooserSubtitleNilWithoutUseCase() {
        #expect(ConfigureAIState.chooserSubtitle(for: makeModel(tag: "uncased")) == nil)
    }

    // MARK: - Same-family variant dedupe

    /// Two quant builds of one model (same `simplifiedName`) collapse to a
    /// single row; with plenty of memory the larger, higher-precision build
    /// wins ("quality should matter more"). The tiny solo model draws the
    /// smallest-comfortable recommendation away from the twin family, so the
    /// family is decided purely by the quality rule.
    @Test func dedupeKeepsHighestQualityVariantThatFitsComfortably() {
        let highPrecision = makeModel(tag: "twin-hp", name: "Twin 9B MXFP8", sizeBytes: 8 * gb)
        let efficient = makeModel(tag: "twin-eff", name: "Twin 9B qat MXFP4", sizeBytes: 4 * gb)
        let solo = makeModel(tag: "solo", name: "Solo 1B MXFP8", sizeBytes: 2 * gb)
        #expect(highPrecision.simplifiedName == efficient.simplifiedName)

        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [highPrecision, efficient, solo],
            totalMemoryGB: 64,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == [highPrecision.id, solo.id])
    }

    /// Quality yields to comfort: when the high-precision build only fits
    /// tightly but the efficient build fits comfortably, the family collapses
    /// to the efficient one.
    @Test func dedupePrefersComfortableVariantOverTightHigherQuality() {
        // est. memory = size × 1.25: 10 GB vs 5 GB against 12 GB total →
        // ratios 0.83 (tight) and 0.42 (comfortable).
        let highPrecision = makeModel(tag: "twin-hp", name: "Twin 9B MXFP8", sizeBytes: 8 * gb)
        let efficient = makeModel(tag: "twin-eff", name: "Twin 9B qat MXFP4", sizeBytes: 4 * gb)
        let solo = makeModel(tag: "solo", name: "Solo 1B MXFP8", sizeBytes: 2 * gb)

        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [highPrecision, efficient, solo],
            totalMemoryGB: 12,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == [efficient.id, solo.id])
    }

    /// The committed selection always survives dedupe, even when the policy
    /// would have collapsed its family onto a sibling — the active model must
    /// never vanish from the list.
    @Test func dedupeKeepsSelectedVariantVisible() {
        let highPrecision = makeModel(tag: "twin-hp", name: "Twin 9B MXFP8", sizeBytes: 8 * gb)
        let efficient = makeModel(tag: "twin-eff", name: "Twin 9B qat MXFP4", sizeBytes: 4 * gb)
        let solo = makeModel(tag: "solo", name: "Solo 1B MXFP8", sizeBytes: 2 * gb)

        // On a 12 GB Mac the policy pick would be `efficient` (see above);
        // an explicit selection of the high-precision build overrides it.
        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [highPrecision, efficient, solo],
            totalMemoryGB: 12,
            selectedId: highPrecision.id
        )
        #expect(deduped.map(\.id) == [highPrecision.id, solo.id])
    }

    /// The auto-default (`recommendedLocalPick`) survives dedupe even when a
    /// sibling has higher quality — otherwise the "Picked for your Mac" badge
    /// would point at a hidden row and contradict the home card.
    @Test func dedupeKeepsRecommendedVariantOverHigherQualitySibling() {
        // No solo model here: the smallest comfortable pick (the efficient
        // build) *is* the recommendation, and must represent the family.
        let highPrecision = makeModel(tag: "twin-hp", name: "Twin 9B MXFP8", sizeBytes: 8 * gb)
        let efficient = makeModel(tag: "twin-eff", name: "Twin 9B qat MXFP4", sizeBytes: 4 * gb)
        let recommended = ConfigureAIState.recommendedLocalPick(
            from: [highPrecision, efficient],
            totalMemoryGB: 64
        )
        #expect(recommended?.id == efficient.id)

        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [highPrecision, efficient],
            totalMemoryGB: 64,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == [efficient.id])
    }

    /// A family whose every build is too large collapses to its smallest
    /// variant, so the disabled row documents the family's floor.
    @Test func dedupeKeepsSmallestVariantWhenWholeFamilyIsTooLarge() {
        let huge = makeModel(tag: "twin-huge", name: "Twin 90B MXFP8", sizeBytes: 40 * gb)
        let large = makeModel(tag: "twin-large", name: "Twin 90B qat MXFP4", sizeBytes: 20 * gb)

        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [huge, large],
            totalMemoryGB: 16,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == [large.id])
    }

    /// Unique families pass through untouched, in catalog order.
    @Test func dedupePreservesUniqueFamiliesAndOrder() {
        let models = [
            makeModel(tag: "uniq-a", name: "Alpha 4B MXFP8", sizeBytes: 4 * gb),
            makeModel(tag: "uniq-b", name: "Beta 9B qat MXFP4", sizeBytes: 8 * gb),
        ]
        let deduped = ConfigureAIState.dedupedTopPicks(
            from: models,
            totalMemoryGB: 64,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == models.map(\.id))
    }

    /// A variant already on disk represents its family even against a
    /// higher-quality sibling — dedupe must never steer the user into
    /// re-downloading a near-duplicate of bits they already have.
    @Test func dedupeKeepsDownloadedVariantOverHigherQualitySibling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-ai-dedupe-downloaded", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let efficient = MLXModel(
            id: "cfg-ai-res/twin-dl-eff",
            name: "Twin 9B qat MXFP4",
            description: "",
            downloadURL: "https://example.com/twin-dl-eff",
            downloadSizeBytes: 4 * gb,
            rootDirectory: root
        )
        let bundleDir =
            root
            .appendingPathComponent("cfg-ai-res", isDirectory: true)
            .appendingPathComponent("twin-dl-eff", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            FileManager.default.createFile(
                atPath: bundleDir.appendingPathComponent(file).path,
                contents: Data()
            )
        }
        #expect(efficient.isDownloaded)

        let highPrecision = makeModel(tag: "twin-dl-hp", name: "Twin 9B MXFP8", sizeBytes: 8 * gb)
        let solo = makeModel(tag: "solo", name: "Solo 1B MXFP8", sizeBytes: 2 * gb)

        let deduped = ConfigureAIState.dedupedTopPicks(
            from: [highPrecision, efficient, solo],
            totalMemoryGB: 64,
            selectedId: nil
        )
        #expect(deduped.map(\.id) == [efficient.id, solo.id])
    }
}
