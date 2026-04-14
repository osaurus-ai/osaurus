//
//  RuntimeConfig.swift
//  osaurus
//
//  Captures a snapshot of server-side generation configuration used by MLX.
//  KV cache quantization, TurboQuant, and prefill step sizing are now owned
//  by the vmlx-swift-lm package and are no longer user-configurable.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float
    let maxKV: Int?

    /// Captures a generation config snapshot from ServerConfiguration.
    static func snapshot() async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        return RuntimeConfig(
            topP: cfg?.genTopP ?? 1.0,
            maxKV: cfg?.genMaxKVSize ?? Self.defaultMaxKV()
        )
    }

    /// Auto-detect a reasonable maxKV default based on available system RAM.
    /// Machines with more RAM can afford larger context windows.
    private static func defaultMaxKV() -> Int {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        switch ramGB {
        case 0 ..< 24: return 8192
        case 24 ..< 48: return 16384
        case 48 ..< 96: return 32768
        default: return 65536
        }
    }
}
