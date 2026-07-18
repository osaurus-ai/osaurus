//
//  InferenceFeatureFlags.swift
//  osaurus
//
//  Runtime-tunable knobs for the MLX inference path.
//
//  The knobs are `mlxBatchEngineMaxBatchSize` and the opt-in
//  `autoBatchSize` mode (resolve the batch size from observed demand via
//  `BatchAutoscaler`) — `BatchEngine` is the single MLX entry point (no
//  per-request `TokenIterator` fallback) and the prior osaurus-side
//  scheduler / cooperative-yield / multi-stream gates have all been
//  retired. Their behaviour is now provided by vmlx-swift's actor loop
//  (see `vmlx-swift/Libraries/MLXLMCommon/BatchEngine/BATCH_ENGINE.md`).
//

import Foundation
@preconcurrency import MLXLMCommon

public enum InferenceFeatureFlags {
    private enum Keys {
        static let mlxBatchEngineMaxSize = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        static let autoBatchSize = "ai.osaurus.scheduler.autoBatchSize"
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
        mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
    }

    /// Legacy entry point used by tests that exercise the
    /// UserDefaults fallback directly.
    static func mlxBatchEngineMaxBatchSize(in userDefaults: UserDefaults) -> Int {
        let raw = userDefaults.integer(forKey: Keys.mlxBatchEngineMaxSize)
        return raw > 0 ? min(raw, 32) : 1
    }

    /// Preferred entry point. The Server → Settings panel writes
    /// `concurrency.continuousBatching` and
    /// `concurrency.maxConcurrentSequences`; the former gates the multi-slot
    /// scheduler and the latter wins over the legacy `UserDefaults` key.
    /// Tests that have a runtime override pass it explicitly so we don't
    /// depend on `ServerRuntimeSettingsStore`'s on-disk state.
    static func mlxBatchEngineMaxBatchSize(
        in userDefaults: UserDefaults,
        runtime: VMLXServerRuntimeSettings
    ) -> Int {
        guard runtime.concurrency.continuousBatching else { return 1 }
        if let value = runtime.concurrency.maxConcurrentSequences, value > 0 {
            return min(value, 32)
        }
        return mlxBatchEngineMaxBatchSize(in: userDefaults)
    }

    // MARK: - Auto batch sizing (opt-in)

    /// Whether the "auto" batch-sizing pathway is active. Default FALSE —
    /// nothing changes for anyone who hasn't opted in:
    ///
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.autoBatchSize -bool true`
    ///
    /// Auto only applies when NO explicit size is configured: an explicit
    /// `concurrency.maxConcurrentSequences` (Server → Settings) or a legacy
    /// `mlxBatchEngineMaxBatchSize` UserDefaults value is a deliberate
    /// choice of the compile-vs-throughput trade-off and always wins.
    /// `continuousBatching == false` pins single-slot on the legacy path,
    /// so auto (whose whole point is multi-slot escalation) defers to it.
    static var autoBatchSizingEnabled: Bool {
        autoBatchSizingEnabled(
            in: .standard,
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
    }

    static func autoBatchSizingEnabled(
        in userDefaults: UserDefaults,
        runtime: VMLXServerRuntimeSettings
    ) -> Bool {
        guard userDefaults.bool(forKey: Keys.autoBatchSize) else { return false }
        guard runtime.concurrency.continuousBatching else { return false }
        if let explicit = runtime.concurrency.maxConcurrentSequences, explicit > 0 {
            return false
        }
        return userDefaults.integer(forKey: Keys.mlxBatchEngineMaxSize) <= 0
    }

    /// Model-aware resolution used by the generation path.
    ///
    /// With auto batch sizing OFF (the default) this returns exactly what
    /// the legacy `mlxBatchEngineMaxBatchSize(in:runtime:)` resolution
    /// returns — behavior identical to today. With auto ON (and no explicit
    /// size configured) it returns the `BatchAutoscaler` recommendation:
    /// 1 (compiled decode, 9× TTFT) until real overlapping demand for this
    /// model is observed, then the next power of two of the observed
    /// concurrency, capped by the `ChipProfile` hardware tier.
    ///
    /// `autoscaler` / `tierCapOverride` are test seams; production callers
    /// use the shared autoscaler and the host's detected tier. The tier cap
    /// is resolved lazily so the flag-off path never probes hardware.
    static func mlxBatchEngineMaxBatchSize(
        in userDefaults: UserDefaults,
        runtime: VMLXServerRuntimeSettings,
        model: String,
        autoscaler: BatchAutoscaler? = nil,
        tierCapOverride: Int? = nil
    ) async -> Int {
        guard autoBatchSizingEnabled(in: userDefaults, runtime: runtime) else {
            return mlxBatchEngineMaxBatchSize(in: userDefaults, runtime: runtime)
        }
        let tierCap =
            tierCapOverride
            ?? BatchAutoscalerPolicy.tierCap(for: ChipProfile.current.policyTier)
        let scaler = autoscaler ?? BatchAutoscaler.shared
        return await scaler.recommendedBatchSize(for: model, tierCap: tierCap)
    }

    /// Production model-aware entry point (standard defaults + current
    /// runtime settings snapshot).
    static func mlxBatchEngineMaxBatchSize(model: String) async -> Int {
        await mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: ServerRuntimeSettingsStore.snapshot(),
            model: model
        )
    }
}
