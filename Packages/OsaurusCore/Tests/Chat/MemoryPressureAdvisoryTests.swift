//
//  MemoryPressureAdvisoryTests.swift
//  OsaurusCoreTests
//
//  Pins the trigger against two REAL machines, because the intuitive
//  threshold is wrong and firing this warning on a healthy Mac would train
//  users to ignore it.
//
//  Numbers below are measured, not invented:
//    - "struggling" is an M3 Max 64 GB running Ornith-1.5-35B-A3B-JANG_6M
//      at 9.3 tok/s with a 215 s TTFT.
//    - "healthy" is a developer Mac doing nothing, which nonetheless sits at
//      78% of its provisioned swap — the reading that makes swap percentage
//      useless as a signal.
//

import XCTest

@testable import OsaurusCore

final class MemoryPressureAdvisoryTests: XCTestCase {

    private let pageSize = HostMemoryPressureProbe.pageSize

    private func sample(
        freeGB: Double,
        swapUsedGB: Double = 0,
        swapTotalGB: Double = 0,
        decompressions: UInt64,
        swapins: UInt64 = 0,
        at: Date
    ) -> HostMemorySample {
        HostMemorySample(
            freeBytes: UInt64(freeGB * 1_073_741_824),
            compressedBytes: 0,
            swapUsedBytes: UInt64(swapUsedGB * 1_073_741_824),
            swapTotalBytes: UInt64(swapTotalGB * 1_073_741_824),
            decompressions: decompressions,
            swapins: swapins,
            at: at
        )
    }

    // MARK: - The two real machines

    /// M3 Max: 64 MB free, ~154,000 decompressions/s. Must fire.
    func testFiresOnTheMachineThisWasBuiltFrom() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 0.0625, swapUsedGB: 33.1, swapTotalGB: 34.0, decompressions: 0, at: t0)
        let b = sample(
            freeGB: 0.0625, swapUsedGB: 33.1, swapTotalGB: 34.0,
            decompressions: 307_896, at: t0.addingTimeInterval(2))

        let advisory = try XCTUnwrap(
            MemoryPressureAdvisory.evaluate(previous: a, current: b),
            "the machine that produced 9.3 tok/s and a 215s TTFT must trigger the notice")
        XCTAssertEqual(advisory.decompressionPagesPerSecond, 153_948, accuracy: 1)
        // ~2.5 GB/s of pure unpacking overhead.
        XCTAssertGreaterThan(advisory.decompressionBytesPerSecond, 2.0e9)
    }

    /// Healthy dev Mac: 81 GB free, ~6.5 decompressions/s. Must stay silent.
    func testStaysSilentOnAHealthyMachine() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 81.55, swapUsedGB: 3.92, swapTotalGB: 5.0, decompressions: 1_785_958_389, at: t0)
        let b = sample(
            freeGB: 81.55, swapUsedGB: 3.92, swapTotalGB: 5.0,
            decompressions: 1_785_958_402, at: t0.addingTimeInterval(2))

        XCTAssertNil(MemoryPressureAdvisory.evaluate(previous: a, current: b))
    }

    // MARK: - The threshold that would have been wrong

    /// The regression this test exists for: swap percentage was the obvious
    /// trigger and it is not usable. macOS grows swap on demand, so a healthy
    /// machine with 81 GB free reads 78% swap-used. Firing on that alone would
    /// warn constantly on machines with no problem at all.
    func testHighSwapPercentageAloneDoesNotFire() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 81.55, swapUsedGB: 3.92, swapTotalGB: 5.0, decompressions: 0, at: t0)
        let b = sample(
            freeGB: 81.55, swapUsedGB: 3.92, swapTotalGB: 5.0,
            decompressions: 10, at: t0.addingTimeInterval(2))

        XCTAssertGreaterThan(b.swapUsedFraction, 0.75, "precondition: swap really is 78% used")
        XCTAssertNil(
            MemoryPressureAdvisory.evaluate(previous: a, current: b),
            "swap percentage must not be sufficient on its own")
    }

    /// A heavy but brief burst on a machine that still has headroom is an app
    /// launching, not a thrashing box.
    func testHighDecompressionWithFreeMemoryDoesNotFire() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 20, decompressions: 0, at: t0)
        let b = sample(freeGB: 20, decompressions: 400_000, at: t0.addingTimeInterval(2))
        XCTAssertNil(MemoryPressureAdvisory.evaluate(previous: a, current: b))
    }

    /// Low memory alone is normal on a Mac that is simply using its RAM well.
    func testLowFreeMemoryWithoutDecompressionDoesNotFire() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 0.2, decompressions: 0, at: t0)
        let b = sample(freeGB: 0.2, decompressions: 12, at: t0.addingTimeInterval(2))
        XCTAssertNil(MemoryPressureAdvisory.evaluate(previous: a, current: b))
    }

    // MARK: - Degenerate counter inputs

    /// Counters are since-boot and monotonic. A decrease means a reboot or a
    /// reordered read; inventing a rate from it would be fiction.
    func testCounterGoingBackwardsYieldsNoRate() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 0.05, decompressions: 500_000, at: t0)
        let b = sample(freeGB: 0.05, decompressions: 1_000, at: t0.addingTimeInterval(2))
        XCTAssertNil(b.decompressionRate(since: a))
        XCTAssertNil(MemoryPressureAdvisory.evaluate(previous: a, current: b))
    }

    func testZeroElapsedYieldsNoRate() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 0.05, decompressions: 0, at: t0)
        let b = sample(freeGB: 0.05, decompressions: 900_000, at: t0)
        XCTAssertNil(b.decompressionRate(since: a))
        XCTAssertNil(MemoryPressureAdvisory.evaluate(previous: a, current: b))
    }

    /// Rate uses OBSERVED elapsed time, not an assumed sampling interval. A
    /// delayed sample on a struggling machine would otherwise report a rate
    /// inflated by however late it arrived.
    func testRateUsesObservedElapsedTimeNotAnAssumedInterval() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = sample(freeGB: 0.05, decompressions: 0, at: t0)
        let b = sample(freeGB: 0.05, decompressions: 300_000, at: t0.addingTimeInterval(6))
        let rate = try XCTUnwrap(b.decompressionRate(since: a))
        XCTAssertEqual(rate, 50_000, accuracy: 1, "300k over 6s is 50k/s, not 150k/s")
    }

    func testNoSwapProvisionedIsNotADivideByZero() {
        let s = sample(freeGB: 4, swapUsedGB: 0, swapTotalGB: 0, decompressions: 0, at: Date())
        XCTAssertEqual(s.swapUsedFraction, 0)
    }

    // MARK: - Copy

    /// It has to say it is NOT the model, or the user concludes the model is
    /// broken — which is exactly what happened before this existed.
    func testWarningBlamesTheMachineNotTheModelAndGivesAnAction() {
        let advisory = MemoryPressureAdvisory(
            freeBytes: 65_000_000, swapUsedBytes: 35_000_000_000,
            decompressionPagesPerSecond: 154_000)
        let text = advisory.warningText
        XCTAssertTrue(text.contains("isn't the model itself"), text)
        XCTAssertTrue(text.contains("Other apps"), text)
        XCTAssertTrue(text.lowercased().contains("quit"), text)
        for jargon in ["decompress", "compressor", "swap-in", "page fault", "vm_stat", "KV"] {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(jargon),
                "kernel jargon '\(jargon)' leaked into user-facing copy: \(text)")
        }
    }

    func testFormattingSwitchesUnitsAtOneGigabyte() {
        XCTAssertEqual(MemoryPressureAdvisory.format(bytes: 1_073_741_824), "1.0 GB")
        XCTAssertEqual(MemoryPressureAdvisory.format(bytes: 65_000_000), "62 MB")
    }

    // MARK: - The live probe

    /// The probe must return real numbers on a real machine. A nil here would
    /// mean the Mach call is wrong and the whole feature is inert.
    func testProbeReadsThisMachine() throws {
        let s = try XCTUnwrap(HostMemoryPressureProbe.sample())
        XCTAssertGreaterThan(s.freeBytes, 0)
        XCTAssertGreaterThan(s.decompressions, 0, "since-boot counter is never 0 on a running Mac")
    }
}
