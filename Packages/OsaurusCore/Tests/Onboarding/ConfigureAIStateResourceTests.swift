//
//  ConfigureAIStateResourceTests.swift
//  osaurusTests
//
//  Coverage for the resource-cost surfaces on the Configure AI onboarding
//  step: the local-commit disk-space preflight that refuses inline instead of
//  starting a doomed background download, the plain-language model
//  subtitle, the fit label, and the "why this model" line.
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

    /// Committing the local option with a selection that can't possibly fit
    /// the real volume must stay put with an inline warning — not advance,
    /// not commit the brain source, not start a download.
    @Test func localCommitPreflightBlocksOversizedDownloadInline() {
        // If the volume can't be statted in this environment the preflight
        // fails open by design and there is nothing to verify.
        guard ConfigureAIState.queryFreeDiskBytes() != nil else { return }

        let state = ConfigureAIState()
        // ~2.3 exabytes: guaranteed shortfall on any real volume.
        state.selectedModel = makeModel(tag: "huge", sizeBytes: Int64.max / 4)

        var completed = false
        state.chooseLocalAndContinue(onComplete: { completed = true })

        #expect(completed == false)
        #expect(state.screen == .home)
        #expect(state.diskSpaceWarning != nil)
        #expect(state.selectedBrainSource == nil)
    }

    // MARK: - Model subtitle

    /// Model subtitles come from the curated use case, not the catalog
    /// description — the descriptions are Models-tab copy full of the
    /// vocabulary onboarding is supposed to hide.
    @Test func modelSubtitleDerivedFromUseCase() {
        for useCase in ModelUseCase.allCases {
            let subtitle = ConfigureAIState.modelSubtitle(
                for: makeModel(tag: "cased-\(useCase.rawValue)", useCase: useCase)
            )
            #expect(subtitle?.isEmpty == false)
        }
    }

    /// No use case means no subtitle — never fall back to the raw description.
    @Test func modelSubtitleNilWithoutUseCase() {
        #expect(ConfigureAIState.modelSubtitle(for: makeModel(tag: "uncased")) == nil)
    }

    // MARK: - Outcome copy

    /// The reason is phrased in terms of this Mac, and only when the model
    /// runs comfortably there.
    @Test func pickReasonNamesThisMacsMemory() {
        let model = makeModel(tag: "pick", sizeBytes: 4 * gb)
        let reason = ConfigureAIState.pickReason(for: model, totalMemoryGB: 32)
        #expect(reason?.contains("32 GB") == true)
        #expect(reason?.contains("runs smoothly") == true)
        #expect(ConfigureAIState.pickReason(for: model, totalMemoryGB: 0) == nil)
    }

    /// No reason is offered when the model would only fit tightly.
    @Test func pickReasonNilWhenTheModelWouldNotRunSmoothly() {
        let model = makeModel(tag: "tight", sizeBytes: 8 * gb)
        #expect(ConfigureAIState.pickReason(for: model, totalMemoryGB: 12) == nil)
    }

    @Test func fitLabelSpeaksInOutcomes() {
        #expect(ConfigureAIState.fitLabel(.compatible) == "Runs smoothly here")
        #expect(ConfigureAIState.fitLabel(.tight) == "May slow your other apps")
        #expect(ConfigureAIState.fitLabel(.tooLarge) == "Too big for this Mac")
        #expect(ConfigureAIState.fitLabel(.unknown) == nil)
    }
}
