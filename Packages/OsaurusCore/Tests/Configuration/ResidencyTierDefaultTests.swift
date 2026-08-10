//
//  ResidencyTierDefaultTests.swift
//  osaurusTests
//
//  Covers the RAM-tier mapping for the idle-residency default and the two
//  contracts around it: explicit user selections are never overridden (the
//  tier default only feeds `ServerConfiguration.default`), and the decode
//  path keeps honoring a persisted policy.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ResidencyTierDefaultTests {

    private func gib(_ n: UInt64) -> UInt64 { n << 30 }

    @Test func smallMachinesReleaseWeightsQuickly() {
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(8))
                == .afterSeconds(120))
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(16))
                == .afterSeconds(120))
    }

    @Test func midRangeKeepsTheEstablishedWarmDefault() {
        for ram in [24, 32, 48, 64, 96] {
            #expect(
                ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(UInt64(ram)))
                    == .defaultWarm,
                "expected defaultWarm at \(ram) GiB")
        }
    }

    @Test func bigMemoryMachinesGetTheHourWindow() {
        // Not `.never`: a default must guarantee weights eventually leave on
        // their own so memory-pressure relief doesn't depend on user action
        // (review feedback on #1902). `.never` stays an explicit choice.
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(128))
                == .afterSeconds(3_600))
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(512))
                == .afterSeconds(3_600))
    }

    @Test func boundariesAreInclusiveLowExclusiveMiddle() {
        // 16 GiB is still "small"; the first byte past it is mid-range.
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(16) + 1)
                == .defaultWarm)
        // One byte short of 128 GiB is still mid-range.
        #expect(
            ModelIdleResidencyPolicy.tierDefault(physicalMemoryBytes: gib(128) - 1)
                == .defaultWarm)
    }

    /// Every value the tier function can return must be a Settings preset,
    /// otherwise the picker has no matching tag on exactly the machines that
    /// tier targets (the ≤ 16 GiB default of 120 s was missing at first).
    @Test func everyTierDefaultIsASettingsPreset() {
        for ram: UInt64 in [4, 8, 16, 24, 64, 127, 128, 512] {
            let tierDefault = ModelIdleResidencyPolicy.tierDefault(
                physicalMemoryBytes: gib(ram))
            #expect(
                ModelIdleResidencyPolicy.presets.contains(tierDefault),
                "tier default for \(ram) GiB (\(tierDefault)) is not a Settings preset")
        }
    }

    @Test func smallTierDefaultRendersTwoMinutes() {
        #expect(ModelIdleResidencyPolicy.afterSeconds(120).displayName == "2 minutes")
    }

    /// A persisted explicit policy must survive decode untouched — the tier
    /// default only applies through `ServerConfiguration.default` when the
    /// key is absent.
    @Test func persistedPolicySurvivesRoundTrip() throws {
        var config = ServerConfiguration.default
        config.modelIdleResidencyPolicy = .afterSeconds(300)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)
        #expect(decoded.modelIdleResidencyPolicy == .afterSeconds(300))
    }
}
