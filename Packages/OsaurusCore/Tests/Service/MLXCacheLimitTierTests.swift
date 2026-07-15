//
//  MLXCacheLimitTierTests.swift
//  osaurusTests
//
//  Covers the RAM-tier policy for the MLX freed-buffer cache cap: small
//  machines get a tighter pool (jetsam headroom), mid-range machines keep
//  the historical heuristic bit-for-bit, and big-memory machines get a
//  larger reuse pool with a sane ceiling.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MLXCacheLimitTierTests {

    private let gib = 1 << 30
    private func ram(_ n: UInt64) -> UInt64 { n << 30 }

    @Test func smallMachinesGetTighterPool() {
        // 8 GiB machine, 4 GiB model: weights/4 = 1 GiB, RAM/10 = 0.8 GiB.
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: 4 * gib, physicalMemoryBytes: ram(8), adaptiveDisabled: false)
                == (8 * gib) / 10)
        // 16 GiB boundary is still "small".
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: 8 * gib, physicalMemoryBytes: ram(16), adaptiveDisabled: false)
                == (16 * gib) / 10)
    }

    @Test func midRangeMatchesHistoricalHeuristicExactly() {
        for ramGiB: UInt64 in [24, 32, 48, 64] {
            let systemRAM = Int(ramGiB) * gib
            let weights = 20 * gib
            let historical = min(max(weights / 4, 1 * gib), min(systemRAM / 8, 8 * gib))
            #expect(
                ModelRuntime.mlxCacheLimitBytes(
                    residentWeightsBytes: weights, physicalMemoryBytes: ram(ramGiB),
                    adaptiveDisabled: false)
                    == historical,
                "expected historical value at \(ramGiB) GiB")
        }
    }

    @Test func bigMemoryMachinesGetLargerPoolWithCeiling() {
        // 128 GiB, 100 GiB resident: weights/4 = 25 GiB, RAM/6 ≈ 21.3 GiB.
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: 100 * gib, physicalMemoryBytes: ram(128), adaptiveDisabled: false)
                == (128 * gib) / 6)
        // 512 GiB: RAM/6 ≈ 85 GiB would mostly hoard; ceiling holds at 24 GiB.
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: 400 * gib, physicalMemoryBytes: ram(512), adaptiveDisabled: false)
                == 24 * gib)
    }

    @Test func escapeHatchRestoresHistoricalFormulaOnBigMachines() {
        // With the adaptive policy disabled, a 128 GiB machine gets the
        // historical min(weights/4, min(RAM/8, 8 GiB)) — not the RAM/6 tier.
        let systemRAM = 128 * gib
        let weights = 100 * gib
        let historical = min(max(weights / 4, 1 * gib), min(systemRAM / 8, 8 * gib))
        #expect(historical == 8 * gib)
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: weights, physicalMemoryBytes: ram(128),
                adaptiveDisabled: true)
                == historical)
    }

    @Test func weightsBoundStillApplies() {
        // Small resident model on a big machine: weights/4 (with the 1 GiB
        // floor) still caps the pool — a 4 GiB model never justifies a
        // 21 GiB reuse pool.
        #expect(
            ModelRuntime.mlxCacheLimitBytes(
                residentWeightsBytes: 4 * gib, physicalMemoryBytes: ram(128), adaptiveDisabled: false)
                == 1 * gib)
    }
}
