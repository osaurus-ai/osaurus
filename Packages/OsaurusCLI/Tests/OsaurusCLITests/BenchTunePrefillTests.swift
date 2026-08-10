//
//  BenchTunePrefillTests.swift
//  osaurus
//
//  Tests for `osaurus bench --tune-prefill` winner selection (noise-floor
//  tie-break) and for the interrupted-sweep restore path.
//

import XCTest

@testable import OsaurusCLICore

final class BenchTunePrefillTests: XCTestCase {
    // MARK: - Winner selection (noise-floor tie-break)

    func testWinnerEmptyResultsIsNil() {
        XCTAssertNil(BenchCommand.selectTuneWinner([]))
    }

    func testWinnerClearWinOutsideNoiseFloorPicksFaster() {
        // 4096 is >3% faster than everything else: it must win even though
        // it is the largest step.
        let results: [(step: Int, medianTTFTMs: Double)] = [
            (512, 1_000), (1_024, 950), (2_048, 900), (4_096, 700),
        ]
        XCTAssertEqual(BenchCommand.selectTuneWinner(results)?.step, 4_096)
    }

    func testWinnerNearTieResolvesToSmallestStep() {
        // 4096 "wins" by 0.4% — inside the 3% noise floor, so the smallest
        // step within the band (2048) is chosen instead.
        let results: [(step: Int, medianTTFTMs: Double)] = [
            (512, 1_100), (1_024, 1_050), (2_048, 1_004), (4_096, 1_000),
        ]
        let winner = BenchCommand.selectTuneWinner(results)
        XCTAssertEqual(winner?.step, 2_048)
        XCTAssertEqual(winner?.medianTTFTMs, 1_004)
    }

    func testWinnerAllWithinNoiseFloorPicksSmallestStep() {
        let results: [(step: Int, medianTTFTMs: Double)] = [
            (4_096, 1_000), (512, 1_020), (2_048, 1_010),
        ]
        XCTAssertEqual(BenchCommand.selectTuneWinner(results)?.step, 512)
    }

    func testWinnerJustOutsideNoiseFloorIsExcluded() {
        // 512 is 3.5% slower than the best: outside the band, so the best
        // itself wins.
        let results: [(step: Int, medianTTFTMs: Double)] = [
            (512, 1_035), (4_096, 1_000),
        ]
        XCTAssertEqual(BenchCommand.selectTuneWinner(results)?.step, 4_096)
    }

    // MARK: - Interrupted-sweep restore

    private func makeTempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-tune-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("prefill-tuning.json")
    }

    func testRestorePreviousRecordAndPreserveForeignModels() throws {
        let file = makeTempFile()
        let original: [String: Any] = ["prefillStepSize": 512, "chip": "Apple M5 Max"]
        try BenchCommand.writeTuningRecord(at: file, model: "model-a", record: original)
        try BenchCommand.writeTuningRecord(at: file, model: "model-b", record: ["prefillStepSize": 2_048])

        // Sweep installs a candidate, then aborts.
        try BenchCommand.writeTuningRecord(
            at: file, model: "model-a",
            record: ["prefillStepSize": 4_096, "note": "candidate under test"])
        BenchCommand.restoreTuningRecord(at: file, model: "model-a", previous: original)

        let records = BenchCommand.readTuningRecords(at: file)
        XCTAssertEqual(records["model-a"]?["prefillStepSize"] as? Int, 512)
        XCTAssertEqual(records["model-a"]?["chip"] as? String, "Apple M5 Max")
        XCTAssertNil(records["model-a"]?["note"])
        XCTAssertEqual(records["model-b"]?["prefillStepSize"] as? Int, 2_048)
    }

    func testRestoreRemovesKeyWhenNoPreviousRecordExisted() throws {
        let file = makeTempFile()
        try BenchCommand.writeTuningRecord(
            at: file, model: "model-a",
            record: ["prefillStepSize": 1_024, "note": "candidate under test"])
        BenchCommand.restoreTuningRecord(at: file, model: "model-a", previous: nil)
        XCTAssertNil(BenchCommand.readTuningRecords(at: file)["model-a"])
    }

    func testAbortRestoreRestoresRecordAndRemovesBackupSidecar() throws {
        // Exercises the exact body the SIGINT/SIGTERM handlers run.
        let file = makeTempFile()
        let backup = URL(fileURLWithPath: file.path + ".tune-backup")
        let previous: [String: Any] = ["prefillStepSize": 512]
        try BenchCommand.writeTuningRecord(at: file, model: "model-a", record: previous)
        try Data(contentsOf: file).write(to: backup)
        try BenchCommand.writeTuningRecord(
            at: file, model: "model-a",
            record: ["prefillStepSize": 4_096, "note": "candidate under test"])

        BenchCommand.tuneSweepRestore = (file: file, model: "model-a", previous: previous, backup: backup)
        BenchCommand.tuneSweepAbortRestore()

        XCTAssertEqual(
            BenchCommand.readTuningRecords(at: file)["model-a"]?["prefillStepSize"] as? Int, 512)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(BenchCommand.tuneSweepRestore, "abort restore must clear its state")

        // A second call (e.g. handler fired after an early-exit path already
        // restored) must be a harmless no-op.
        BenchCommand.tuneSweepAbortRestore()
    }
}
