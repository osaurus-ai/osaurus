//
//  MemoryBandwidthCalibrationTests.swift
//  osaurus
//
//  The CLI carries a standalone copy of the calibration probe, spec table,
//  and record shape (it does not link OsaurusCore — see the cross-reference
//  in MemoryBandwidthCalibration.swift). These tests pin the copies to the
//  Core originals: spec-table parity on hardcoded rows, and record-shape
//  compatibility through the same JSON fixture string kept in
//  ChipProfileCalibrationTests (OsaurusCore). No absolute bandwidth numbers
//  are asserted anywhere — those are machine-dependent.
//

import Foundation
import XCTest

@testable import OsaurusCLICore

final class MemoryBandwidthCalibrationTests: XCTestCase {

    /// JSON contract fixture — keep byte-identical to the copy in
    /// `ChipProfileCalibrationTests` (OsaurusCore), which decodes it into
    /// the Core `CalibrationRecord`. Together the two tests freeze the
    /// on-disk shape the CLI writes and the server reads.
    private static let recordFixtureJSON = """
        {"chip":"Apple M4 Pro","measuredAt":"2026-07-07T12:00:00Z",\
        "measuredBandwidthGBps":210.5,"osVersion":"macOS 26.0","probeThreads":8}
        """

    /// Encoding the CLI record must reproduce the fixture object exactly —
    /// same keys, same values — so the Core Codable can decode CLI output.
    func testRecordEncodesToTheSharedFixtureShape() throws {
        let record = MemoryBandwidthCalibration.Record(
            measuredBandwidthGBps: 210.5,
            chip: "Apple M4 Pro",
            measuredAt: "2026-07-07T12:00:00Z",
            osVersion: "macOS 26.0",
            probeThreads: 8
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)

        let encodedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        let fixtureObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(Self.recordFixtureJSON.utf8))
                as? NSDictionary)
        XCTAssertEqual(encodedObject, fixtureObject)
    }

    /// And the mirrored struct must decode what Core (or an older CLI) wrote.
    func testRecordDecodesTheSharedFixture() throws {
        let record = try JSONDecoder().decode(
            MemoryBandwidthCalibration.Record.self,
            from: Data(Self.recordFixtureJSON.utf8))
        XCTAssertEqual(record.measuredBandwidthGBps, 210.5)
        XCTAssertEqual(record.chip, "Apple M4 Pro")
        XCTAssertEqual(record.measuredAt, "2026-07-07T12:00:00Z")
        XCTAssertEqual(record.osVersion, "macOS 26.0")
        XCTAssertEqual(record.probeThreads, 8)
    }

    /// Spec-table parity with the Core copy, pinned by hardcoded rows (the
    /// two tables are shared-by-convention, not by code).
    func testSpecTableParityRows() {
        XCTAssertEqual(MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M1"), 68)
        XCTAssertEqual(
            MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M1 Ultra"), 800)
        XCTAssertEqual(
            MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M3 Ultra"), 819)
        XCTAssertEqual(
            MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M4 Max"), 546)
        XCTAssertEqual(
            MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M5 Pro"), 307)
        XCTAssertNil(
            MemoryBandwidthCalibration.specBandwidthGBps(brandString: "Apple M4 Extreme"))
        XCTAssertNil(
            MemoryBandwidthCalibration.specBandwidthGBps(
                brandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"))
    }

    /// Estimator parity with the documented formula (same constant as Core).
    func testEstimatorFormula() {
        XCTAssertEqual(MemoryBandwidthCalibration.decodeEfficiency, 0.7)
        let tps = MemoryBandwidthCalibration.estimatedDecodeTps(
            weightsBytes: 18_200_000_000, bandwidthGBps: 391)
        XCTAssertEqual(tps, 391e9 * 0.7 / 18.2e9, accuracy: 1e-9)
        XCTAssertEqual(
            MemoryBandwidthCalibration.estimatedDecodeTps(weightsBytes: 0, bandwidthGBps: 391), 0)
    }

    /// Tiny-buffer smoke run only (full ~1 GiB probe is user-initiated via
    /// `osaurus bench --calibrate`, never run by tests). Runs the parallel
    /// path (2 threads) so slice/aggregate arithmetic is exercised. Shape
    /// only: > 0, finite — never an absolute number.
    func testProbeSmokeWithTinyBuffers() {
        let gbps = MemoryBandwidthCalibration.measureBandwidthGBps(
            bufferBytes: 1 << 20, secondsPerTrial: 0.02, trials: 1, threads: 2)
        XCTAssertGreaterThan(gbps, 0)
        XCTAssertTrue(gbps.isFinite)
    }

    /// Thread-count parity with the Core copy (cap 8, floor 1).
    func testDefaultThreadCountCapAndFloor() {
        XCTAssertEqual(
            MemoryBandwidthCalibration.defaultThreadCount(activeProcessorCount: 16), 8)
        XCTAssertEqual(
            MemoryBandwidthCalibration.defaultThreadCount(activeProcessorCount: 4), 4)
        XCTAssertEqual(
            MemoryBandwidthCalibration.defaultThreadCount(activeProcessorCount: 0), 1)
    }

    func testDefaultBufferSizeFallsBackOnSmallRAM() {
        XCTAssertEqual(
            MemoryBandwidthCalibration.defaultBufferBytes(physicalMemoryBytes: 16 << 30),
            256 << 20)
        XCTAssertEqual(
            MemoryBandwidthCalibration.defaultBufferBytes(physicalMemoryBytes: 32 << 30),
            1 << 30)
    }

    /// `osaurus show` prints the estimate only for locally installed models;
    /// the weights sum is the recursive `.safetensors` total.
    func testWeightsBytesSumsLocalSafetensors() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-weights-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shardDir = dir.appendingPathComponent("shards", isDirectory: true)
        try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        try Data(count: 1_024).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data(count: 2_048).write(
            to: shardDir.appendingPathComponent("model-00001-of-00002.safetensors"))
        try Data(count: 512).write(to: dir.appendingPathComponent("config.json"))

        XCTAssertEqual(ShowCommand.weightsBytes(under: dir), 3_072)
        XCTAssertNil(
            ShowCommand.weightsBytes(
                under: dir.appendingPathComponent("missing", isDirectory: true)))
    }

    /// The server's `/health` scan root is the authoritative models base
    /// dir; this pins the JSON contract (`local_model_scan.root`).
    func testModelsRootExtractionFromHealthJSON() throws {
        let fixture = """
            {"status":"healthy","local_model_scan":{"status":"finished",\
            "root":"/Users/someone/MLXModels","root_exists":true,"model_count":5}}
            """
        let health = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(
            ShowCommand.modelsRoot(fromHealth: health)?.path, "/Users/someone/MLXModels")

        // Missing block, null root, and empty root all mean "unknown".
        XCTAssertNil(ShowCommand.modelsRoot(fromHealth: ["status": "healthy"]))
        XCTAssertNil(
            ShowCommand.modelsRoot(fromHealth: ["local_model_scan": ["root": NSNull()]]))
        XCTAssertNil(ShowCommand.modelsRoot(fromHealth: ["local_model_scan": ["root": ""]]))
    }

    /// The server lists lowercased ids while directories keep their casing;
    /// resolution must try the exact nesting first, then a case-insensitive
    /// two-level scan (org/repo layout).
    func testResolveLocalModelDirectoryTriesBothNameForms() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base
            .appendingPathComponent("OsaurusAI", isDirectory: true)
            .appendingPathComponent("Qwen3.6-35B-A3B-MXFP4-MTP", isDirectory: true)
        let flat = base.appendingPathComponent("gemma-4-E2B-it-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)

        // Exact nesting (as `osaurus pull` lays out).
        XCTAssertEqual(
            ShowCommand.resolveLocalModelDirectory(
                forModelId: "OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP", under: base)?.lastPathComponent,
            "Qwen3.6-35B-A3B-MXFP4-MTP")
        // Lowercased forms must resolve to the same directories. Compare
        // case-insensitively: on the (default) case-insensitive APFS the
        // exact-nesting branch already matches and returns the caller's
        // spelling, while on a case-sensitive volume the scan branch returns
        // the on-disk casing — both point at the same directory.
        // Single-component server id → level-2 leaf match.
        XCTAssertEqual(
            ShowCommand.resolveLocalModelDirectory(
                forModelId: "qwen3.6-35b-a3b-mxfp4-mtp", under: base)?
                .lastPathComponent.lowercased(),
            "qwen3.6-35b-a3b-mxfp4-mtp")
        // org/name id → full relative-path match.
        XCTAssertEqual(
            ShowCommand.resolveLocalModelDirectory(
                forModelId: "osaurusai/qwen3.6-35b-a3b-mxfp4-mtp", under: base)?
                .lastPathComponent.lowercased(),
            "qwen3.6-35b-a3b-mxfp4-mtp")
        // Flat id → level-1 match.
        XCTAssertEqual(
            ShowCommand.resolveLocalModelDirectory(
                forModelId: "gemma-4-e2b-it-4bit", under: base)?
                .lastPathComponent.lowercased(),
            "gemma-4-e2b-it-4bit")
        // Not installed → nil (silent skip upstream).
        XCTAssertNil(
            ShowCommand.resolveLocalModelDirectory(forModelId: "not-a-model", under: base))
    }
}
