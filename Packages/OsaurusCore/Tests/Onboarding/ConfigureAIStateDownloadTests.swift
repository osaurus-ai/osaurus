//
//  ConfigureAIStateDownloadTests.swift
//  osaurusTests
//
//  Coverage for the Configure AI step's single-path flow: the featured local
//  model with one-press background download + advance, the "Skip download"
//  Cloud path, the bring-your-own-key drill-in, and the pin targets
//  `finishOnboarding` reads for each brain source.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigureAIStateDownloadTests {

    /// Build a synthetic in-memory model + state combo, leaving no
    /// global side-effects behind by clearing `ModelManager.shared`
    /// download state at the end of each test.
    /// `downloadSizeBytes` defaults to a tiny explicit size so the disk
    /// preflight can never refuse: without it, the size is *estimated* from
    /// the id, and a random UUID segment like "…-472B-…" parses as 472
    /// billion params — a phantom multi-hundred-GB download.
    private func makeStateWithModel(
        downloadSizeBytes: Int64? = 1024
    ) -> (ConfigureAIState, MLXModel) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-cfg-ai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        let model = MLXModel(
            id: "cfg-ai/test-\(UUID().uuidString)",
            name: "Test Onboarding",
            description: "",
            downloadURL: "https://example.com/test",
            downloadSizeBytes: downloadSizeBytes,
            rootDirectory: tempDir
        )
        let state = ConfigureAIState()
        state.selectedModel = model
        return (state, model)
    }

    private func clear(_ model: MLXModel) {
        ModelManager.shared.downloadService.downloadStates[model.id] = nil
        ModelManager.shared.downloadService.downloadMetrics[model.id] = nil
    }

    /// Materialize `model` on disk so `isDownloaded` reports true — lets the
    /// local commit path be exercised without touching the network.
    private func markDownloaded(_ model: MLXModel) throws {
        let bundleDir = model.localDirectory
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            FileManager.default.createFile(
                atPath: bundleDir.appendingPathComponent(file).path,
                contents: Data()
            )
        }
    }

    // MARK: - Default (managed Osaurus) home screen

    /// A fresh state lands on the home screen — the featured local model
    /// card — with no brain committed and no download started yet.
    @Test func defaultsToOsaurusHomeScreen() {
        let state = ConfigureAIState()
        #expect(state.screen == .home)
        #expect(state.apiSubstate == .picker)
        #expect(state.selectedBrainSource == nil)
        #expect(state.hasStartedLocalDownload == false)

        // `ensureLocalSelection` pre-picks the featured model so the card
        // can show a concrete name and download size on first render.
        state.ensureLocalSelection()
        #expect(state.selectedModel != nil)
        #expect(state.screen == .home)
    }

    /// "Skip download" commits the managed Osaurus brain and advances in one
    /// click — no model, key, or download involved.
    @Test func chooseOsaurusCommitsAndAdvancesImmediately() {
        let state = ConfigureAIState()

        var completed = false
        state.chooseOsaurusAndContinue(onComplete: { completed = true })

        #expect(completed == true)
        #expect(state.selectedBrainSource == .osaurus)
        // Neither alternative pin target may fire for the managed source.
        #expect(state.localDefaultModelIdToPin == nil)
        #expect(state.providerModelPinTarget == nil)
    }

    /// Skipping to Cloud is a pure commit: it must not kick off the featured
    /// model's download as a side effect — users who start on free credits
    /// download local models later, on their own schedule.
    @Test func chooseOsaurusDoesNotStartLocalDownload() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }
        #expect(state.selectedModel?.isDownloaded != true)

        var completed = false
        state.chooseOsaurusAndContinue(onComplete: { completed = true })

        #expect(completed == true)
        #expect(state.selectedBrainSource == .osaurus)
        #expect(ModelManager.shared.downloadStates[model.id] == nil)
    }

    /// One CTA press commits the local default, starts its background download,
    /// and advances. Chat owns progress feedback, so onboarding never requires
    /// a redundant second confirmation.
    @Test func chooseLocalAndContinue_startsDownloadAndAdvances() {
        let (state, model) = makeStateWithModel()
        defer {
            ModelManager.shared.cancelDownload(model.id)
            clear(model)
            try? FileManager.default.removeItem(at: model.localDirectory)
        }
        #expect(state.selectedModel?.isDownloaded != true)
        #expect(state.hasStartedLocalDownload == false)

        var completed = false
        state.chooseLocalAndContinue(onComplete: { completed = true })

        #expect(completed == true)
        #expect(state.selectedBrainSource == .local)
        #expect(state.localDefaultModelIdToPin == model.id)
        #expect(state.hasStartedLocalDownload == true)
        if case .downloading = ModelManager.shared.downloadStates[model.id] {
            // Background download stays in flight after onboarding advances.
        } else {
            Issue.record("expected an in-flight background download after the CTA press")
        }
    }

    /// The disk preflight refuses the download inline: nothing starts, no
    /// brain source is committed, and the warning is surfaced for the banner.
    @Test func chooseLocalAndContinue_refusesWhenDownloadWontFit() {
        // A petabyte-scale download can never fit; the preflight must refuse.
        let (state, model) = makeStateWithModel(
            downloadSizeBytes: 1024 * 1024 * 1024 * 1024 * 1024
        )
        defer { clear(model) }

        var completed = false
        state.chooseLocalAndContinue(onComplete: { completed = true })

        #expect(completed == false)
        #expect(state.diskSpaceWarning != nil)
        #expect(state.selectedBrainSource == nil)
        #expect(state.hasStartedLocalDownload == false)
        #expect(ModelManager.shared.downloadStates[model.id] == nil)
    }

    // MARK: - Provider navigation

    /// Drilling into bring-your-own-key moves to the BYOK picker, and backing
    /// out returns to the provider chips it was entered from.
    @Test func byokDrillInAndBackReturnsToProviders() {
        let state = ConfigureAIState()

        state.showKeys()
        state.enterProvider(.openai)
        #expect(state.screen == .byok)
        #expect(state.apiSubstate == .keyForm(.openai))

        state.popBYOKToProviders()
        #expect(state.screen == .keys)
        #expect(state.apiSubstate == .picker)
        #expect(state.substateDirection == .backward)
    }

    /// The three paths are peers: each opens from home and returns to it.
    @Test func pathsOpenFromHomeAndReturn() {
        let state = ConfigureAIState()

        state.showLocal()
        #expect(state.screen == .local)
        #expect(state.substateDirection == .forward)
        state.popToHome()
        #expect(state.screen == .home)

        state.showKeys()
        #expect(state.screen == .keys)
        state.popToHome()
        #expect(state.screen == .home)
        #expect(state.substateDirection == .backward)
    }

    /// An abandoned custom-endpoint dialog over the provider chips drops its
    /// half-filled form.
    @Test func abandonedCustomDialogResetsOverProviders() {
        let state = ConfigureAIState()
        state.showKeys()
        state.enterCustomProvider()
        #expect(state.connectDialog == .apiKey)
        #expect(state.apiSubstate == .customForm)

        state.closeConnectDialog()
        #expect(state.connectDialog == nil)
        #expect(state.apiSubstate == .picker)
        #expect(state.screen == .keys)
    }

    // MARK: - Local commit (non-blocking)

    /// Choosing local with the model already on disk commits the source and
    /// advances immediately — nothing to download, no blocking screen.
    @Test func chooseLocalWithDownloadedModelAdvancesImmediately() throws {
        let (state, model) = makeStateWithModel()
        defer {
            clear(model)
            try? FileManager.default.removeItem(at: model.localDirectory)
        }
        try markDownloaded(model)
        #expect(state.selectedModel?.isDownloaded == true)

        var completed = false
        state.chooseLocalAndContinue(onComplete: { completed = true })

        #expect(completed == true)
        #expect(state.selectedBrainSource == .local)
        #expect(state.localDefaultModelIdToPin == model.id)
        // The commit never leaves the current screen — there is no blocking
        // downloading sub-screen anymore.
        #expect(state.screen == .home)
    }

    /// Onboarding offers only the preferred model; another Top Pick already
    /// on disk does not replace it.
    @Test func ensureLocalSelectionPicksPreferredModelEvenWhenAnotherTopPickIsOnDisk() throws {
        let manager = ModelManager.shared
        let originalSuggested = manager.suggestedModels
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-cfg-ai-\(UUID().uuidString)")
        defer {
            manager.suggestedModels = originalSuggested
            try? FileManager.default.removeItem(at: root)
        }

        let installed = MLXModel(
            id: "test/installed-top-pick-\(UUID().uuidString)",
            name: "Installed Top Pick",
            description: "",
            downloadURL: "https://example.com/installed",
            isTopSuggestion: true,
            downloadSizeBytes: 1024,
            rootDirectory: root
        )
        try markDownloaded(installed)
        let preferred = MLXModel(
            id: ConfigureAIState.preferredOnboardingModelId,
            name: "Raptor",
            description: "",
            downloadURL: "https://example.com/raptor",
            isTopSuggestion: true,
            downloadSizeBytes: 1024,
            rootDirectory: root
        )
        manager.suggestedModels = [installed, preferred]

        let state = ConfigureAIState()
        state.ensureLocalSelection()

        #expect(installed.isDownloaded)
        #expect(state.selectedModel?.id == ConfigureAIState.preferredOnboardingModelId)
    }

    /// There is no memory-based fallback: the preferred model is offered even
    /// when it would not fit this Mac, so the card never dead-ends empty.
    @Test func ensureLocalSelectionKeepsPreferredModelWhenItIsTooLarge() {
        let manager = ModelManager.shared
        let originalSuggested = manager.suggestedModels
        defer { manager.suggestedModels = originalSuggested }

        manager.suggestedModels = [
            MLXModel(
                id: "test/small-\(UUID().uuidString)",
                name: "Small",
                description: "",
                downloadURL: "https://example.com/small",
                isTopSuggestion: true,
                downloadSizeBytes: 1024
            ),
            MLXModel(
                id: ConfigureAIState.preferredOnboardingModelId,
                name: "Raptor",
                description: "",
                downloadURL: "https://example.com/raptor",
                isTopSuggestion: true,
                downloadSizeBytes: 400 * 1024 * 1024 * 1024
            ),
        ]

        let state = ConfigureAIState()
        state.ensureLocalSelection()

        #expect(state.selectedModel?.id == ConfigureAIState.preferredOnboardingModelId)
    }

    /// An existing selection is left alone.
    @Test func ensureLocalSelectionKeepsAnExistingSelection() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.ensureLocalSelection()

        #expect(state.selectedModel?.id == model.id)
    }

    // MARK: - Pin targets read by finishOnboarding

    /// `finishOnboarding` reads `localDefaultModelIdToPin` to pin the agent's
    /// default model. It must only surface the selected id when the user
    /// actually committed to the Local path — a sticky `selectedModel` left
    /// over after switching to a non-local source must not be pinned.
    @Test func localDefaultModelIdToPin_returnsSelectedIdOnlyForLocalBrainSource() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        // No brain source committed yet -> nothing to pin.
        #expect(state.localDefaultModelIdToPin == nil)

        // Committed local -> the selected model's id.
        state.selectedBrainSource = .local
        #expect(state.localDefaultModelIdToPin == model.id)

        // Switched to a bring-your-own-key source (selection stays sticky) ->
        // nil, so the local model isn't mis-pinned when the user proceeds.
        state.selectedBrainSource = .providerKey(.openai)
        #expect(state.localDefaultModelIdToPin == nil)

        // The managed source pins through the Router path, never the local id.
        state.selectedBrainSource = .osaurus
        #expect(state.localDefaultModelIdToPin == nil)
    }

    /// `finishOnboarding` reads `providerModelPinTarget` to poll for the
    /// just-connected provider's first chat-capable model. It must only return
    /// the captured provider id for the bring-your-own-key / OAuth brain source.
    @Test func providerModelPinTarget_returnsAddedProviderIdOnlyForProviderKeySource() {
        let state = ConfigureAIState()
        let providerId = UUID()
        state.addedProviderId = providerId

        // No / non-provider brain source -> nil even with a captured provider.
        #expect(state.providerModelPinTarget == nil)
        state.selectedBrainSource = .local
        #expect(state.providerModelPinTarget == nil)
        state.selectedBrainSource = .osaurus
        #expect(state.providerModelPinTarget == nil)

        // Provider-key brain source -> the captured provider id.
        state.selectedBrainSource = .providerKey(.openai)
        #expect(state.providerModelPinTarget == providerId)
    }
}
