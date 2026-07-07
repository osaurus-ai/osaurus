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
