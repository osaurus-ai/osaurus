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
        #expect(decoded.genPrefillStepSize == nil)
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

    // MARK: - Cache tier fields (vmlx migration)

    /// Decoding JSON without any cache fields should leave them all as nil —
    /// which the runtime interprets as "default on" for enabled flags.
    @Test func cacheFields_missingInJSON_decodeAsNil() async throws {
        let empty = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: empty)
        #expect(decoded.cacheEnabled == nil)
        #expect(decoded.cacheDiskEnabled == nil)
        #expect(decoded.cacheDiskMaxGB == nil)
        #expect(decoded.cacheMaxBlocks == nil)
    }

    /// Full round-trip: encode a config with explicit cache fields, decode,
    /// verify every field matches.
    @Test func cacheFields_fullRoundTrip_preservesExplicitValues() async throws {
        var original = ServerConfiguration.default
        original.cacheEnabled = false
        original.cacheDiskEnabled = false
        original.cacheDiskMaxGB = 8.0
        original.cacheMaxBlocks = 500

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        #expect(decoded.cacheEnabled == false)
        #expect(decoded.cacheDiskEnabled == false)
        #expect(decoded.cacheDiskMaxGB == 8.0)
        #expect(decoded.cacheMaxBlocks == 500)
    }

    /// Explicit `true` for a bool cache field must survive round-trip (not
    /// collapse to nil). This guards against accidentally adding a defaulting
    /// decoder that would lose the explicit-true state.
    @Test func cacheFields_explicitTrueRoundTrip() async throws {
        var original = ServerConfiguration.default
        original.cacheEnabled = true
        original.cacheDiskEnabled = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        #expect(decoded.cacheEnabled == true)
        #expect(decoded.cacheDiskEnabled == true)
    }

    /// Mixing nil and explicit values in the same config decodes correctly.
    /// This is the "user only toggled disk cache, left master at default"
    /// scenario.
    @Test func cacheFields_mixedNilAndExplicit() async throws {
        var original = ServerConfiguration.default
        original.cacheEnabled = nil            // default on
        original.cacheDiskEnabled = false      // explicit off
        original.cacheDiskMaxGB = nil
        original.cacheMaxBlocks = 1500         // explicit

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        #expect(decoded.cacheEnabled == nil)
        #expect(decoded.cacheDiskEnabled == false)
        #expect(decoded.cacheDiskMaxGB == nil)
        #expect(decoded.cacheMaxBlocks == 1500)
    }

    /// Partial JSON with only some cache fields should leave others as nil.
    @Test func cacheFields_partialJSON_onlyDecodedFields() async throws {
        let json = """
        {
            "cacheDiskMaxGB": 2.0,
            "cacheMaxBlocks": 400
        }
        """
        let decoded = try JSONDecoder().decode(
            ServerConfiguration.self, from: Data(json.utf8))
        #expect(decoded.cacheEnabled == nil)
        #expect(decoded.cacheDiskEnabled == nil)
        #expect(decoded.cacheDiskMaxGB == 2.0)
        #expect(decoded.cacheMaxBlocks == 400)
    }
}
