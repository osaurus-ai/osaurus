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
    /// Defaults to **1** so the vmlx compile path engages on Mistral 3 / 4,
    /// Qwen 3.5/3.6, MiniMax, NemotronH, and DSV4 (all the families where
    /// `CompilableKVCache` / `CompilableTurboQuantKVCache` /
    /// `CompilableRotatingKVCache` Stage 1B.3 / Stage 2 / Stage 3 promotion
    /// is shipped). Per vmlx's `OSAURUS-PRODUCTION-REFERENCE-2026-05-01.md`
    /// §8 + §15 invariant 13: compile only engages when `maxBatchSize == 1`
    /// (Stage 1B.4 — per-bucket shared `[B, H, maxLen, D]` buffers — is
    /// pending). With `maxBatchSize > 1` every promotion gate fails and the
    /// model runs the uncompiled decode loop, losing the documented 9× TTFT
    /// speedup vmlx measured on `BENCH_VL_BATCH_CHAT` Mistral 3.5 (24.8s
    /// → 2.7s).
    ///
    /// Osaurus's primary use case is single-user chat through the macOS app,
    /// where only one slot is active at a time anyway. For server-style
    /// deployments serving multiple concurrent users, override:
    ///
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8`
    ///
    /// — at the cost of compile being permanently disabled for that
    /// process. The rate-display rolling tok/s ramp + tooltip alert
    /// surfaces this trade-off in the chat UI when a non-default value is
    /// detected.
    ///
    /// Capped at 32 to match BatchEngine's documented per-engine slot
    /// ceiling. Values <=0 fall back to the compile-friendly 1.
    public static var mlxBatchEngineMaxBatchSize: Int {
        let raw = UserDefaults.standard.integer(forKey: Keys.mlxBatchEngineMaxSize)
        return raw > 0 ? min(raw, 32) : 1
    }
}
