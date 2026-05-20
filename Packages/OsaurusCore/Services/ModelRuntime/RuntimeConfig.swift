//
//  RuntimeConfig.swift
//  osaurus
//
//  Snapshot of server-side generation defaults consulted by the MLX runtime.
//
//  KV cache sizing, quantization, prefill step sizing and similar low-level
//  knobs are owned by vmlx-swift's `CacheCoordinator` and `BatchEngine`
//  (see `OSAURUS-INTEGRATION.md`). The only generation-time setting osaurus
//  still needs to thread through is the user's preferred `topP` default.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float

    /// Captures a generation config snapshot from `ServerConfiguration`.
    static func snapshot() async -> RuntimeConfig {
        RuntimeConfig(topP: diskBackedServerConfiguration()?.genTopP ?? 1.0)
    }

    private static func diskBackedServerConfiguration() -> ServerConfiguration? {
        let url = OsaurusPaths.resolvePath(
            new: OsaurusPaths.serverConfigFile(),
            legacy: "ServerConfiguration.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
    }
}
