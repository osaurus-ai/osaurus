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

    /// Regression for the 2026-04 providers-wipe outage:
    /// when a `.osec` JSON twin AND a plaintext file BOTH exist
    /// (which is exactly what happens when a consuming store like
    /// `RemoteProviderConfigurationStore.load` synthesized an
    /// empty default while we were broken), recovery must:
    ///
    ///   1. Treat the .osec content as authoritative (it predates
    ///      the empty default).
    ///   2. Archive the existing plaintext to
    ///      `<name>.replaced-by-recovery.json` so the user can
    ///      manually merge anything that was newer.
    ///   3. Write the decrypted .osec content into place.
    ///   4. Delete the .osec.
    ///
    /// Pre-fix this Case-1 collision destroyed the user's real
    /// providers list (the empty plaintext won; the .osec was
    /// silently deleted).
    @Test
    func recovery_prefersOsecOverEmptyPlaintext_andArchivesExisting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let providersDir = root.appendingPathComponent("providers", isDirectory: true)
            try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
            let plainURL = providersDir.appendingPathComponent("remote.json")

            let realData = Data(#"{"providers":[{"name":"Anthropic","host":"api.anthropic.com"}]}"#.utf8)
            try Self.seedEncryptedJSON(
                rootDir: root,
                relativeDir: "providers",
                filename: "remote.json",
                plaintext: realData,
                seedBackup: false
            )

            // Mimic the buggy load() that auto-wrote an empty default.
            let emptyDefault = Data(#"{"providers":[]}"#.utf8)
            try emptyDefault.write(to: plainURL)

            try "1".write(
                to: root.appendingPathComponent(".storage-version"),
                atomically: true,
                encoding: .utf8
            )

            _ = await StorageMigrator.shared.runIfNeeded(progress: nil)

            // Real data must be back at the canonical location.
            #expect(FileManager.default.fileExists(atPath: plainURL.path))
            #expect(
                try Data(contentsOf: plainURL) == realData,
                "recovery must restore the .osec content, not keep the empty default"
            )

            // Archive of the empty default must exist for forensics.
            let archive = providersDir.appendingPathComponent("remote.replaced-by-recovery.json")
            #expect(
                FileManager.default.fileExists(atPath: archive.path),
                "recovery must archive the prior plaintext so users can merge"
            )
            #expect(try Data(contentsOf: archive) == emptyDefault)

            // .osec is consumed.
            let osec = providersDir.appendingPathComponent("remote.json.osec")
            #expect(!FileManager.default.fileExists(atPath: osec.path))
        }
    }

    /// When `.osec` and existing plaintext are byte-identical (e.g.
    /// recovery already ran in a previous launch), recovery just
    /// removes the orphan `.osec` without touching the plaintext
    /// or creating a `.replaced-by-recovery.json` sibling.
    @Test
    func recovery_isIdempotentWhenContentsMatch() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let dir = root.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plainURL = dir.appendingPathComponent("midnight.json")
            let bytes = Data(#"{"theme":"dark"}"#.utf8)

            try Self.seedEncryptedJSON(
                rootDir: root,
                relativeDir: "themes",
                filename: "midnight.json",
                plaintext: bytes,
                seedBackup: false
            )
            try bytes.write(to: plainURL)

            try "1".write(
                to: root.appendingPathComponent(".storage-version"),
                atomically: true,
                encoding: .utf8
            )

            _ = await StorageMigrator.shared.runIfNeeded(progress: nil)

            #expect(try Data(contentsOf: plainURL) == bytes)
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("midnight.json.osec").path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("midnight.replaced-by-recovery.json").path
                ),
                "no archive should be created when contents already match"
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
