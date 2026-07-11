//
//  BenchKVMatrixTests.swift
//  osaurus
//
//  `--kv-matrix` mutates the user's `server-runtime.json` and MUST hand it
//  back byte-identical, so the config read/modify/restore round-trip is the
//  safety-critical logic here. Table/median math is covered because the JSON
//  report is consumed as policy evidence — a wrong median or a mislabeled
//  low-confidence cell corrupts the TurboQuant decision matrix.
//

import Foundation
import XCTest

@testable import OsaurusCLICore

final class BenchKVMatrixTests: XCTestCase {
    /// Shaped like a real (abridged) server-runtime.json: nested `cache`
    /// object plus sibling sections that must survive the codec edit.
    private let sampleConfig = Data(
        """
        {
          "cache" : {
            "defaultMaxKVSize" : 65536,
            "liveKVCodec" : "engine_selected",
            "storedKVCodec" : "auto",
            "turboQuantKeyBits" : null
          },
          "contractVersion" : 1,
          "network" : {
            "host" : "127.0.0.1",
            "port" : 1337
          }
        }
        """.utf8)

    // MARK: - Config read/modify/restore

    func testSettingCodecRewritesOnlyTheCodecField() throws {
        let mutated = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)

        XCTAssertEqual(BenchCommand.liveKVCodec(inConfigData: mutated), "turboquant")

        // Every sibling field survives the round-trip.
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: mutated) as? [String: Any])
        XCTAssertEqual(root["contractVersion"] as? Int, 1)
        let network = try XCTUnwrap(root["network"] as? [String: Any])
        XCTAssertEqual(network["port"] as? Int, 1337)
        let cache = try XCTUnwrap(root["cache"] as? [String: Any])
        XCTAssertEqual(cache["defaultMaxKVSize"] as? Int, 65536)
        XCTAssertEqual(cache["storedKVCodec"] as? String, "auto")
        XCTAssertTrue(cache["turboQuantKeyBits"] is NSNull)
    }

    func testRoundTripOnTempFileRestoresOriginalBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("server-runtime.json")
        try sampleConfig.write(to: url, options: .atomic)

        // Mutate on disk the way kvMatrix does…
        let original = try Data(contentsOf: url)
        let mutated = try BenchCommand.configData(settingLiveKVCodec: "turboquant", in: original)
        try mutated.write(to: url, options: .atomic)
        XCTAssertEqual(
            BenchCommand.liveKVCodec(inConfigData: try Data(contentsOf: url)), "turboquant")

        // …then restore: the file must be byte-identical to what the user had.
        try original.write(to: url, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: url), sampleConfig)
    }

    func testSettingCodecThrowsOnDocumentWithoutCacheObject() {
        let noCache = Data(#"{"network":{"port":1337}}"#.utf8)
        XCTAssertThrowsError(
            try BenchCommand.configData(settingLiveKVCodec: "turboquant", in: noCache))

        let notAnObject = Data(#"[1,2,3]"#.utf8)
        XCTAssertThrowsError(
            try BenchCommand.configData(settingLiveKVCodec: "turboquant", in: notAnObject))
    }

    func testLiveKVCodecReaderToleratesGarbage() {
        XCTAssertNil(BenchCommand.liveKVCodec(inConfigData: Data("not json".utf8)))
        XCTAssertNil(BenchCommand.liveKVCodec(inConfigData: Data("{}".utf8)))
        XCTAssertEqual(BenchCommand.liveKVCodec(inConfigData: sampleConfig), "engine_selected")
    }

    // MARK: - codec verification contract

    func testCodecBlockCanOnlyRepresentVerifiedEvidence() {
        let scenarios: [[String: Any]] = [["target_prompt_tokens": 8192]]
        let block = BenchCommand.kvMatrixCodecBlock(
            codec: "engine_selected", scenarios: scenarios)
        XCTAssertEqual(block["codec"] as? String, "engine_selected")
        XCTAssertEqual(block["codec_verified"] as? Bool, true)
        XCTAssertEqual((block["scenarios"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(
            block["description"] as? String,
            BenchCommand.kvMatrixCodecDescriptions["engine_selected"])
    }

    // MARK: - Sidecar backup + abort restore

    func testBackupURLIsSidecarNextToConfig() {
        let config = URL(fileURLWithPath: "/tmp/config/server-runtime.json")
        XCTAssertEqual(
            BenchCommand.kvMatrixBackupURL(for: config).path,
            "/tmp/config/server-runtime.json.kvmatrix-backup")
    }

    func testBackupCreationRefusesToOverwriteRecoveryFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("server-runtime.json.kvmatrix-backup")
        let existing = Data("existing recovery".utf8)
        try existing.write(to: backup)

        XCTAssertThrowsError(try BenchCommand.createKVMatrixBackup(sampleConfig, at: backup))
        XCTAssertEqual(try Data(contentsOf: backup), existing)
    }

    func testAbortRestoreRestoresOriginalBytesAndRemovesBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-abort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        try sampleConfig.write(to: configURL, options: .atomic)

        // Run mutates the config after writing the sidecar backup…
        let backup = BenchCommand.kvMatrixBackupURL(for: configURL)
        try sampleConfig.write(to: backup, options: .atomic)
        let mutated = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)
        try mutated.write(to: configURL, options: .atomic)

        // …then the signal handler's body fires.
        BenchCommand.armKVMatrixRestore(
            configURL: configURL,
            originalData: sampleConfig,
            ownedData: [sampleConfig, mutated],
            backup: backup
        )
        BenchCommand.kvMatrixAbortRestore()

        XCTAssertEqual(try Data(contentsOf: configURL), sampleConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(
            BenchCommand.hasKVMatrixRestoreState(),
            "abort restore must disarm itself")

        // A second call must be a harmless no-op.
        BenchCommand.kvMatrixAbortRestore()
        XCTAssertEqual(try Data(contentsOf: configURL), sampleConfig)
    }

    func testAbortRestoreRecognizesPreviousProbeDuringCodecTransition() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-transition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        let backup = BenchCommand.kvMatrixBackupURL(for: configURL)
        let previousProbe = try BenchCommand.configData(
            settingLiveKVCodec: "engine_selected", in: sampleConfig)
        let nextProbe = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)
        try previousProbe.write(to: configURL, options: .atomic)
        try sampleConfig.write(to: backup, options: .atomic)
        BenchCommand.armKVMatrixRestore(
            configURL: configURL,
            originalData: sampleConfig,
            ownedData: [sampleConfig, previousProbe, nextProbe],
            backup: backup)

        XCTAssertTrue(BenchCommand.kvMatrixAbortRestore())
        XCTAssertEqual(try Data(contentsOf: configURL), sampleConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRestoreRefusesToOverwriteConcurrentWriter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        let expected = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)
        let concurrent = Data(#"{"cache":{"liveKVCodec":"engine_selected"},"writer":"settings"}"#.utf8)
        try concurrent.write(to: configURL, options: .atomic)

        let restored = try BenchCommand.restoreKVMatrixConfig(
            at: configURL,
            expectedData: [expected],
            originalData: sampleConfig)

        XCTAssertFalse(restored)
        XCTAssertEqual(try Data(contentsOf: configURL), concurrent)
    }

    func testRestoreVerifiesByteIdenticalOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        let expected = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)
        try expected.write(to: configURL, options: .atomic)

        XCTAssertTrue(
            try BenchCommand.restoreKVMatrixConfig(
                at: configURL,
                expectedData: [expected],
                originalData: sampleConfig))
        XCTAssertEqual(try Data(contentsOf: configURL), sampleConfig)
    }

    func testNextCodecWriteRefusesConcurrentChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        let firstProbe = try BenchCommand.configData(
            settingLiveKVCodec: "engine_selected", in: sampleConfig)
        let secondProbe = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant", in: sampleConfig)
        let concurrent = Data(#"{"cache":{"liveKVCodec":"engine_selected"},"writer":"settings"}"#.utf8)
        try concurrent.write(to: configURL, options: .atomic)

        XCTAssertFalse(
            try BenchCommand.writeKVMatrixConfig(
                at: configURL,
                expectedData: firstProbe,
                newData: secondProbe))
        XCTAssertEqual(try Data(contentsOf: configURL), concurrent)
    }

    // MARK: - Median / low-confidence math

    func testMedian() {
        XCTAssertEqual(BenchCommand.median([]), 0)
        XCTAssertEqual(BenchCommand.median([42]), 42)
        XCTAssertEqual(BenchCommand.median([3, 1, 2]), 2)
        XCTAssertEqual(BenchCommand.median([4, 1, 3, 2]), 2.5)
    }

    func testLowConfidenceFlag() {
        XCTAssertFalse(BenchCommand.kvMatrixIsLowConfidence(completionTokens: [32, 128]))
        XCTAssertTrue(BenchCommand.kvMatrixIsLowConfidence(completionTokens: [128, 31]))
        XCTAssertFalse(BenchCommand.kvMatrixIsLowConfidence(completionTokens: []))
    }

    // MARK: - Table rendering

    func testTableDeltasAreAgainstEngineSelectedBaselineOfSamePromptSize() {
        let cells = [
            BenchCommand.KVMatrixCell(
                codec: "engine_selected", targetPromptTokens: 8192,
                medianUncachedTTFTMs: 1000, medianCachedTTFTMs: 50,
                medianDecodeTps: 40, lowConfidence: false),
            BenchCommand.KVMatrixCell(
                codec: "turboquant", targetPromptTokens: 8192,
                medianUncachedTTFTMs: 1500, medianCachedTTFTMs: 60,
                medianDecodeTps: 28, lowConfidence: true),
        ]
        let lines = BenchCommand.kvMatrixTableLines(cells)

        XCTAssertEqual(lines.count, 3)  // header + one row per cell
        // Baseline row carries no delta annotations.
        XCTAssertFalse(lines[1].contains("%"))
        // Candidate row: +50% uncached TTFT, +20% cached, -30% decode.
        XCTAssertTrue(lines[2].contains("(+50%)"))
        XCTAssertTrue(lines[2].contains("(+20%)"))
        XCTAssertTrue(lines[2].contains("(-30%)"))
        XCTAssertTrue(lines[2].contains("[low-confidence]"))
    }

    func testTableRowsWithoutBaselineOmitDeltas() {
        let cells = [
            BenchCommand.KVMatrixCell(
                codec: "turboquant", targetPromptTokens: 32768,
                medianUncachedTTFTMs: 2000, medianCachedTTFTMs: 80,
                medianDecodeTps: 25, lowConfidence: false)
        ]
        let lines = BenchCommand.kvMatrixTableLines(cells)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[1].contains("%"))
    }
}
