//
//  BatchEnginePlan.swift
//  osaurus
//
//  Historical record of the `BatchEngine` integration. The runtime path is
//  now fully wired in `BatchEngineAdapter.swift` + the
//  `mlxBatchEngineEnabled` branch of `ModelRuntime.generateEventStream`,
//  so this file's role has shrunk to documentation: what's still pending
//  upstream and what to flip on to use the engine.
//

import Foundation

/// Documentation namespace tracking the state of the `BatchEngine` integration.
/// Public so future tuning work has an obvious landing spot in the file tree.
public enum BatchEnginePlan {

    /// Default `maxBatchSize` we'd pass to `container.makeBatchEngine(...)`
    /// if the user hasn't overridden it via `defaults write`. The runtime
    /// reads from `InferenceFeatureFlags.mlxBatchEngineMaxBatchSize` which
    /// ships at 4 — see that flag for the rationale.
    public static let suggestedMaxBatchSize = 4

    /// What still doesn't work end-to-end through the batched path. Track
    /// this list when bumping vmlx-swift-lm: any items that close upstream
    /// can have their guard removed in `BatchEngineAdapter`.
    public enum Blocker: String, CaseIterable {
        /// `kvBits` / `kvMode` (TurboQuant + AWQ KV) not applied during
        /// batched decode. Memory footprint per slot grows linearly until
        /// vmlx ships `BatchQuantizedKVCache`.
        case kvQuantization

        /// `compile()` tracing is unavailable due to dynamic batch sizes.
        /// Single-batch decode loses ~2-5 % vs the iterator path; gain comes
        /// from sharing the forward pass across slots.
        case compileSupport
    }

    /// Currently-blocking issues that prevent enabling this by default.
    /// Empty would mean "safe to flip the flag default to ON".
    public static var openBlockers: [Blocker] { Blocker.allCases }

    /// Convenience: `true` when the runtime is actively routing through the
    /// batched path. Mostly useful for diagnostics / tests that want to
    /// assert which path they're exercising.
    public static var isActive: Bool { InferenceFeatureFlags.mlxBatchEngineEnabled }
}
