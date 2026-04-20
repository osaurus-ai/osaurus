//
//  InferenceFeatureFlags.swift
//  osaurus
//
//  Compile-time + runtime flags for risky scheduler features.
//
//  Each flag here gates behaviour that is correct in theory but hasn't yet
//  burned in under production load. Defaults are conservative — the previous
//  behaviour (no flag set) is what ships unless the user has explicitly
//  opted in via `defaults write`.
//

import Foundation

/// Mutable runtime flags. The store is `defaults`-backed so a single
/// `defaults write` can flip a behaviour without rebuilding. We keep the
/// reads cheap (one Atomics-style load per token) by caching into a
/// `nonisolated(unsafe)` global on first access.
public enum InferenceFeatureFlags {
    /// Per-flag user-defaults keys. Using a string namespace so a future
    /// settings UI can enumerate them.
    private enum Keys {
        static let cooperativeYield = "ai.osaurus.scheduler.cooperativeYield"
        static let mlxAllowConcurrentStreams = "ai.osaurus.scheduler.mlxAllowConcurrentStreams"
        static let mlxBatchEngine = "ai.osaurus.scheduler.mlxBatchEngine"
        static let mlxBatchEngineMaxSize = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
    }

    /// When true, `StreamAccumulator` yields the cooperative thread pool
    /// between tokens whenever the scheduler has higher-priority work queued.
    ///
    /// This does NOT preempt MLX (the GPU work continues on its own task);
    /// it only frees the cooperative pool so other Swift Concurrency work —
    /// plugin event delivery, SwiftUI redraws, log flushing — can run while
    /// the GPU produces the next token. Reduces "frozen UI" symptoms during
    /// long streams without introducing a true preemption mechanism (which
    /// would require deeper integration with `MLXLMCommon.TokenIterator`).
    ///
    /// Off by default; enable with:
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.cooperativeYield -bool YES`
    public static var cooperativeYieldEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.cooperativeYield)
    }

    /// When true, `MetalGate.enterGeneration` no longer mutually-excludes
    /// MLX-vs-MLX (it still gates MLX-vs-CoreML). Combined with the per-model
    /// `ModelWorker`, two streams of *different* models can run concurrently
    /// — useful when the user has `manualMultiModel` eviction policy and
    /// enough RAM/wired-memory headroom for both models.
    ///
    /// CAUTION: `MetalGate`'s docstring notes that overlapping Metal
    /// submissions can `EXC_BAD_ACCESS` on Apple Silicon. The MLX-vs-MLX
    /// risk has not been broadly validated; opting in here is at the
    /// operator's discretion. Same-model concurrency remains forbidden by
    /// the per-model worker regardless of this flag.
    ///
    /// Off by default; enable with:
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.mlxAllowConcurrentStreams -bool YES`
    public static var mlxAllowConcurrentStreams: Bool {
        UserDefaults.standard.bool(forKey: Keys.mlxAllowConcurrentStreams)
    }

    /// Route MLX inference through `BatchEngine` (continuous batching) instead
    /// of the per-request `TokenIterator` path.
    ///
    /// `BatchEngine` lives in `vmlx-swift-lm` and provides 2.5–5× throughput
    /// when multiple requests for the same model arrive concurrently — they
    /// share a single decode forward pass. See
    /// `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/BATCH_ENGINE.md`.
    ///
    /// As of vmlx-swift-lm `c101739` the prior blockers are largely closed:
    ///   - Multi-turn KV cache reuse: each slot calls `coordinator.fetch()`
    ///     before prefill and `coordinator.storeAfterGeneration()` after,
    ///     including SSM companion state and disk cache.
    ///   - VLM cache: `mediaSalt` mixes a pixel fingerprint into the cache
    ///     key, so "same text + same image" hits and "same text + different
    ///     image" misses correctly.
    ///   - Sliding-window models: round-trip ring-buffer + 5-tuple metaState
    ///     via `.rotating` LayerKind in the v2 `TQDiskSerializer`.
    ///
    /// Remaining trade-offs:
    ///   - KV-cache quantization (`kvBits`/`kvMode`) still not applied during
    ///     batched decode. Memory footprint per slot grows linearly until
    ///     vmlx ships `BatchQuantizedKVCache`.
    ///   - `compile()` tracing is unavailable due to dynamic batch sizes —
    ///     dense single-batch decode loses ~2-5% vs the iterator path; gain
    ///     comes purely from sharing the forward pass across slots.
    ///   - When this flag is on, `ModelRuntime` skips `MetalGate`,
    ///     `InferenceScheduler`, and the per-model `ModelWorker` for MLX
    ///     paths because the engine's actor loop is the serialization point.
    ///     `ModelLease` and per-plugin in-flight caps still apply.
    ///
    /// Off by default; enable with:
    ///   `defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngine -bool YES`
    public static var mlxBatchEngineEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.mlxBatchEngine)
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
