//
//  ServerConfigurationStoreTests.swift
//  osaurusTests
//

import XCTest
@testable import osaurus

final class ServerConfigurationStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("osaurus-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        ServerConfigurationStore.overrideDirectory = dir
    }

    override func tearDown() async throws {
        ServerConfigurationStore.overrideDirectory = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testCodableRoundTrip_UsesDefaultsForMissing() throws {
        // Encode a minimal JSON missing optional/new fields
        let partial: [String: Any] = [
            "port": 1234,
            "exposeToNetwork": true
        ]
        let data = try JSONSerialization.data(withJSONObject: partial)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: data)

        XCTAssertEqual(decoded.port, 1234)
        XCTAssertEqual(decoded.exposeToNetwork, true)
        // Defaulted fields
        let defaults = ServerConfiguration.default
        XCTAssertEqual(decoded.numberOfThreads, defaults.numberOfThreads)
        XCTAssertEqual(decoded.backlog, defaults.backlog)
        XCTAssertEqual(decoded.genTopP, defaults.genTopP)
        XCTAssertEqual(decoded.genKVGroupSize, defaults.genKVGroupSize)
        XCTAssertEqual(decoded.genQuantizedKVStart, defaults.genQuantizedKVStart)
        XCTAssertEqual(decoded.genPrefillStepSize, defaults.genPrefillStepSize)
    }

    func testStoreRoundTrip_ReadsWhatWasWritten() throws {
        var config = ServerConfiguration.default
        config.port = 5555
        config.exposeToNetwork = true
        config.genTopP = 0.7
        config.genKVBits = 8
        config.genMaxKVSize = 16384

        ServerConfigurationStore.save(config)
        let loaded = ServerConfigurationStore.load()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, config)
    }
}


