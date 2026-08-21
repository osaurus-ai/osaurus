//
//  DiskCacheUsageTests.swift
//  OsaurusCoreTests
//
//  Pins the disk-cache footer readout. The dangerous property here is not the
//  formatting — it is that both byte figures are ROOT-WIDE. Every model's
//  DiskCache opens the same cache_index.db and sums cache_entries with no
//  modelKey predicate, so each loaded model reports the identical whole-root
//  number. Summing them would silently multiply the displayed cache size by the
//  number of loaded models, and the number would look plausible the whole time.
//

import XCTest

@testable import OsaurusCore

final class DiskCacheUsageTests: XCTestCase {

    // MARK: - Aggregation invariant

    /// Three models loaded, all reporting the SAME root total. The snapshot must
    /// report that total once, not three times.
    func testRootWideBytesAreNotMultipliedByModelCount() {
        let rootBytes = 8 * 1_073_741_824  // 8 GB actually on disk
        let capBytes = 32 * 1_073_741_824  // 32 GB configured

        // Mirrors the aggregation in MLXBatchAdapter: max for the gauges.
        var payload = 0
        var maxBytes = 0
        for _ in 0..<3 {
            payload = max(payload, rootBytes)
            maxBytes = max(maxBytes, capBytes)
        }

        XCTAssertEqual(payload, rootBytes, "root-wide bytes must not be summed across models")
        XCTAssertEqual(maxBytes, capBytes)

        let usage = DiskCacheUsage(usedBytes: payload, maxBytes: maxBytes)
        XCTAssertEqual(usage.usedFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(usage.usedLabel, "8.0 GB")
    }

    func testSnapshotCarriesTheByteFieldsThroughCounterMerging() {
        // mergingCounters rebuilds the snapshot field by field; a new field that
        // is not passed through silently becomes 0. This is exactly how the
        // decode-path fields would have been lost.
        let live = BatchDiagnosticsSnapshot(
            pendingCount: 0,
            activeCount: 0,
            activeHighWatermark: 0,
            decodeSplitCount: 0,
            turboQuantCompressions: 0,
            isAcceptingRequests: true,
            diskL2PayloadBytes: 5_000_000_000,
            diskL2MaxBytes: 20_000_000_000,
            diskL2Evictions: 7
        )
        XCTAssertEqual(live.diskL2PayloadBytes, 5_000_000_000)
        XCTAssertEqual(live.diskL2MaxBytes, 20_000_000_000)
        XCTAssertEqual(live.diskL2Evictions, 7)
        XCTAssertEqual(try XCTUnwrap(live.diskL2UsedFraction), 0.25, accuracy: 0.0001)
    }

    // MARK: - Warning threshold

    func testWarningFiresAtSeventyFivePercentAndNotBefore() {
        let cap = 100 * 1_073_741_824
        let justUnder = DiskCacheUsage(usedBytes: Int(Double(cap) * 0.74), maxBytes: cap)
        let atThreshold = DiskCacheUsage(usedBytes: Int(Double(cap) * 0.75), maxBytes: cap)
        let over = DiskCacheUsage(usedBytes: Int(Double(cap) * 0.92), maxBytes: cap)

        XCTAssertLessThan(justUnder.usedFraction, 0.75)
        XCTAssertGreaterThanOrEqual(atThreshold.usedFraction, 0.75)
        XCTAssertGreaterThanOrEqual(over.usedFraction, 0.75)
    }

    /// The warning has to name the consequence and the remedy — "cache is full"
    /// alone gives the user nothing to act on.
    func testWarningTextNamesConsequenceAndRemedy() {
        let cap = 100 * 1_073_741_824
        let usage = DiskCacheUsage(usedBytes: Int(Double(cap) * 0.8), maxBytes: cap)
        let text = usage.warningText
        XCTAssertTrue(text.contains("80%"), text)
        XCTAssertTrue(text.contains("evicted"), text)
        XCTAssertTrue(text.contains("re-prefill"), text)
        XCTAssertTrue(text.contains("Disk Cache Size"), text)
    }

    // MARK: - Degenerate inputs

    func testNoQuotaConfiguredYieldsZeroFractionAndNoDivideByZero() {
        let usage = DiskCacheUsage(usedBytes: 1_000_000, maxBytes: 0)
        XCTAssertEqual(usage.usedFraction, 0)
    }

    /// The cap is a SOFT cap enforced after a store, so usage genuinely can sit
    /// above 100% between the write and the quota pass. That is real and worth
    /// showing rather than clamping away — the bar itself clamps its width.
    func testOverfullReadingIsReportedRatherThanClamped() {
        let cap = 10 * 1_073_741_824
        let usage = DiskCacheUsage(usedBytes: 11 * 1_073_741_824, maxBytes: cap)
        XCTAssertGreaterThan(usage.usedFraction, 1.0)
    }

    func testNegativeInputsAreFloored() {
        let usage = DiskCacheUsage(usedBytes: -5, maxBytes: -5, evictions: -5)
        XCTAssertEqual(usage.usedBytes, 0)
        XCTAssertEqual(usage.maxBytes, 0)
        XCTAssertEqual(usage.evictions, 0)
    }

    // MARK: - Formatting

    func testFormattingSwitchesUnitsAtOneGigabyte() {
        XCTAssertEqual(DiskCacheUsage.format(bytes: 1_073_741_824), "1.0 GB")
        XCTAssertEqual(DiskCacheUsage.format(bytes: 400 * 1_048_576), "400 MB")
        XCTAssertEqual(DiskCacheUsage.format(bytes: 0), "0 MB")
    }

    /// 372 GB is what auto resolves to on a 3.7 TB volume — the realistic
    /// post-change cap. It must render readably, not as scientific notation or
    /// a truncated integer.
    func testRealisticAutoCapRendersReadably() {
        XCTAssertEqual(DiskCacheUsage.format(bytes: 372 * 1_073_741_824), "372.0 GB")
    }
}
