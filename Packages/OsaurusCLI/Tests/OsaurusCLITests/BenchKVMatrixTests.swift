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
    func testRuntimeSettingsResponseUsesCodableCodecKey() {
        let response: [String: Any] = [
            "status": "ok",
            "settings": [
                "cache": ["liveKVCodec": "turboquant"],
            ],
        ]

        XCTAssertEqual(
            BenchCommand.activeLiveKVCodec(inRuntimeSettingsResponse: response),
            "turboquant"
        )
        XCTAssertNil(
            BenchCommand.activeLiveKVCodec(inRuntimeSettingsResponse: [
                "settings": ["cache": ["live_kv_codec": "turboquant"]],
            ])
        )
    }

    func testTurboQuantProbeSetsExplicitBitsAndPreservesOtherFields() throws {
        let mutated = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant",
            in: sampleConfig
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mutated) as? [String: Any]
        )
        let cache = try XCTUnwrap(root["cache"] as? [String: Any])

        XCTAssertEqual(cache["liveKVCodec"] as? String, "turboquant")
        XCTAssertEqual(cache["turboQuantKeyBits"] as? Int, 3)
        XCTAssertEqual(cache["turboQuantValueBits"] as? Int, 3)
    }

    func testCanonicalProbeAcceptsLoadNormalizationAndReencoding() throws {
        let preNormalization = Data(
            """
            {
              "cache" : {
                "liveKVCodec" : "engine_selected"
              },
              "contractVersion" : 1,
              "mtp" : {
                "acceptedTokensOnlyEnterBaseCache" : true,
                "draftTokenLimit" : null,
                "keepDraftCacheSeparate" : true,
                "mode" : "off"
              }
            }
            """.utf8)
        var canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: preNormalization) as? [String: Any])
        var mtp = try XCTUnwrap(canonical["mtp"] as? [String: Any])
        mtp["mode"] = "auto"
        canonical["mtp"] = mtp

        let canonicalData = try XCTUnwrap(
            BenchCommand.runtimeSettingsData(
                inRuntimeSettingsResponse: ["settings": canonical]))
        let probe = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant",
            in: canonicalData)
        let probeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: probe) as? [String: Any])
        let appReencoded = try JSONSerialization.data(
            withJSONObject: probeObject, options: [.sortedKeys])

        XCTAssertFalse(BenchCommand.configDocumentsMatch(preNormalization, canonicalData))
        XCTAssertNotEqual(probe, appReencoded)
        XCTAssertNoThrow(
            try BenchCommand.verifyKVMatrixReadback(
                requestedData: probe,
                runtimeSettingsResponse: ["settings": probeObject],
                persistedData: appReencoded))
        XCTAssertFalse(
            BenchCommand.configDocumentsMatch(
                Data(#"{"enabled":true}"#.utf8),
                Data(#"{"enabled":1}"#.utf8)))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-normalized-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        try appReencoded.write(to: configURL, options: .atomic)

        XCTAssertTrue(
            try BenchCommand.restoreKVMatrixConfig(
                at: configURL,
                expectedData: [probe],
                originalData: preNormalization))
        XCTAssertEqual(try Data(contentsOf: configURL), preNormalization)
    }

    func testSemanticReadbackMismatchDoesNotClaimConcurrentModification() throws {
        let requested = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant",
            in: sampleConfig)
        var changed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requested) as? [String: Any])
        changed["generation"] = ["temperature": 0.75]
        let changedData = try JSONSerialization.data(withJSONObject: changed)

        XCTAssertThrowsError(
            try BenchCommand.verifyKVMatrixReadback(
                requestedData: requested,
                runtimeSettingsResponse: ["settings": changed],
                persistedData: changedData)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("normalized or migrated"))
            XCTAssertTrue(error.localizedDescription.contains("another settings writer"))
            XCTAssertFalse(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "concurrent modification"))
        }
    }

    func testPersistedReadbackMismatchDoesNotClaimConcurrentModification() throws {
        let requested = try BenchCommand.configData(
            settingLiveKVCodec: "turboquant",
            in: sampleConfig)
        let requestedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requested) as? [String: Any])
        var changedOnDisk = requestedObject
        changedOnDisk["generation"] = ["temperature": 0.75]
        let changedData = try JSONSerialization.data(withJSONObject: changedOnDisk)

        XCTAssertThrowsError(
            try BenchCommand.verifyKVMatrixReadback(
                requestedData: requested,
                runtimeSettingsResponse: ["settings": requestedObject],
                persistedData: changedData)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "differs from /admin/runtime-settings readback"))
            XCTAssertTrue(error.localizedDescription.contains("unrecognized settings change"))
            XCTAssertFalse(
                error.localizedDescription.localizedCaseInsensitiveContains(
                    "concurrent modification"))
        }
    }

    func testEffectiveKVModeRequiresMatchingCacheEnabledModel() {
        let response: [String: Any] = [
            "models": [
                [
                    "name": "mlx/model-a",
                    "cache_enabled": true,
                    "effective_kv_mode": "turbo(3,3)",
                ],
                [
                    "name": "mlx/model-b",
                    "cache_enabled": false,
                    "effective_kv_mode": "fp16",
                ],
            ],
        ]

        XCTAssertEqual(
            BenchCommand.effectiveKVMode(
                inCacheStatsResponse: response,
                model: "mlx/model-a"
            ),
            "turbo(3,3)"
        )
        XCTAssertNil(
            BenchCommand.effectiveKVMode(
                inCacheStatsResponse: response,
                model: "mlx/model-b"
            )
        )
        XCTAssertNil(
            BenchCommand.effectiveKVMode(
                inCacheStatsResponse: response,
                model: "mlx/missing"
            )
        )
    }

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

    func testSettingTurboQuantPreservesSiblingsAndSetsRequiredBits() throws {
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
        XCTAssertEqual(cache["turboQuantKeyBits"] as? Int, 3)
        XCTAssertEqual(cache["turboQuantValueBits"] as? Int, 3)
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
            codec: "engine_selected", effectiveKVMode: "fp16", scenarios: scenarios)
        XCTAssertEqual(block["codec"] as? String, "engine_selected")
        XCTAssertEqual(block["codec_verified"] as? Bool, true)
        XCTAssertEqual(block["effective_kv_mode"] as? String, "fp16")
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

    func testBackupCleanupRequiresByteIdenticalOriginalConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-matrix-backup-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("server-runtime.json")
        let backup = BenchCommand.kvMatrixBackupURL(for: configURL)
        try sampleConfig.write(to: configURL, options: .atomic)
        try sampleConfig.write(to: backup, options: .atomic)

        XCTAssertTrue(
            try BenchCommand.removeKVMatrixBackupIfOriginalIsIntact(
                configURL: configURL,
                originalData: sampleConfig,
                backupURL: backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        let concurrent = Data(#"{"cache":{"liveKVCodec":"engine_selected"},"writer":"settings"}"#.utf8)
        try concurrent.write(to: configURL, options: .atomic)
        try sampleConfig.write(to: backup, options: .atomic)

        XCTAssertFalse(
            try BenchCommand.removeKVMatrixBackupIfOriginalIsIntact(
                configURL: configURL,
                originalData: sampleConfig,
                backupURL: backup))
        XCTAssertEqual(try Data(contentsOf: configURL), concurrent)
        XCTAssertEqual(try Data(contentsOf: backup), sampleConfig)
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
