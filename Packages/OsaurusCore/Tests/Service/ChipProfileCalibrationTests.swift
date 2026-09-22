//
//  ChipProfileCalibrationTests.swift
//  osaurusTests
//
//  Covers the machine-wide bandwidth calibration store (round-trip,
//  chip-mismatch invalidation, mtime-based re-read of CLI writes), the pure
//  decode-throughput estimator including its nil paths, the spec-bandwidth
//  table, and a tiny-buffer smoke run of the probe. No test asserts an
//  absolute bandwidth number — those are machine-dependent by definition.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChipProfileCalibrationTests {

    /// JSON contract fixture. The same string lives in the CLI test
    /// (`MemoryBandwidthCalibrationTests` in OsaurusCLITests) — together they
    /// pin the CLI writer and this Core reader to one on-disk shape.
    private static let recordFixtureJSON = """
        {"chip":"Apple M4 Pro","measuredAt":"2026-07-07T12:00:00Z",\
        "measuredBandwidthGBps":210.5,"osVersion":"macOS 26.0","probeThreads":8}
        """

    private func withTempStore<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chip-profile-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("chip-profile.json")
        return try ChipProfileCalibration.$fileURLOverrideForTests.withValue(url) {
            try body(url)
        }
    }

    // MARK: - Store

    @Test func missingFileMeansNoMeasurement() throws {
        try withTempStore { _ in
            #expect(ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M4") == nil)
            #expect(ChipProfileCalibration.storedRecord() == nil)
        }
    }

    @Test func roundTripForMatchingChip() throws {
        try withTempStore { _ in
            try ChipProfileCalibration.save(
                record: .init(
                    measuredBandwidthGBps: 391.2, chip: "Apple M5 Max",
                    measuredAt: "2026-07-07T12:00:00Z", osVersion: "macOS 26.0",
                    probeThreads: 8))
            #expect(
                ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M5 Max") == 391.2)
        }
    }

    @Test func chipMismatchInvalidatesRecord() throws {
        try withTempStore { _ in
            // A Migration Assistant restore moves ~/.osaurus to new hardware;
            // the stored measurement must not be trusted there.
            try ChipProfileCalibration.save(
                record: .init(
                    measuredBandwidthGBps: 391.2, chip: "Apple M1",
                    measuredAt: nil, osVersion: nil, probeThreads: 8))
            #expect(ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M5 Max") == nil)
            // The raw record is still readable — only the validated
            // accessor applies the invalidation rule.
            #expect(ChipProfileCalibration.storedRecord()?.chip == "Apple M1")
        }
    }

    @Test func externalWriteIsPickedUpByMtime() throws {
        try withTempStore { url in
            try ChipProfileCalibration.save(
                record: .init(
                    measuredBandwidthGBps: 100, chip: "Apple M4",
                    measuredAt: nil, osVersion: nil, probeThreads: 8))
            #expect(ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M4") == 100)

            // Simulate the CLI process rewriting the file (fresh JSON, no
            // shared in-process state) with a bumped mtime.
            let json = #"{"measuredBandwidthGBps": 250.0, "chip": "Apple M4", "probeThreads": 4}"#
            try Data(json.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)

            #expect(ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M4") == 250)
        }
    }

    @Test func decodesTheSharedCLIFixture() throws {
        // Must stay decodable as long as the CLI-side test encodes the same
        // fixture — the two tests jointly freeze the JSON contract.
        let record = try JSONDecoder().decode(
            ChipProfileCalibration.CalibrationRecord.self,
            from: Data(Self.recordFixtureJSON.utf8))
        #expect(record.measuredBandwidthGBps == 210.5)
        #expect(record.chip == "Apple M4 Pro")
        #expect(record.measuredAt == "2026-07-07T12:00:00Z")
        #expect(record.osVersion == "macOS 26.0")
        #expect(record.probeThreads == 8)
    }

    @Test func legacySingleThreadedRecordWithoutProbeThreadsIsIgnored() throws {
        try withTempStore { url in
            // A record from the retired single-threaded probe lacks
            // `probeThreads` and its number is not comparable to aggregate
            // measurements — it must fail decode and be re-measured.
            let legacy = #"{"measuredBandwidthGBps": 119.1, "chip": "Apple M5 Max"}"#
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(legacy.utf8).write(to: url, options: .atomic)
            #expect(ChipProfileCalibration.storedRecord() == nil)
            #expect(ChipProfileCalibration.measuredBandwidthGBps(forChip: "Apple M5 Max") == nil)
        }
    }

    @Test func invalidCalibrationBoundsAreIgnored() throws {
        try withTempStore { url in
            let invalidRecords = [
                #"{"measuredBandwidthGBps": 0, "chip": "Apple M5 Max", "probeThreads": 8}"#,
                #"{"measuredBandwidthGBps": -1, "chip": "Apple M5 Max", "probeThreads": 8}"#,
                #"{"measuredBandwidthGBps": 391, "chip": "Apple M5 Max", "probeThreads": 0}"#,
                #"{"measuredBandwidthGBps": 391, "chip": "", "probeThreads": 8}"#,
            ]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (index, json) in invalidRecords.enumerated() {
                try Data(json.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(Double(index + 1))],
                    ofItemAtPath: url.path)
                #expect(ChipProfileCalibration.storedRecord() == nil)
            }
        }
    }

    // MARK: - Estimator

    @Test func estimatorMatchesTheDocumentedFormula() {
        // 391 GB/s × 0.7 ÷ 18.2 GB weights.
        let weights: Int64 = 18_200_000_000
        let tps = ChipProfileCalibration.estimatedDecodeTps(
            weightsBytes: weights, bandwidthGBps: 391)
        #expect(abs(tps - (391e9 * 0.7 / 18.2e9)) < 1e-9)
        // Degenerate weights must not divide by zero.
        #expect(
            ChipProfileCalibration.estimatedDecodeTps(weightsBytes: 0, bandwidthGBps: 391) == 0)
        #expect(
            ChipProfileCalibration.estimatedDecodeTps(
                weightsBytes: weights, bandwidthGBps: 0) == 0)
        #expect(
            ChipProfileCalibration.estimatedDecodeTps(
                weightsBytes: weights, bandwidthGBps: .infinity) == 0)
    }

    @Test func profileEstimatorPrefersMeasuredOverSpec() {
        func profile(brand: String, measured: Double?) -> ChipProfile {
            ChipProfile(
                brandString: brand,
                generation: nil,
                tier: .unknown,
                physicalMemoryBytes: 16 << 30,
                gpuCoreCount: nil,
                recommendedMaxWorkingSetBytes: nil,
                measuredBandwidthGBps: measured
            )
        }
        let weights: Int64 = 10_000_000_000

        // Measured wins even when a spec entry exists (M4 Pro spec is 273).
        let measured = ChipProfileCalibration.estimatedDecodeTps(
            weightsBytes: weights, profile: profile(brand: "Apple M4 Pro", measured: 200))
        #expect(measured == 200e9 * 0.7 / 10e9)

        // No measurement → spec fallback.
        let spec = ChipProfileCalibration.estimatedDecodeTps(
            weightsBytes: weights, profile: profile(brand: "Apple M4 Pro", measured: nil))
        #expect(spec == 273e9 * 0.7 / 10e9)

        // Neither available (unknown chip, never calibrated) → nil.
        #expect(
            ChipProfileCalibration.estimatedDecodeTps(
                weightsBytes: weights,
                profile: profile(brand: "Intel(R) Xeon(R)", measured: nil)) == nil)
    }

    // MARK: - Spec table

    @Test func specTableCoversKnownChipsAndRejectsUnknown() {
        let expected: [String: Double] = [
            "Apple M1": 68, "Apple M1 Pro": 200, "Apple M1 Max": 400, "Apple M1 Ultra": 800,
            "Apple M2": 100, "Apple M2 Pro": 200, "Apple M2 Max": 400, "Apple M2 Ultra": 800,
            "Apple M3": 100, "Apple M3 Pro": 150, "Apple M3 Max": 400, "Apple M3 Ultra": 819,
            "Apple M4": 120, "Apple M4 Pro": 273, "Apple M4 Max": 546,
            "Apple M5": 153, "Apple M5 Pro": 307, "Apple M5 Max": 614,
        ]
        for (brand, bandwidth) in expected {
            #expect(ChipProfileCalibration.specBandwidthGBps(brandString: brand) == bandwidth)
        }
        #expect(ChipProfileCalibration.specBandwidthGBps(brandString: "  Apple M2 \n") == 100)
        #expect(ChipProfileCalibration.specBandwidthGBps(brandString: "Apple M4 Extreme") == nil)
        #expect(
            ChipProfileCalibration.specBandwidthGBps(
                brandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == nil)
        #expect(ChipProfileCalibration.specBandwidthGBps(brandString: "") == nil)
    }

    // MARK: - Probe smoke test

    /// Tiny buffers and short trials on purpose: the full ~1 GiB probe is a
    /// user-initiated CLI action, never something a test suite runs. Runs
    /// the parallel path (2 threads) so slice/aggregate arithmetic is
    /// exercised. Only shape properties are asserted — never an absolute
    /// bandwidth.
    @Test func probeSmokeTestWithTinyBuffers() {
        let gbps = ChipProfileCalibration.measureMemoryBandwidthGBps(
            bufferBytes: 1 << 20, secondsPerTrial: 0.02, trials: 1, threads: 2)
        #expect(gbps > 0)
        #expect(gbps.isFinite)
    }

    @Test func probeBufferSizeFallsBackOnSmallRAMMachines() {
        #expect(
            ChipProfileCalibration.defaultProbeBufferBytes(physicalMemoryBytes: 16 << 30)
                == 256 << 20)
        #expect(
            ChipProfileCalibration.defaultProbeBufferBytes(physicalMemoryBytes: 32 << 30)
                == 1 << 30)
    }

    @Test func probeThreadCountIsCappedAtEightAndFloorsAtOne() {
        #expect(ChipProfileCalibration.defaultProbeThreadCount(activeProcessorCount: 16) == 8)
        #expect(ChipProfileCalibration.defaultProbeThreadCount(activeProcessorCount: 8) == 8)
        #expect(ChipProfileCalibration.defaultProbeThreadCount(activeProcessorCount: 4) == 4)
        #expect(ChipProfileCalibration.defaultProbeThreadCount(activeProcessorCount: 0) == 1)
    }
}
