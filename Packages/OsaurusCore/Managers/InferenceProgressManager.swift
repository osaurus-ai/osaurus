//
//  InferenceProgressManager.swift
//  osaurus
//
//  Observable singleton that broadcasts prefill progress so the UI can show
//  "Processing N tokens…" while the GPU is doing its initial prompt forward pass.
//

import Foundation

enum PrefillProgressStage: String, Codable, Sendable, Equatable {
    case queued
    case cacheLookup
    case cacheRestore
    case prefill
    case complete
}

struct PrefillProgressState: Codable, Sendable, Equatable {
    let stage: PrefillProgressStage
    let completedUnitCount: Int
    let totalUnitCount: Int
    let detail: String?

    var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }

    var percentCompleted: Double {
        fractionCompleted * 100
    }
}

/// Singleton observable that tracks in-flight prefill progress.
///
/// Stored-property mutations are always dispatched to the MainActor so that
/// SwiftUI bindings are updated correctly.  Call sites that are NOT on the
/// MainActor use the fire-and-forget `*Async` variants.
final class InferenceProgressManager: ObservableObject, @unchecked Sendable {
    static let shared = InferenceProgressManager()

    /// Refcount of in-flight model loads. Incremented by
    /// `modelLoadWillStartAsync`, decremented by `modelLoadDidFinishAsync`.
    /// The UI observes `isLoadingModel` which is a computed `count > 0`
    /// view. The refcount — rather than a bare Bool — guarantees the
    /// flag doesn't get stuck `false` when two concurrent loads race
    /// (e.g. a second chat window starting a different model while the
    /// first is mid-load) and doesn't get stuck `true` when a load is
    /// cancelled mid-flight and its cleanup fires out of order with a
    /// newer load's start.
    ///
    /// `private(set)` so only this class can mutate it. `@Published`
    /// so SwiftUI redraws when the derived `isLoadingModel` flips.
    @MainActor @Published private(set) var loadInFlightCount: Int = 0

    /// True while at least one model container is being loaded.
    /// Computed view over `loadInFlightCount`. SwiftUI picks up changes
    /// because the underlying `@Published` storage is annotated.
    @MainActor var isLoadingModel: Bool { loadInFlightCount > 0 }

    /// Non-nil while a prefill is in progress.  Set to the prompt token count
    /// just before `prepareAndGenerate` is called; cleared as soon as the first
    /// generated token arrives (or on error / cancellation).
    @MainActor @Published var prefillTokenCount: Int? = nil

    /// Wall-clock time when the current prefill started.
    @MainActor @Published var prefillStartedAt: Date? = nil

    /// Latest runtime-reported prefill stage. Nil means no prompt prefill is active.
    @MainActor @Published var prefillProgress: PrefillProgressState? = nil

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
        prefillProgress = PrefillProgressState(
            stage: .queued,
            completedUnitCount: 0,
            totalUnitCount: max(0, tokenCount),
            detail: nil
        )
    }

    /// Called from the MainActor when vmlx reports real prompt-processing progress.
    @MainActor func prefillDidUpdate(_ progress: PrefillProgressState) {
        if prefillStartedAt == nil { prefillStartedAt = Date() }
        prefillTokenCount = progress.totalUnitCount
        prefillProgress = progress
        if progress.stage == .complete {
            prefillDidFinish()
        }
    }

    /// Called from the MainActor when the first token is generated (prefill done)
    /// or on error / cancellation.
    @MainActor func prefillDidFinish() {
        prefillTokenCount = nil
        prefillStartedAt = nil
        prefillProgress = nil
    }

    /// Fire-and-forget variant for call sites that are not on MainActor.
    func prefillWillStartAsync(tokenCount: Int) {
        Task { @MainActor in self.prefillWillStart(tokenCount: tokenCount) }
    }

    /// Fire-and-forget variant for call sites that are not on MainActor.
    func prefillDidUpdateAsync(_ progress: PrefillProgressState) {
        Task { @MainActor in self.prefillDidUpdate(progress) }
    }

    /// Fire-and-forget variant for call sites that are not on MainActor.
    func prefillDidFinishAsync() {
        Task { @MainActor in self.prefillDidFinish() }
    }

    /// Signal that model container loading has started. Increments the
    /// in-flight refcount; the matching `modelLoadDidFinishAsync` must
    /// fire for every call, regardless of success / failure / cancel.
    func modelLoadWillStartAsync() {
        Task { @MainActor in self.loadInFlightCount += 1 }
    }

    /// Signal that model container loading has finished. Decrements the
    /// refcount with a floor at 0 so double-fires (e.g. a buggy caller
    /// firing in both a `catch` and a success path) can never drive it
    /// negative and poison subsequent loads.
    ///
    /// Callers must guarantee that every `modelLoadWillStartAsync` is
    /// paired with exactly one `modelLoadDidFinishAsync` on every exit
    /// path (success, throw, cancel). See
    /// `ModelRuntime.generateEventStream` for the canonical pattern —
    /// a narrow do/catch scoped to just the container load.
    func modelLoadDidFinishAsync() {
        Task { @MainActor in
            self.loadInFlightCount = max(0, self.loadInFlightCount - 1)
        }
    }
}
