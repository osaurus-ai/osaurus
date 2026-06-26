//
//  HostAwareDiskCacheTests.swift
//  osaurusTests
//
//  Proves the host-aware L2 disk-cache cap policy: bound the cap to a fraction
//  of free disk so a constrained volume can't be filled, while leaving healthy
//  hosts untouched (no reuse loss where there's room). See
//  `ModelRuntime.hostAwareDiskCacheDecision` and
//  `perf-gemma4-12b-mxfp8-baseline.md` Lever 2/5.
//

import Foundation
import Testing

@testable import OsaurusCore

struct HostAwareDiskCacheTests {
    private func gib(_ gb: Double) -> Int64 { Int64(gb * 1_073_741_824.0) }

    @Test("healthy host: configured cap is unchanged (no reuse loss)")
    func healthyHostUnchanged() {
        // 100 GB free, default 10 GB cap: 100 * 0.25 = 25 > 10 → cap stays 10.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: gib(100)
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 10.0) < 0.001)
    }

    @Test("threshold host: free == cap/fraction keeps the configured cap")
    func thresholdHostUnchanged() {
        // 40 GB free, 10 GB cap: 40 * 0.25 = 10 → min(10,10) = 10, unchanged.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: gib(40)
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 10.0) < 0.001)
    }

    @Test("constrained host: cap is lowered to the free-disk fraction")
    func constrainedHostLowered() {
        // 26 GB free, 10 GB cap: 26 * 0.25 = 6.5 → cap lowered to 6.5.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: gib(26)
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 6.5) < 0.001)
    }

    @Test("tiny disk: disk tier is disabled below the useful floor")
    func tinyDiskDisabled() {
        // 2 GB free: 2 * 0.25 = 0.5 < 1.0 floor → disabled.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: gib(2)
        )
        #expect(!d.enabled)
    }

    @Test("floor boundary: free that lands exactly on the floor stays enabled")
    func floorBoundaryEnabled() {
        // 4 GB free: 4 * 0.25 = 1.0 == floor → not below → enabled at 1.0.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: gib(4)
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 1.0) < 0.001)
    }

    @Test("unknown free space: configured cap is left as-is")
    func unknownFreeUnchanged() {
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 10,
            freeBytes: 0
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 10.0) < 0.001)
    }

    @Test("explicit small user cap is respected, never raised")
    func smallUserCapRespected() {
        // 100 GB free, user set 2 GB: 100 * 0.25 = 25 → min(2,25) = 2, kept.
        let d = ModelRuntime.hostAwareDiskCacheDecision(
            configuredCapGB: 2,
            freeBytes: gib(100)
        )
        #expect(d.enabled)
        #expect(abs(d.capGB - 2.0) < 0.001)
    }
}
