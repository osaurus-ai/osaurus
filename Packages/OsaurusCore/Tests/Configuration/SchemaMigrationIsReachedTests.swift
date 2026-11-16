// Host migrations must execute and persist their schema version while preserving
// explicit cache sizing choices, including legacy GB and explicit 10%.

import Foundation
import MLXLMCommon
import XCTest

@testable import OsaurusCore

final class SchemaMigrationIsReachedTests: XCTestCase {

    private var root: URL!
    private var previousTestRoot: String?

    /// The store's own `fileURL()` is private, and the layout is documented at
    /// the top of that file: `<root>/config/server-runtime.json`.
    private func settingsFileURL() -> URL {
        root.appendingPathComponent("config/server-runtime.json")
    }

    override func setUpWithError() throws {
        previousTestRoot = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTestRoot {
            setenv("OSAURUS_TEST_ROOT", previousTestRoot, 1)
        } else {
            unsetenv("OSAURUS_TEST_ROOT")
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a settings file shaped like a real pre-v3 install.
    private func writeLegacySettings(diskCapGB: Double?) throws {
        var settings = VMLXServerRuntimeSettings()
        settings.schemaVersion = nil  // never migrated
        settings.cache.blockDisk.enabled = true
        settings.cache.blockDisk.maxSizeGB = diskCapGB
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsFileURL())
    }

    func testLoadRunsAndPersistsSchemaMigrationWithoutResettingLegacySizes() throws {
        for gb in [10.0, 250.0] {
            try writeLegacySettings(diskCapGB: gb)
            let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())
            XCTAssertEqual(loaded.schemaVersion, VMLXServerRuntimeSettings.contractVersion)
            XCTAssertNil(loaded.cache.blockDisk.maxSizePercent)
            XCTAssertEqual(loaded.cache.blockDisk.maxSizeGB, gb)
            let persisted = try JSONDecoder().decode(
                VMLXServerRuntimeSettings.self,
                from: Data(contentsOf: settingsFileURL())
            )
            XCTAssertEqual(persisted.schemaVersion, VMLXServerRuntimeSettings.contractVersion)
            XCTAssertEqual(persisted.cache.blockDisk.maxSizeGB, gb)
            XCTAssertNil(persisted.cache.blockDisk.maxSizePercent)
            XCTAssertEqual(ServerRuntimeSettingsStore.load()?.cache.blockDisk.maxSizeGB, gb)
        }
    }

    func testExplicitPercentagesAndAutomaticSurviveMigrationAndReload() throws {
        for percent in [nil, 10.0, 33.0, 0.0005] as [Double?] {
            var settings = VMLXServerRuntimeSettings()
            settings.schemaVersion = nil
            settings.cache.blockDisk.maxSizeGB = nil
            settings.cache.blockDisk.maxSizePercent = percent
            try JSONEncoder().encode(settings).write(to: settingsFileURL())
            let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())
            XCTAssertEqual(loaded.schemaVersion, VMLXServerRuntimeSettings.contractVersion)
            XCTAssertEqual(loaded.cache.blockDisk.maxSizePercent, percent)
            XCTAssertNil(loaded.cache.blockDisk.maxSizeGB)
            XCTAssertEqual(ServerRuntimeSettingsStore.load()?.cache.blockDisk.maxSizePercent, percent)
            let persisted = try JSONDecoder().decode(
                VMLXServerRuntimeSettings.self,
                from: Data(contentsOf: settingsFileURL())
            )
            XCTAssertEqual(persisted.cache.blockDisk.maxSizePercent, percent)
        }
    }

    func testMigratedLegacySizeResolvesWithoutInventingAPercentage() throws {
        try writeLegacySettings(diskCapGB: 10.0)
        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())
        let resolved = DiskCacheCapPolicy.resolve(
            percent: loaded.cache.blockDisk.maxSizePercent,
            legacyGB: loaded.cache.blockDisk.maxSizeGB,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_000_000_000_000,
            ownBytes: 0
        )
        XCTAssertEqual(resolved.capBytes, 10 * 1_073_741_824)
    }

    /// Keep the migration on the real store load path.
    func testStoreStillInvokesTheMigration() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Models/Configuration/ServerRuntimeSettingsStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            src.contains("migrateToCurrentSchema()"),
            "the store no longer runs vmlx schema migrations"
        )
    }
}
