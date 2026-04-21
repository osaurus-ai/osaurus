//
//  RuntimeConfig.swift
//  osaurus
//
//  Snapshot of server-side generation defaults consulted by the MLX runtime.
//
//  KV cache sizing, quantization, prefill step sizing and similar low-level
//  knobs are owned by vmlx-swift-lm's `CacheCoordinator` and `BatchEngine`
//  (see `OSAURUS-INTEGRATION.md`). The only generation-time setting osaurus
//  still needs to thread through is the user's preferred `topP` default.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float

    /// Captures a generation config snapshot from `ServerConfiguration`.
    static func snapshot() async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        return RuntimeConfig(topP: cfg?.genTopP ?? 1.0)
    }
}
