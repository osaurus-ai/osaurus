//
//  SchemaMigrationIsReachedTests.swift
//  OsaurusCoreTests
//
//  vmlx defines `migrateToCurrentSchema()` for one-time, version-gated
//  repairs of persisted settings. It had NO CALL SITE in either repo.
//
//  So every repair it defines silently never happened. The v2 repair — a
//  persisted flat 10 GB disk cap becoming auto-sized — never reached a single
//  updating install. Fresh installs looked fine only because their value was
//  nil to begin with and the resolver handles nil, which is exactly the shape
//  that makes a dead migration invisible: the case you test by hand works.
//
//  vmlx's own tests could not catch it. They call the function directly, so
//  they prove it is CORRECT, not that it RUNS. These prove it runs, by going
//  through the store's real load path.
//

import Foundation
import MLXLMCommon
import XCTest

@testable import OsaurusCore

final class SchemaMigrationIsReachedTests: XCTestCase {

    private var root: URL!

    /// The store's own `fileURL()` is private, and the layout is documented at
    /// the top of that file: `<root>/config/server-runtime.json`.
    private func settingsFileURL() -> URL {
        root.appendingPathComponent("config/server-runtime.json")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("OSAURUS_TEST_ROOT")
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

    /// THE test. An install carrying the old flat cap must come back from
    /// `load()` already migrated — not merely migratable.
    func testLoadRunsTheSchemaMigration() throws {
        try writeLegacySettings(diskCapGB: 10.0)

        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        XCTAssertEqual(
            loaded.schemaVersion, VMLXServerRuntimeSettings.contractVersion,
            "load() did not run migrateToCurrentSchema — the migration is dead code again")
        XCTAssertEqual(
            loaded.cache.blockDisk.maxSizePercent, 10.0,
            "the updating install did not land on 10% of its disk")
        XCTAssertNil(loaded.cache.blockDisk.maxSizeGB, "stale absolute cap survived")
    }

    /// The migrated value must be WRITTEN BACK, not just returned. Otherwise
    /// every launch re-migrates and anything the user changes in between is
    /// fighting a repair that keeps re-running.
    func testMigratedSettingsArePersisted() throws {
        try writeLegacySettings(diskCapGB: 10.0)
        _ = ServerRuntimeSettingsStore.load()

        let onDisk = try JSONDecoder().decode(
            VMLXServerRuntimeSettings.self,
            from: Data(contentsOf: settingsFileURL()))

        XCTAssertEqual(
            onDisk.schemaVersion, VMLXServerRuntimeSettings.contractVersion,
            "the migration ran in memory but was never saved")
        XCTAssertEqual(onDisk.cache.blockDisk.maxSizePercent, 10.0)
    }

    /// A hand-set absolute cap is also moved onto the share — the reset is
    /// deliberate and applies to every updating install, not just the ones
    /// still on the shipped default.
    func testAHandSetGigabyteCapIsAlsoReset() throws {
        try writeLegacySettings(diskCapGB: 250.0)

        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        XCTAssertEqual(loaded.cache.blockDisk.maxSizePercent, 10.0)
        XCTAssertNil(loaded.cache.blockDisk.maxSizeGB)
    }

    /// And it must not re-run. A share the user picks after updating has to
    /// survive the next launch, or the "one-time" reset is a permanent
    /// override that quietly discards their choice.
    func testAShareChosenAfterMigrationSurvivesReload() throws {
        try writeLegacySettings(diskCapGB: 10.0)
        var migrated = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        migrated.cache.blockDisk.maxSizePercent = 33
        ServerRuntimeSettingsStore.save(migrated)

        let reloaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())
        XCTAssertEqual(
            reloaded.cache.blockDisk.maxSizePercent, 33,
            "the one-time reset ran again and overwrote a deliberate choice")
    }

    /// The resolved cap must follow from the migrated share, so the value the
    /// engine enforces after an update is a real tenth of the user's disk.
    func testMigratedShareResolvesToATenthOfTheVolume() throws {
        try writeLegacySettings(diskCapGB: 10.0)
        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        let dir = OsaurusPaths.diskKVCache()
        let capacity = try XCTUnwrap(
            VMLXServerRuntimeSettings.cacheVolumeCapacityGB(for: dir))
        let resolved = VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
            percent: loaded.cache.blockDisk.maxSizePercent,
            legacyGB: loaded.cache.blockDisk.maxSizeGB,
            directory: dir)

        XCTAssertEqual(resolved, capacity * 0.10, accuracy: 0.01)
        XCTAssertGreaterThan(resolved, 10.0, "10% of this volume should beat the old flat cap")
    }

    /// Guards the regression directly: the store must reference the migration.
    /// A refactor that drops the call would otherwise only be caught by
    /// noticing settings quietly stopped being repaired.
    func testStoreStillInvokesTheMigration() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Models/Configuration/ServerRuntimeSettingsStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            src.contains("migrateToCurrentSchema()"),
            "the store no longer runs vmlx schema migrations")
    }
}
