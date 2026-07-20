//
//  WarmupProgressHub.swift
//  osaurus
//
//  Per-model progress side channel for background warm-up generations.
//
//  Warm-up requests run with `suppressProgressUI` so they never drive the
//  global `InferenceProgressManager` HUD ("Loading Model…" overlays). This
//  hub is where the runtime layers publish their load/prefill progress
//  instead, keyed by model name, so the model chip tooltip can show what
//  the warm-up is doing without any global UI.
//

import Foundation

enum WarmupProgressPhase: Equatable, Sendable {
    case loadingModel
    case prefilling(PrefillProgressState)
}

final class WarmupProgressHub: ObservableObject, @unchecked Sendable {
    static let shared = WarmupProgressHub()

    @MainActor @Published private(set) var phases: [String: WarmupProgressPhase] = [:]

    init() {}

    nonisolated func modelLoadWillStart(model: String) {
        setPhase(.loadingModel, for: model)
    }

    nonisolated func prefillWillStart(model: String, tokenCount: Int) {
        setPhase(
            .prefilling(
                PrefillProgressState(
                    stage: .queued,
                    completedUnitCount: 0,
                    totalUnitCount: max(0, tokenCount),
                    detail: nil
                )
            ),
            for: model
        )
    }

    nonisolated func prefillDidUpdate(model: String, state: PrefillProgressState) {
        setPhase(.prefilling(state), for: model)
    }

    nonisolated func finish(model: String) {
        guard !model.isEmpty else { return }
        Task { @MainActor in
            self.phases[model] = nil
        }
    }

    private nonisolated func setPhase(_ phase: WarmupProgressPhase, for model: String) {
        guard !model.isEmpty else { return }
        Task { @MainActor in
            // Publish only when the displayed value changes. Prefill emits a
            // progress event per batch; republishing each one re-evaluates
            // every observing view body (FloatingInputCard observes this hub)
            // for a tooltip that shows whole percents. Quantize to the visible
            // granularity: stage transitions and 1% steps.
            if let current = self.phases[model], !Self.displayedValueChanged(current, phase) {
                return
            }
            self.phases[model] = phase
        }
    }

    private static func displayedValueChanged(
        _ old: WarmupProgressPhase, _ new: WarmupProgressPhase
    ) -> Bool {
        switch (old, new) {
        case (.loadingModel, .loadingModel):
            return false
        case (.prefilling(let a), .prefilling(let b)):
            if a.stage != b.stage || a.detail != b.detail { return true }
            return percent(a) != percent(b)
        default:
            return true
        }
    }

    private static func percent(_ state: PrefillProgressState) -> Int {
        guard state.totalUnitCount > 0 else { return 0 }
        return Int(Double(state.completedUnitCount) * 100 / Double(state.totalUnitCount))
    }
}
