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
    /// pop the substate back to the picker. The previous UX left the
    /// user on the dead downloading screen even after dismissing the
    /// failure alert — issue #1071.
    @Test func cancelLocalDownload_returnsToPickerAndResetsState() {
        let (state, model) = makeStateWithModel()
        defer { clear(model) }

        state.localSubstate = .downloading
        ModelManager.shared.downloadService.downloadStates[model.id] = .downloading(progress: 0.3)

        state.cancelLocalDownload()

        #expect(state.localSubstate == .picker)
        let after = ModelManager.shared.downloadService.downloadStates[model.id]
        #expect(after == .notStarted)
    }
}
