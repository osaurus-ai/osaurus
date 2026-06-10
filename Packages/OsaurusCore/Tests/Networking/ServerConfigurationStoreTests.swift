//
//  ServerConfigurationStoreTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ServerConfigurationStoreTests {

    @Test func codableRoundTrip_usesDefaultsForMissing() async throws {
        let partial: [String: Any] = [
            "port": 1234,
            "exposeToNetwork": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: partial)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        #expect(decoded.port == 1234)
        #expect(decoded.exposeToNetwork == true)
        let defaults = ServerConfiguration.default
        #expect(decoded.numberOfThreads == defaults.numberOfThreads)
        #expect(decoded.backlog == defaults.backlog)
        #expect(decoded.genTopP == defaults.genTopP)
        #expect(decoded.globalProxyURL == nil)
        #expect(decoded.modelIdleResidencyPolicy == defaults.modelIdleResidencyPolicy)
        #expect(decoded.modelLoadRAMSoftThreshold == defaults.modelLoadRAMSoftThreshold)
        #expect(decoded.modelLoadRAMHardThreshold == defaults.modelLoadRAMHardThreshold)
    }

    @Test @MainActor func storeRoundTrip_readsWhatWasWritten() async throws {
        // Isolate store to a temp directory
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "osaurus-config-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ServerConfigurationStore.overrideDirectory = dir
        defer {
            ServerConfigurationStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }

        var config = ServerConfiguration.default
        config.port = 5555
        config.exposeToNetwork = true
        config.genTopP = 0.7
        config.globalProxyURL = "http://proxy.example.com:8080"
        config.modelLoadRAMSoftThreshold = 0.62
        config.modelLoadRAMHardThreshold = 0.82

        ServerConfigurationStore.save(config)
        let loaded = ServerConfigurationStore.load()

        #expect(loaded != nil)
        #expect(loaded == config)
    }

    /// Decoding pre-migration JSON files that contained now-removed cache*
    /// and gen* fields should succeed silently — unknown keys are ignored
    /// by the decoder. This test simulates that migration by feeding JSON
    /// with fields the schema no longer knows about.
    @Test func decode_ignoresRemovedCacheFields() async throws {
        let json = """
            {
                "port": 1234,
                "cacheEnabled": false,
                "cacheDiskEnabled": false,
                "cacheDiskMaxGB": 8.0,
                "cacheMaxBlocks": 500,
                "genKVBits": 8,
                "genKVGroupSize": 64,
                "genQuantizedKVStart": 512,
                "genPrefillStepSize": 1024,
                "genTurboQuant": true,
                "genMaxKVSize": 8192
            }
            """
        let decoded = try JSONDecoder().decode(
            ServerConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(decoded.port == 1234)
    }

    @Test func modelIdleResidencyPolicy_decodesStableJSON() async throws {
        let json = """
            {
                "port": 1337,
                "modelIdleResidencyPolicy": {
                    "mode": "after_seconds",
                    "seconds": 900
                }
            }
            """
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: Data(json.utf8))

        #expect(decoded.modelIdleResidencyPolicy == .afterSeconds(900))
    }

    @Test func modelIdleResidencyPolicy_defaultsWarmForMultiTurnChat() async throws {
        #expect(ServerConfiguration.default.modelIdleResidencyPolicy == .afterSeconds(900))
        #expect(ModelIdleResidencyPolicy.presets.first == .afterSeconds(300))
        #expect(ModelIdleResidencyPolicy.presets.contains(.immediately))
    }

    @Test @MainActor func modelIdleResidencyPolicy_migratesLegacyImmediateOnce() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "osaurus-config-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ServerConfigurationStore.overrideDirectory = dir
        defer {
            ServerConfigurationStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }

        let legacyJSON = """
            {
                "port": 1337,
                "modelIdleResidencyPolicy": {
                    "mode": "immediately"
                }
            }
            """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("server.json"))

        let migrated = try #require(ServerConfigurationStore.load())
        #expect(migrated.modelIdleResidencyPolicy == .defaultWarm)

        var explicitImmediate = migrated
        explicitImmediate.modelIdleResidencyPolicy = .immediately
        ServerConfigurationStore.save(explicitImmediate)

        let reloaded = try #require(ServerConfigurationStore.load())
        #expect(reloaded.modelIdleResidencyPolicy == .immediately)
    }

    @Test func modelIdleResidencyPolicy_defaultsWhenMalformed() async throws {
        let json = """
            {
                "port": 1337,
                "modelIdleResidencyPolicy": {
                    "mode": "after_seconds",
                    "seconds": "soon"
                }
            }
            """
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: Data(json.utf8))

        #expect(decoded.modelIdleResidencyPolicy == ServerConfiguration.default.modelIdleResidencyPolicy)
    }

    @Test func modelIdleResidencyPolicy_clampsPersistedSeconds() async throws {
        let lowJSON = """
            {
                "modelIdleResidencyPolicy": {
                    "mode": "after_seconds",
                    "seconds": 1
                }
            }
            """
        let highJSON = """
            {
                "modelIdleResidencyPolicy": {
                    "mode": "after_seconds",
                    "seconds": 999999
                }
            }
            """

        let low = try JSONDecoder().decode(ServerConfiguration.self, from: Data(lowJSON.utf8))
        let high = try JSONDecoder().decode(ServerConfiguration.self, from: Data(highJSON.utf8))

        #expect(low.modelIdleResidencyPolicy == .afterSeconds(30))
        #expect(high.modelIdleResidencyPolicy == .afterSeconds(86_400))
    }

    @Test func modelLoadRAMThresholds_decodeClampAndSort() async throws {
        let json = """
            {
                "modelLoadRAMSoftThreshold": 1.25,
                "modelLoadRAMHardThreshold": 0.40
            }
            """
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: Data(json.utf8))

        #expect(decoded.modelLoadRAMSoftThreshold == 0.40)
        #expect(decoded.modelLoadRAMHardThreshold == 1.0)
    }

    @Test func modelIdleResidencyPolicy_encodesStableJSON() async throws {
        let data = try JSONEncoder().encode(ModelIdleResidencyPolicy.afterSeconds(12))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["mode"] as? String == "after_seconds")
        #expect(object["seconds"] as? Int == 30)
    }
}
