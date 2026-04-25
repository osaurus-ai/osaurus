//
//  StorageMigratorJSONRecoveryTests.swift
//  osaurusTests
//
//  Coverage for the v1→v2 JSON-recovery path on
//  `StorageMigrator`. The initial v1 build encrypted JSON files to
//  `.osec` without teaching the consuming stores to read them, so
//  the user's agents/themes/config silently disappeared on next
//  launch. v2 walks the tree and restores `.osec` JSON twins back
//  to plaintext (preferring the pre-encryption backup, falling
//  back to AES-GCM decrypt).
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageMigratorJSONRecoveryTests {

    private static func setUpTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-recovery-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        StorageKeyManager.shared._setKeyForTesting(
            SymmetricKey(data: Data(repeating: 0xC0, count: 32))
        )
        return root
    }

    private static func tearDown(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        StorageKeyManager.shared.wipeCache()
    }

    /// Drop a `.osec` JSON twin at `dirPath/name.json.osec` AND a
    /// matching backup under `.pre-encryption-backup/json/name.json`.
    /// Mirrors what the buggy v1 migrator left on disk.
    private static func seedEncryptedJSON(
        rootDir: URL,
        relativeDir: String,
        filename: String,
        plaintext: Data,
        seedBackup: Bool
    ) throws {
        let dir = rootDir.appendingPathComponent(relativeDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let osec = dir.appendingPathComponent(filename + ".osec")
        try EncryptedFileStore.write(plaintext, to: osec)
        if seedBackup {
            let backupDir =
                rootDir
                .appendingPathComponent(".pre-encryption-backup", isDirectory: true)
                .appendingPathComponent("json", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try plaintext.write(to: backupDir.appendingPathComponent(filename))
        }
    }

    // MARK: - Tests

    @Test
    func runIfNeeded_restoresOsecBackToJsonViaBackup() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Simulate the buggy v1 state.
            let agentBytes = Data("{\"name\":\"Alice\"}".utf8)
            try Self.seedEncryptedJSON(
                rootDir: root,
                relativeDir: "agents",
                filename: "alice.json",
                plaintext: agentBytes,
                seedBackup: true
            )
            // Stamp v1 so the migrator runs the v1→v2 recovery branch.
            try "1".write(
                to: root.appendingPathComponent(".storage-version"),
                atomically: true,
                encoding: .utf8
            )

            let result = await StorageMigrator.shared.runIfNeeded(progress: nil)
            switch result {
            case .success(let v):
                #expect(v == StorageMigrator.targetVersion)
            case .failure(let err):
                Issue.record("migrator failed: \(err.localizedDescription)")
                return
            }

            let restored =
                root
                .appendingPathComponent("agents", isDirectory: true)
                .appendingPathComponent("alice.json")
            let osec =
                root
                .appendingPathComponent("agents", isDirectory: true)
                .appendingPathComponent("alice.json.osec")
            #expect(FileManager.default.fileExists(atPath: restored.path))
            #expect(!FileManager.default.fileExists(atPath: osec.path))
            #expect(try Data(contentsOf: restored) == agentBytes)
        }
    }

    @Test
    func runIfNeeded_decryptsInPlaceWhenBackupMissing() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // No backup → recovery must AES-GCM decrypt the .osec
            // in place instead of giving up.
            let bytes = Data("{\"theme\":\"dark\"}".utf8)
            try Self.seedEncryptedJSON(
                rootDir: root,
                relativeDir: "themes",
                filename: "midnight.json",
                plaintext: bytes,
                seedBackup: false
            )
            try "1".write(
                to: root.appendingPathComponent(".storage-version"),
                atomically: true,
                encoding: .utf8
            )

            _ = await StorageMigrator.shared.runIfNeeded(progress: nil)

            let restored =
                root
                .appendingPathComponent("themes", isDirectory: true)
                .appendingPathComponent("midnight.json")
            #expect(FileManager.default.fileExists(atPath: restored.path))
            #expect(try Data(contentsOf: restored) == bytes)
        }
    }

    @Test
    func runIfNeeded_noLongerEncryptsJSON() async throws {
        // Sanity check that the v1 step is now JSON-free. A
        // freshly-seeded plaintext JSON file should remain
        // plaintext after the migrator completes — no `.osec`
        // sibling should appear.
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let agentDir = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
            let plain = agentDir.appendingPathComponent("untouched.json")
            try Data("{\"a\":1}".utf8).write(to: plain)

            _ = await StorageMigrator.shared.runIfNeeded(progress: nil)

            #expect(FileManager.default.fileExists(atPath: plain.path))
            #expect(
                !FileManager.default.fileExists(atPath: plain.appendingPathExtension("osec").path),
                "v1 must NOT encrypt JSON files anymore — that bug stranded user data on first install"
            )
        }
    }

    @Test
    func recovery_skipsAttachmentBlobsAndContainerState() async throws {
        // The recovery walk must NOT touch `.osec` files under
        // `chat-history/blobs/` (those are content-addressed
        // attachment spillovers — they must stay encrypted) or
        // anywhere under `container/` (sandbox runtime state).
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // A real attachment blob — sha256.osec, no plaintext twin.
            let blobDir =
                root
                .appendingPathComponent("chat-history", isDirectory: true)
                .appendingPathComponent("blobs", isDirectory: true)
            try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
            let blob = blobDir.appendingPathComponent("deadbeef.osec")
            try EncryptedFileStore.write(Data(repeating: 0xAA, count: 64), to: blob)

            // A bogus .osec under container/ — recovery must ignore.
            let containerJSONDir =
                root
                .appendingPathComponent("container", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: containerJSONDir, withIntermediateDirectories: true)
            let containerOsec = containerJSONDir.appendingPathComponent("ignore.json.osec")
            try EncryptedFileStore.write(Data("{}".utf8), to: containerOsec)

            try "1".write(
                to: root.appendingPathComponent(".storage-version"),
                atomically: true,
                encoding: .utf8
            )

            _ = await StorageMigrator.shared.runIfNeeded(progress: nil)

            #expect(FileManager.default.fileExists(atPath: blob.path))
            #expect(FileManager.default.fileExists(atPath: containerOsec.path))
        }
    }
}
