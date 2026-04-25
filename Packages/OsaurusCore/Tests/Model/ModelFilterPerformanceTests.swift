//
//  ModelFilterPerformanceTests.swift
//
//  Covers the Performance filter added to `ModelFilterState`. The filter
//  exposes the already-computed `MLXModel.compatibility(totalMemoryGB:)`
//  assessment — same three buckets the per-row badge renders — so picking
//  "Runs Well" or "Hide Too Large" matches visible badges 1:1.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelFilterState Performance filter")
struct ModelFilterPerformanceTests {

    /// Mid-size dense model (~3 GB on disk, ~4.5 GB resident after
    /// overhead multiplier). The actual multiplier lives in
    /// `MLXModel.estimatedMemoryGB` — we use whole-GB round numbers here
    /// so the buckets below are interpretable at a glance.
    private static func model(_ name: String, gbOnDisk: Double) -> MLXModel {
        let bytes = Int64(gbOnDisk * 1024 * 1024 * 1024)
        return MLXModel(
            id: "test/\(name)",
            name: name,
            description: "",
            downloadURL: "https://example.com/\(name)",
            downloadSizeBytes: bytes
        )
    }

    // MARK: - Fixture bucket sanity

    /// Sanity-check the fixtures: at 16 GB of RAM, our three sample
    /// models end up in the three compatibility buckets we want to
    /// exercise. If MLXModel's overhead multiplier or the 0.75 / 0.95
    /// ratio thresholds ever change and the fixtures drift, this test
    /// catches it before any filter assertion fails mysteriously.
    @Test("Fixture buckets land in compatible / tight / tooLarge at 16 GB total")
    func fixtureBucketsCorrect() {
        // MLXModel applies a 1.2× overhead multiplier to disk-bytes.
        // compatibility thresholds: <0.75 ratio → compatible,
        // <0.95 → tight, ≥0.95 → tooLarge. At total=16 GB:
        //   gbOnDisk=2  → 2.4 GB resident (ratio 0.15) → compatible
        //   gbOnDisk=11 → 13.2 GB resident (ratio 0.825) → tight
        //   gbOnDisk=14 → 16.8 GB resident (ratio 1.05) → tooLarge
        let total = 16.0
        let small = Self.model("small", gbOnDisk: 2.0)
        let mid = Self.model("mid", gbOnDisk: 11.0)
        let big = Self.model("big", gbOnDisk: 14.0)
        #expect(small.compatibility(totalMemoryGB: total) == .compatible)
        #expect(mid.compatibility(totalMemoryGB: total) == .tight)
        #expect(big.compatibility(totalMemoryGB: total) == .tooLarge)
    }

    // MARK: - runsWell

    @Test("runsWell keeps only .compatible entries")
    func runsWellKeepsOnlyCompatible() {
        let total = 16.0
        let models = [
            Self.model("small", gbOnDisk: 2.0),
            Self.model("mid", gbOnDisk: 11.0),
            Self.model("big", gbOnDisk: 14.0),
        ]
        var state = ModelManager.ModelFilterState()
        state.performance = .runsWell
        let out = state.apply(to: models, totalMemoryGB: total).map(\.name)
        #expect(out == ["small"])
    }

    @Test("runsWell drops unknown-memory models (conservative)")
    func runsWellDropsUnknownMemory() {
        // A model without downloadSizeBytes has `estimatedMemoryGB == nil`
        // → `compatibility == .unknown`. runsWell is an affirmative
        // allowlist: only `.compatible` passes. Ambiguous models are OUT.
        let unknown = MLXModel(
            id: "test/unknown",
            name: "unknown",
            description: "",
            downloadURL: "https://example.com/unknown"
        )
        var state = ModelManager.ModelFilterState()
        state.performance = .runsWell
        let out = state.apply(to: [unknown], totalMemoryGB: 16.0).map(\.name)
        #expect(out.isEmpty)
    }

    // MARK: - hideTooLarge

    @Test("hideTooLarge drops only .tooLarge; tight and compatible pass")
    func hideTooLargeDropsOnlyTooLarge() {
        let total = 16.0
        let models = [
            Self.model("small", gbOnDisk: 2.0),
            Self.model("mid", gbOnDisk: 11.0),
            Self.model("big", gbOnDisk: 14.0),
        ]
        var state = ModelManager.ModelFilterState()
        state.performance = .hideTooLarge
        let out = state.apply(to: models, totalMemoryGB: total).map(\.name)
        // small (compatible) + mid (tight) stay; big (tooLarge) dropped.
        #expect(out.sorted() == ["mid", "small"])
    }

    @Test("hideTooLarge keeps unknown-memory models (benefit of the doubt)")
    func hideTooLargeKeepsUnknown() {
        // hideTooLarge is a negative filter: we exclude ONLY models we
        // KNOW are too large. Unknown-memory models pass through so users
        // don't lose visibility on newly-indexed / undercounted models.
        let unknown = MLXModel(
            id: "test/unknown",
            name: "unknown",
            description: "",
            downloadURL: "https://example.com/unknown"
        )
        var state = ModelManager.ModelFilterState()
        state.performance = .hideTooLarge
        let out = state.apply(to: [unknown], totalMemoryGB: 16.0).map(\.name)
        #expect(out == ["unknown"])
    }

    // MARK: - No-op guards

    @Test("totalMemoryGB == 0 no-ops the Performance filter (monitor not ready)")
    func zeroMemoryIsNoOp() {
        // `SystemMonitorService` reports `totalMemoryGB == 0` before its
        // first sample. If we applied the filter in that window we'd
        // empty the model list on cold launch. `PerformanceFilter.matches`
        // short-circuits to `true` when totalMemoryGB <= 0.
        let models = [
            Self.model("small", gbOnDisk: 2.0),
            Self.model("big", gbOnDisk: 14.0),
        ]
        var state = ModelManager.ModelFilterState()
        state.performance = .runsWell
        let out = state.apply(to: models, totalMemoryGB: 0).map(\.name)
        #expect(out.sorted() == ["big", "small"])
    }

    @Test("performance = nil no-ops filter regardless of totalMemoryGB")
    func nilPerformanceIsNoOp() {
        let models = [
            Self.model("small", gbOnDisk: 2.0),
            Self.model("big", gbOnDisk: 14.0),
        ]
        let state = ModelManager.ModelFilterState()
        let out = state.apply(to: models, totalMemoryGB: 16.0).map(\.name)
        #expect(out.sorted() == ["big", "small"])
    }

    // MARK: - Interaction with other filter dimensions

    @Test("Performance composes with paramCategory (logical AND)")
    func composesWithParamCategory() {
        // Stack paramCategory = .small ON TOP OF performance = .runsWell:
        // both must hold. `paramCategory.matches` requires
        // `parameterCountBillions`; we construct models with explicit
        // param counts via the name-parsing heuristic would be fragile,
        // so we only exercise the Performance dimension here and confirm
        // a missing-param model drops out when paramCategory is set.
        let models = [
            Self.model("small", gbOnDisk: 2.0)
        ]
        var state = ModelManager.ModelFilterState()
        state.performance = .runsWell
        state.paramCategory = .small
        let out = state.apply(to: models, totalMemoryGB: 16.0).map(\.name)
        // `parameterCountBillions` is nil without explicit metadata →
        // `paramCategory.matches` returns false → filtered out even
        // though Performance would pass.
        #expect(out.isEmpty)
    }

    // MARK: - isActive / reset

    @Test("performance toggles isActive")
    func performanceFlipsActive() {
        var state = ModelManager.ModelFilterState()
        #expect(!state.isActive)
        state.performance = .runsWell
        #expect(state.isActive)
        state.performance = nil
        #expect(!state.isActive)
    }

    @Test("reset clears performance too")
    func resetClearsPerformance() {
        var state = ModelManager.ModelFilterState()
        state.performance = .hideTooLarge
        state.typeFilter = .llm
        state.reset()
        #expect(state.performance == nil)
        #expect(state.typeFilter == .all)
        #expect(!state.isActive)
    }
}
