//
//  StorageExportServiceCleanupTests.swift
//  OsaurusCoreTests
//
//  Pins the safety contract for
//  `StorageExportService.cleanupOrphanedPluginDatabases`:
//
//   - Removes only the plugin directories named in the caller's
//     mismatch list (typically supplied by
//     `StorageMigrator.detectKeyMismatch()`).
//   - Never touches plugin directories that aren't on the list,
//     even if they sit right next to the orphans on disk.
//   - Never touches the four core SQLCipher databases under any
//     circumstance, even if the caller mis-passes them in.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageExportServiceCleanupTests {

    private static func setUpTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-orphan-cleanup-\(UUID().uuidString)",
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

    private static func seedPluginDB(rootDir: URL, pluginId: String) throws {
        let dataDir =
            rootDir
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: dataDir.appendingPathComponent("data.db"))
    }

    private static func pluginDir(rootDir: URL, pluginId: String) -> URL {
        rootDir
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
    }

    @Test
    func cleanupRemovesOnlyOrphanedPluginDirsAndKeepsKnownOnes() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Two real-shape plugins: one we'll mark orphaned, one
            // we'll leave alone. Both directories exist on disk; the
            // caller's mismatch list is the discriminator.
            try Self.seedPluginDB(rootDir: root, pluginId: "com.acme.weather")
            try Self.seedPluginDB(rootDir: root, pluginId: "com.acme.stale")

            // Caller passes only the stale one as a target.
            let mismatch: [StorageMigrator.DatabaseTarget] = [
                .init(
                    label: "plugin com.acme.stale",
                    path: OsaurusPaths.pluginDatabaseFile(for: "com.acme.stale").path
                )
            ]

            let summary = await StorageExportService.shared.cleanupOrphanedPluginDatabases(
                targets: mismatch
            )

            #expect(summary.directoriesRemoved == 1)
            #expect(summary.removedPluginIds == ["com.acme.stale"])
            #expect(
                !FileManager.default.fileExists(
                    atPath: Self.pluginDir(rootDir: root, pluginId: "com.acme.stale").path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: Self.pluginDir(rootDir: root, pluginId: "com.acme.weather").path
                ),
                "untargeted plugin must not be removed"
            )
        }
    }

    @Test
    func cleanupIgnoresCoreTargetsEvenIfPassedIn() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            try Self.seedPluginDB(rootDir: root, pluginId: "com.acme.real")

            // Defense in depth: even if a future caller mis-builds
            // the mismatch array and includes a core DB target, the
            // cleanup must refuse to delete it. Core DB labels never
            // start with `plugin `.
            let dangerous: [StorageMigrator.DatabaseTarget] = [
                .init(label: "chat history", path: OsaurusPaths.chatHistoryDatabaseFile().path),
                .init(label: "memory", path: OsaurusPaths.memoryDatabaseFile().path),
            ]

            let summary = await StorageExportService.shared.cleanupOrphanedPluginDatabases(
                targets: dangerous
            )

            #expect(summary.directoriesRemoved == 0)
            #expect(summary.removedPluginIds.isEmpty)
            #expect(
                FileManager.default.fileExists(
                    atPath: Self.pluginDir(rootDir: root, pluginId: "com.acme.real").path
                )
            )
        }
    }

    @Test
    func cleanupIsIdempotentWhenNothingToRemove() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // No plugins seeded, nothing on the mismatch list.
            let summary = await StorageExportService.shared.cleanupOrphanedPluginDatabases(targets: [])
            #expect(summary.directoriesRemoved == 0)
            #expect(summary.removedPluginIds.isEmpty)
        }
    }
}
