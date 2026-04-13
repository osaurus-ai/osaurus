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
        #expect(decoded.genMaxKVSize == nil)
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
        config.genMaxKVSize = 16384

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
                "genTurboQuant": true
            }
            """
        let decoded = try JSONDecoder().decode(
            ServerConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(decoded.port == 1234)
    }
}
