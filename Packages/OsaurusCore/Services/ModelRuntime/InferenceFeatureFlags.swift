//
//  InferenceFeatureFlags.swift
//  osaurus
//
//  Runtime-tunable knobs for the MLX inference path.
//
//  Today the only knob is `mlxBatchEngineMaxBatchSize` — `BatchEngine` is the
//  single MLX entry point (no per-request `TokenIterator` fallback) and the
//  prior osaurus-side scheduler / cooperative-yield / multi-stream gates have
//  all been retired. Their behaviour is now provided by vmlx-swift-lm's actor
//  loop (see `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/BATCH_ENGINE.md`).
//

import Foundation

public enum InferenceFeatureFlags {
    private enum Keys {
        static let mlxBatchEngineMaxSize = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
    }

    /// Maximum number of sequences `BatchEngine` decodes simultaneously per
    /// model. Higher values increase total throughput but also wired-memory
    /// footprint and per-token latency for any single request.
    ///
    /// Defaults to 4 (BatchEngine's own default is 8, but on a typical 32 GB
    /// machine 8 active slots of an MoE model will exhaust the wired cache
    /// budget; 4 is a conservative starting point we can tune up via
    /// `defaults write` without rebuilding).
    ///
    /// Override with:
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8`
    public static var mlxBatchEngineMaxBatchSize: Int {
        let raw = UserDefaults.standard.integer(forKey: Keys.mlxBatchEngineMaxSize)
        return raw > 0 ? min(raw, 32) : 4
    }
}
