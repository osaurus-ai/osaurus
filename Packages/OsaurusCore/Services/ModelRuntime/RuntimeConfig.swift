//
//  RuntimeConfig.swift
//  osaurus
//
//  Snapshot of server-side generation defaults consulted by the MLX runtime.
//
//  Per-request generation parameters always win. This struct is the
//  fallback layer that applies after model-shipped defaults and before
//  the engine's hardcoded defaults: per-request → model defaults →
//  runtime defaults → engine defaults. Sourced from
//  `VMLXServerRuntimeSettings.generation`.
//

import Foundation
@preconcurrency import MLXLMCommon

struct RuntimeConfig: Sendable {
    /// Generation defaults projected from `runtimeSettings.generation`.
    let generation: VMLXServerGenerationDefaults

    /// Concurrency/runtime batch controls projected from
    /// `runtimeSettings.concurrency`.
    let concurrency: VMLXServerConcurrencySettings

    /// Captures a generation config snapshot from
    /// `VMLXServerRuntimeSettings`. Falls back to `ServerConfiguration`
    /// when the runtime store hasn't been seeded yet.
    static func snapshot() async -> RuntimeConfig {
        let runtime = ServerRuntimeSettingsStore.snapshot()
        // Honor a legacy `genTopP` override even when the new store
        // has no explicit topP override — this keeps any user that
        // edited `server.json` directly working until they touch the
        // new panel and persist via the new store.
        var generation = runtime.generation
        if generation.topP == nil,
            let legacy = diskBackedServerConfiguration(),
            legacy.genTopP != ServerConfiguration.default.genTopP
        {
            generation.topP = Double(legacy.genTopP)
        }
        return RuntimeConfig(
            generation: generation,
            concurrency: runtime.concurrency
        )
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
