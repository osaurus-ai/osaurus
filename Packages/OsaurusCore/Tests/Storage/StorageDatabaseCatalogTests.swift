//
//  StorageDatabaseCatalogTests.swift
//  OsaurusCoreTests
//
//  Pins the production safety net in
//  `StorageDatabaseCatalog.databaseTargets()` that filters out plugin
//  IDs created by leaked test runs (`com.test.*`). Without this
//  filter, key rotation / plaintext export would enumerate test
//  UUIDs the user never created.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageDatabaseCatalogTests {

    private static func setUpTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-target-filter-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        return root
    }

    private static func tearDown(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// Drop a fake plugin DB at `Tools/<id>/data/data.db` so it
    /// looks like the real thing to `databaseTargets()`. Only the
    /// path needs to exist — the catalog decides whether to enroll
    /// the target purely from the directory layout.
    private static func seedPluginDB(rootDir: URL, pluginId: String) throws {
        let dataDir =
            rootDir
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: dataDir.appendingPathComponent("data.db"))
    }

    // MARK: - Static helper

    @Test
    func isLeakedTestPluginId_recognisesComTestPrefix() {
        #expect(StorageDatabaseCatalog.isLeakedTestPluginId("com.test.ratelimit.ABCD"))
        #expect(StorageDatabaseCatalog.isLeakedTestPluginId("com.test.minimal"))
        #expect(StorageDatabaseCatalog.isLeakedTestPluginId("com.test."))
        #expect(!StorageDatabaseCatalog.isLeakedTestPluginId("com.acme.weather"))
        #expect(!StorageDatabaseCatalog.isLeakedTestPluginId("ai.osaurus.skill"))
        #expect(!StorageDatabaseCatalog.isLeakedTestPluginId(""))
    }

    // MARK: - databaseTargets() filtering

    @Test
    func databaseTargets_skipsComTestPluginIds() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            try Self.seedPluginDB(rootDir: root, pluginId: "com.acme.weather")
            try Self.seedPluginDB(rootDir: root, pluginId: "com.test.ratelimit.\(UUID().uuidString)")
            try Self.seedPluginDB(rootDir: root, pluginId: "com.test.minimal")

            let targets = StorageDatabaseCatalog.databaseTargets()
            let pluginLabels = targets.map(\.label).filter { $0.hasPrefix("plugin ") }

            #expect(
                pluginLabels.contains("plugin com.acme.weather"),
                "real plugins must be enrolled"
            )
            #expect(
                !pluginLabels.contains(where: { $0.contains("com.test.") }),
                "com.test.* plugins must be filtered: \(pluginLabels)"
            )
        }
    }

    @Test
    func databaseTargets_alwaysEnrollsCoreSet() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Leave the Tools dir empty — only core targets should be
            // enrolled. This catches accidental over-broad filters
            // that drop "chat history" / "memory" / etc.
            let targets = StorageDatabaseCatalog.databaseTargets()
            let labels = Set(targets.map(\.label))
            #expect(
                labels == [
                    "agent channels",
                    "chat history",
                    "memory",
                    "methods",
                    "router billing",
                    "scheduler",
                    "tool index",
                ]
            )
        }
    }
}
