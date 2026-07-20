//
//  SharedConfigurationServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SharedConfigurationServiceTests {
    @Test
    func publicationsAreOrderedAndSynchronousQuitRemovalDrainsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-shared-config-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SharedConfigurationService(
            instanceId: "test-instance",
            baseDirectoryOverride: root
        )
        var configuration = ServerConfiguration.default
        configuration.port = 4242
        configuration.exposeToNetwork = true

        service.update(
            health: .running,
            configuration: configuration,
            localAddress: "127.0.0.1"
        )
        service.flushPendingIOForTests()

        let instance = root.appendingPathComponent("test-instance", isDirectory: true)
        let file = instance.appendingPathComponent("configuration.json")
        let data = try Data(contentsOf: file)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["health"] as? String == "running")
        #expect(json["port"] as? Int == 4242)
        #expect(json["exposeToNetwork"] as? Bool == true)

        // Rapid state changes must be applied in submission order. A terminal
        // state cannot be overtaken by an older pending write and resurrect a
        // stale discovery file.
        service.update(
            health: .restarting,
            configuration: configuration,
            localAddress: "127.0.0.1"
        )
        service.update(
            health: .stopped,
            configuration: configuration,
            localAddress: "127.0.0.1"
        )
        service.flushPendingIOForTests()
        #expect(!FileManager.default.fileExists(atPath: instance.path))

        // applicationWillTerminate uses this drain before its hard `_exit`.
        service.update(
            health: .running,
            configuration: configuration,
            localAddress: "127.0.0.1"
        )
        service.removeSynchronously()
        #expect(!FileManager.default.fileExists(atPath: instance.path))
    }
}
