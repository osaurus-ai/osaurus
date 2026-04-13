//
//  InferenceProgressManager.swift
//  osaurus
//
//  Observable singleton that broadcasts prefill progress so the UI can show
//  "Processing N tokens…" while the GPU is doing its initial prompt forward pass.
//

import Foundation

/// Singleton observable that tracks in-flight prefill progress.
///
/// Stored-property mutations are always dispatched to the MainActor so that
/// SwiftUI bindings are updated correctly.  Call sites that are NOT on the
/// MainActor use the fire-and-forget `*Async` variants.
final class InferenceProgressManager: ObservableObject, @unchecked Sendable {
    static let shared = InferenceProgressManager()

    /// True while the model container is being loaded (weights paging into GPU).
    /// The UI shows "Loading Model..." during this phase.
    @MainActor @Published var isLoadingModel: Bool = false

    /// Non-nil while a prefill is in progress.  Set to the prompt token count
    /// just before `prepareAndGenerate` is called; cleared as soon as the first
    /// generated token arrives (or on error / cancellation).
    @MainActor @Published var prefillTokenCount: Int? = nil

    /// Wall-clock time when the current prefill started.
    @MainActor @Published var prefillStartedAt: Date? = nil

    init() {}

    #if DEBUG
        /// Test-only factory: creates an isolated instance so tests don't share
        /// state with the `shared` singleton.
        static func _testMake() -> InferenceProgressManager { InferenceProgressManager() }
    #endif

    /// Called from the MainActor just before prefill begins.
    @MainActor func prefillWillStart(tokenCount: Int) {
        if prefillTokenCount == nil { prefillStartedAt = Date() }
        prefillTokenCount = tokenCount
    }

    /// Called from the MainActor when the first token is generated (prefill done)
    /// or on error / cancellation.
    @MainActor func prefillDidFinish() {
        prefillTokenCount = nil
        prefillStartedAt = nil
    }

    /// Fire-and-forget variant for call sites that are not on MainActor.
    func prefillWillStartAsync(tokenCount: Int) {
        Task { @MainActor in self.prefillWillStart(tokenCount: tokenCount) }
    }

    /// Fire-and-forget variant for call sites that are not on MainActor.
    func prefillDidFinishAsync() {
        Task { @MainActor in self.prefillDidFinish() }
    }

    /// Signal that model container loading has started.
    func modelLoadWillStartAsync() {
        Task { @MainActor in self.isLoadingModel = true }
    }

    /// Signal that model container loading has finished.
    func modelLoadDidFinishAsync() {
        Task { @MainActor in self.isLoadingModel = false }
    }
}
