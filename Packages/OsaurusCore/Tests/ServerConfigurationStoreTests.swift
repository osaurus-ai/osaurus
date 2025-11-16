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
        #expect(decoded.genKVGroupSize == defaults.genKVGroupSize)
        #expect(decoded.genQuantizedKVStart == defaults.genQuantizedKVStart)
        #expect(decoded.genPrefillStepSize == defaults.genPrefillStepSize)
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
        config.genKVBits = 8
        config.genMaxKVSize = 16384

        ServerConfigurationStore.save(config)
        let loaded = ServerConfigurationStore.load()

        #expect(loaded != nil)
        #expect(loaded == config)
    }
}
