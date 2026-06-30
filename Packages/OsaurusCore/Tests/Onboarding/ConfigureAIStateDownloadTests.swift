//
//  ConfigureAIStateDownloadTests.swift
//  osaurusTests
//
//  Regression coverage for the inline pause / resume / failed-with-retry
//  surface added to the Configure AI step (issue #1071). Confirms that the
//  view-model's computed properties faithfully reflect the underlying
//  download state so the onboarding CTA + inline controls stay actionable
//  through the entire downloading → paused → failed → retry lifecycle and
//  the user is never stranded on a disabled Continue button.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigureAIStateDownloadTests {

    /// Build a synthetic in-memory model + state combo, leaving no
    /// global side-effects behind by clearing `ModelManager.shared`
    /// download state at the end of each test.
    private func makeStateWithModel() -> (ConfigureAIState, MLXModel) {
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

    @Test func paused_state_is_reflected_through_computed_properties() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        ModelManager.shared.downloadService.downloadStates[model.id] = .paused(progress: 0.6)

        #expect(state.isLocalPaused == true)
        #expect(state.isLocalDownloading == false)
        #expect(state.isLocalFailed == false)
        #expect(state.isLocalCompleted == false)
        #expect(abs(state.localBarProgress - 0.6) < 0.0001)
    }

    @Test func failed_state_exposes_error_message_for_inline_card() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        ModelManager.shared.downloadService.downloadStates[model.id] =
            .failed(error: "network unreachable")

        #expect(state.isLocalFailed == true)
        #expect(state.localFailedError == "network unreachable")
        #expect(state.isLocalDownloading == false)
        #expect(state.isLocalPaused == false)
    }

    /// The onboarding CTA only auto-advances on `.completed`; here we
    /// confirm `.paused` and `.failed` do NOT flip `isLocalCompleted` to
    /// true. This is the contract the `ConfigureAICTA.onChange(of: state.isLocalCompleted)`
    /// hook depends on to avoid spuriously calling onComplete.
    @Test func paused_and_failed_do_not_satisfy_isLocalCompleted() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        ModelManager.shared.downloadService.downloadStates[model.id] = .paused(progress: 0.99)
        #expect(state.isLocalCompleted == false)

        ModelManager.shared.downloadService.downloadStates[model.id] =
            .failed(error: "bad")
        #expect(state.isLocalCompleted == false)
    }

    /// `cancelLocalDownload()` must both reset the download state AND
    /// pop the screen back home. The previous UX left the user on the dead
    /// downloading screen even after dismissing the failure alert — issue #1071.
    @Test func cancelLocalDownload_returnsHomeAndResetsState() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.screen = .downloading
        ModelManager.shared.downloadService.downloadStates[model.id] = .downloading(progress: 0.3)

        state.cancelLocalDownload()

        #expect(state.screen == .home)
        let after = ModelManager.shared.downloadService.downloadStates[model.id]
        #expect(after == .notStarted)
    }

    /// The step is local-first: a fresh state lands on the home screen with no
    /// brain committed yet, so the recommended "Run on your Mac" card is the
    /// default.
    @Test func defaultsToLocalHomeScreen() {
        let state = ConfigureAIState()
        #expect(state.screen == .home)
        #expect(state.apiSubstate == .picker)
        #expect(state.selectedBrainSource == nil)

        // `ensureLocalSelection` pre-picks a model without leaving home.
        state.ensureLocalSelection(totalMemoryGB: 24)
        #expect(state.selectedModel != nil)
        #expect(state.screen == .home)
    }

    /// Drilling into bring-your-own-key moves to the BYOK picker, and backing
    /// out returns to the home screen.
    @Test func byokDrillInAndBackReturnsHome() {
        let state = ConfigureAIState()

        state.showBYOK()
        #expect(state.screen == .byok)
        #expect(state.apiSubstate == .picker)

        state.popBYOKToHome()
        #expect(state.screen == .home)
    }

    @Test func ensureLocalSelectionDoesNotDeadEndWhenAllCuratedModelsAreTooLarge() {
        let manager = ModelManager.shared
        let originalSuggested = manager.suggestedModels
        defer { manager.suggestedModels = originalSuggested }

        manager.suggestedModels = [
            MLXModel(
                id: "test/large-a-\(UUID().uuidString)",
                name: "Large A",
                description: "",
                downloadURL: "https://example.com/large-a",
                isTopSuggestion: true,
                downloadSizeBytes: 40 * 1024 * 1024 * 1024
            ),
            MLXModel(
                id: "test/large-b-\(UUID().uuidString)",
                name: "Large B",
                description: "",
                downloadURL: "https://example.com/large-b",
                isTopSuggestion: true,
                downloadSizeBytes: 48 * 1024 * 1024 * 1024
            ),
        ]

        let state = ConfigureAIState()
        state.ensureLocalSelection(totalMemoryGB: 24)

        #expect(state.selectedModel != nil)
        #expect(state.selectedModel?.isTopSuggestion == true)
    }

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

        // Provider-key brain source -> the captured provider id.
        state.selectedBrainSource = .providerKey(.openai)
        #expect(state.providerModelPinTarget == providerId)
    }

    // MARK: - Model chooser modal

    /// Build a throwaway in-memory model so a test can move the draft to a
    /// different selection than the seeded one.
    private func makeModel(_ tag: String) -> MLXModel {
        MLXModel(
            id: "cfg-ai/\(tag)-\(UUID().uuidString)",
            name: "Test \(tag)",
            description: "",
            downloadURL: "https://example.com/\(tag)",
            rootDirectory: FileManager.default.temporaryDirectory
        )
    }

    /// Opening the chooser seeds the draft from the current selection (so the
    /// active model is pre-highlighted) and flips the dialog open.
    @Test func openModelChooser_seedsDraftFromSelectionAndOpens() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        #expect(state.isChoosingModel == false)
        #expect(state.draftModel == nil)

        state.openModelChooser()

        #expect(state.isChoosingModel == true)
        #expect(state.draftModel?.id == model.id)
    }

    /// Tapping a row only moves the draft — it does not commit the selection or
    /// close the dialog, so users can browse freely before deciding.
    @Test func selectDraftModel_updatesDraftWithoutCommitting() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.openModelChooser()
        let other = makeModel("other")
        state.selectDraftModel(other)

        #expect(state.draftModel?.id == other.id)
        #expect(state.selectedModel?.id == model.id)
        #expect(state.isChoosingModel == true)
    }

    /// "Use this model" applies the draft as the active local brain and closes
    /// the dialog.
    @Test func commitModelChooser_appliesDraftAndCloses() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.openModelChooser()
        let picked = makeModel("picked")
        state.selectDraftModel(picked)
        state.commitModelChooser()

        #expect(state.selectedModel?.id == picked.id)
        #expect(state.isChoosingModel == false)
        #expect(state.draftModel?.id == picked.id)
    }

    /// Cancel / X / Esc / scrim-tap all route here: the dialog closes and the
    /// committed selection is untouched even though the draft had moved.
    @Test func cancelModelChooser_closesWithoutChangingSelection() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.openModelChooser()
        state.selectDraftModel(makeModel("other"))

        state.cancelModelChooser()

        #expect(state.isChoosingModel == false)
        #expect(state.selectedModel?.id == model.id)
    }
}
