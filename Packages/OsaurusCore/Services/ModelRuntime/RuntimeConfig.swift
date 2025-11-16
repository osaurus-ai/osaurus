//
//  RuntimeConfig.swift
//  osaurus
//
//  Captures a snapshot of server-side generation configuration used by MLX.
//

import Foundation

struct RuntimeConfig: Sendable {
    let topP: Float
    let kvBits: Int?
    let kvGroup: Int
    let quantStart: Int
    let maxKV: Int?
    let prefillStep: Int

    static func snapshot() async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        return RuntimeConfig(
            topP: cfg?.genTopP ?? 1.0,
            kvBits: cfg?.genKVBits,
            kvGroup: cfg?.genKVGroupSize ?? 64,
            quantStart: cfg?.genQuantizedKVStart ?? 0,
            maxKV: cfg?.genMaxKVSize,
            prefillStep: cfg?.genPrefillStepSize ?? 512
        )
    }
}
