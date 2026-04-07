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
    let turboQuant: Bool

    /// Captures a generation config snapshot. User settings from ServerConfiguration
    /// take precedence; nil/unset values fall through to auto-detection based on
    /// system RAM and model weight size, then to hardcoded defaults.
    static func snapshot(modelWeightsBytes: Int64 = 0) async -> RuntimeConfig {
        let cfg = await ServerController.sharedConfiguration()
        let userKVBits = cfg?.genKVBits
        let effectiveKVBits = userKVBits ?? Self.autoKVBits(modelWeightsBytes: modelWeightsBytes)
        let effectiveQuantStart: Int
        if userKVBits != nil {
            effectiveQuantStart = cfg?.genQuantizedKVStart ?? 0
        } else {
            effectiveQuantStart = effectiveKVBits != nil ? 512 : 0
        }
        let effectiveTurboQuant: Bool
        if let explicit = cfg?.genTurboQuant {
            effectiveTurboQuant = explicit
        } else {
            effectiveTurboQuant = Self.autoTurboQuant(modelWeightsBytes: modelWeightsBytes)
        }
        return RuntimeConfig(
            topP: cfg?.genTopP ?? 1.0,
            kvBits: effectiveKVBits,
            kvGroup: cfg?.genKVGroupSize ?? 64,
            quantStart: effectiveQuantStart,
            maxKV: cfg?.genMaxKVSize ?? Self.defaultMaxKV(),
            prefillStep: cfg?.genPrefillStepSize ?? Self.defaultPrefillStep(),
            turboQuant: effectiveTurboQuant
        )
    }

    /// Auto-enable 8-bit KV cache quantization when the headroom after model
    /// weights is less than 16 GB. Only kicks in when the user hasn't
    /// explicitly configured genKVBits.
    private static func autoKVBits(modelWeightsBytes: Int64) -> Int? {
        guard modelWeightsBytes > 0 else { return nil }
        let systemRAM = Int64(ProcessInfo.processInfo.physicalMemory)
        let headroom = systemRAM - modelWeightsBytes
        return headroom < 16 * 1024 * 1024 * 1024 ? 8 : nil
    }

    /// Auto-enable TurboQuant when the headroom after model weights is less
    /// than 16 GB. Uses the same threshold as autoKVBits.
    private static func autoTurboQuant(modelWeightsBytes: Int64) -> Bool {
        guard modelWeightsBytes > 0 else { return false }
        let systemRAM = Int64(ProcessInfo.processInfo.physicalMemory)
        let headroom = systemRAM - modelWeightsBytes
        return headroom < 16 * 1024 * 1024 * 1024
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

    /// Larger prefill steps process more prompt tokens per GPU batch, improving
    /// prompt throughput. Machines with more RAM can handle bigger steps without
    /// memory spikes during the prefill attention workspace allocation.
    private static func defaultPrefillStep() -> Int {
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        switch ramGB {
        case 0 ..< 24: return 1024
        case 24 ..< 64: return 2048
        default: return 4096
        }
    }
}
