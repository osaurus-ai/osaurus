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

    /// Short, user-facing title for the runtime stage. Keeping cache lookup
    /// and restore distinct from transformer prefill prevents an initial
    /// `.cacheLookup(0/N)` event from being presented as a cold `Prefill 0/N`.
    var localizedDisplayTitle: String {
        switch self {
        case .queued:
            return L("Queued")
        case .cacheLookup:
            return L("Checking cache")
        case .cacheRestore:
            return L("Restored")
        case .prefill, .complete:
            return L("Prefill")
        }
    }
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

    // MARK: - Model-load accounting
    //
    // A cold container load happens INSIDE the window the chat measures as
    // "time to first token": the send sets its start stamp, then awaits
    // `streamChat`, and no delta can arrive until the weights are resident.
    // So a user loading a 27 GB bundle sees the load billed as TTFT — one
    // report showed "TTFT 215.61s" for a ~1.8k-token prompt, which is not a
    // prefill rate any machine produces. The load is the honest explanation
    // and it belongs in its own number.
    //
    // Intervals are recorded as a UNION, not a sum: two models loading
    // concurrently is still one stretch of wall-clock the user waited
    // through, so double-counting it would over-subtract and drive the
    // reported TTFT to zero.

    /// Closed load intervals, most recent last. Capped — this exists to
    /// attribute the current turn, not to keep history.
    @MainActor private var recentLoadIntervals: [DateInterval] = []

    /// Start of the currently-open union interval, set when the refcount
    /// leaves zero and cleared when it returns to zero.
    @MainActor private var openLoadStart: Date?

    private static let maxRetainedLoadIntervals = 32

    init() {}

    /// Seconds within `from...to` during which at least one model container
    /// was loading.
    ///
    /// Clips against the window on both ends so a load that began before the
    /// send, or is still running, contributes only its overlapping part. A
    /// still-open load is clipped to `to` rather than ignored — the cold-load
    /// case we care about is precisely the one that has not finished when the
    /// first token finally lands.
    @MainActor
    func modelLoadSeconds(from: Date, to: Date) -> TimeInterval {
        guard to > from else { return 0 }
        var total: TimeInterval = 0
        for interval in recentLoadIntervals {
            let lo = max(interval.start, from)
            let hi = min(interval.end, to)
            if hi > lo { total += hi.timeIntervalSince(lo) }
        }
        if let open = openLoadStart {
            let lo = max(open, from)
            if to > lo { total += to.timeIntervalSince(lo) }
        }
        // Can never exceed the window it is measured against.
        return min(total, to.timeIntervalSince(from))
    }

    @MainActor
    private func beginModelLoad(at: Date) {
        if loadInFlightCount == 0 { openLoadStart = at }
        loadInFlightCount += 1
    }

    @MainActor
    private func endModelLoad(at: Date) {
        loadInFlightCount = max(0, loadInFlightCount - 1)
        guard loadInFlightCount == 0, let start = openLoadStart else { return }
        openLoadStart = nil
        // A finish whose timestamp precedes its start (clock adjustment, or a
        // caller pairing out of order) would otherwise create a negative-length
        // interval that subtracts time it never spent.
        guard at > start else { return }
        recentLoadIntervals.append(DateInterval(start: start, end: at))
        if recentLoadIntervals.count > Self.maxRetainedLoadIntervals {
            recentLoadIntervals.removeFirst(
                recentLoadIntervals.count - Self.maxRetainedLoadIntervals)
        }
    }

    #if DEBUG
        /// Test seam: drive the accounting with explicit timestamps so the
        /// overlap arithmetic can be verified without real loads.
        @MainActor func _testBeginModelLoad(at: Date) { beginModelLoad(at: at) }
        @MainActor func _testEndModelLoad(at: Date) { endModelLoad(at: at) }
    #endif

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
    /// The timestamp is taken HERE, at the call site, not inside the
    /// MainActor hop. Under the memory pressure that makes a load slow enough
    /// to matter, that hop can itself be delayed, and stamping after it would
    /// shorten the measured load by exactly the amount the machine was
    /// struggling — biasing the number in the reassuring direction.
    func modelLoadWillStartAsync() {
        let at = Date()
        Task { @MainActor in self.beginModelLoad(at: at) }
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
        let at = Date()
        Task { @MainActor in self.endModelLoad(at: at) }
    }
}
