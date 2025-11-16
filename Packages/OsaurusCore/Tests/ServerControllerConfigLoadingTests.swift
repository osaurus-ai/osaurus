//
//  ServerControllerConfigLoadingTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ServerControllerConfigLoadingTests {

    @Test @MainActor func controllerLoadsSavedConfigurationOnInit() async throws {
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
        config.port = 4242
        config.exposeToNetwork = true
        ServerConfigurationStore.save(config)

        let controller = ServerController()
        #expect(controller.configuration.port == 4242)
        #expect(controller.configuration.exposeToNetwork == true)
    }
}
