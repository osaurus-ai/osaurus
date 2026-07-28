//
//  InferenceFeatureFlags.swift
//  osaurus
//
//  Runtime-tunable knobs for the MLX inference path.
//
//  Today the only knob is `mlxBatchEngineMaxBatchSize` — `BatchEngine` is the
//  single MLX entry point (no per-request `TokenIterator` fallback) and the
//  prior osaurus-side scheduler / cooperative-yield / multi-stream gates have
//  all been retired. Their behaviour is now provided by vmlx-swift's actor
//  loop (see `vmlx-swift/Libraries/MLXLMCommon/BatchEngine/BATCH_ENGINE.md`).
//

import Foundation
@preconcurrency import MLXLMCommon

public enum InferenceFeatureFlags {
    /// Maximum number of sequences `BatchEngine` decodes simultaneously per
    /// model. Higher values increase total throughput but also wired-memory
    /// footprint and per-token latency for any single request.
    ///
    /// The value comes exclusively from the canonical
    /// `server-runtime.json` snapshot. Resolution order is Memory Safety's
    /// explicit sequence override, the explicit Server concurrency override,
    /// then the selected Memory Safety profile. Continuous Batching off pins
    /// the capacity to one. The result is clamped to BatchEngine's 1...32
    /// documented ceiling.
    public static var mlxBatchEngineMaxBatchSize: Int {
        mlxBatchEngineMaxBatchSize(runtime: ServerRuntimeSettingsStore.snapshot())
    }

    /// Testable/runtime-explicit entry point that does not depend on global
    /// persisted state.
    static func mlxBatchEngineMaxBatchSize(
        runtime: VMLXServerRuntimeSettings
    ) -> Int {
        ServerRuntimeSettingsStore.resolvedBatchEngineMaxBatchSize(
            for: runtime
        )
    }

    /// Source-compatible bridge for existing admission call sites. The
    /// `UserDefaults` argument is intentionally ignored: that store is a
    /// one-way first-run migration source, never a live runtime authority.
    static func mlxBatchEngineMaxBatchSize(
        in _: UserDefaults,
        runtime: VMLXServerRuntimeSettings
    ) -> Int {
        mlxBatchEngineMaxBatchSize(runtime: runtime)
    }
}
