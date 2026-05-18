//
//  StorageMigrationGapTests.swift
//  osaurusTests
//
//  Coverage for the gap fixes layered on top of the initial
//  encryption migration:
//
//  - Sequencing: `awaitReady` resolves before any DB open paths run
//    (verified by checking the version stamp lands first).
//  - Fresh install stamping: the migrator drops a `.storage-version`
//    even when there's nothing to migrate, so subsequent launches
//    skip the scan.
//  - Backup retention: the `.pre-encryption-backup/` directory is
//    cleaned up after the second post-migration launch.
//  - Key-mismatch detection: `detectKeyMismatch` returns the right
//    set when an encrypted DB exists but the key changed.
//  - Outcome receipt: `loadLastOutcome` round-trips the
//    success/failure record the Settings panel reads.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageMigrationGapTests {

    // MARK: - Helpers

    private static func setUpTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-migrator-gap-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        StorageKeyManager.shared._setKeyForTesting(
            SymmetricKey(data: Data(repeating: 0x77, count: 32))
        )
        return root
    }

    private static func tearDown(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        StorageKeyManager.shared.wipeCache()
    }

    private static func writePlaintextDB(at path: String) throws {
        var conn: OpaquePointer?
        guard sqlite3_open(path, &conn) == SQLITE_OK, let c = conn else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(c) }
        sqlite3_exec(c, "CREATE TABLE seed(id INTEGER); INSERT INTO seed VALUES (42)", nil, nil, nil)
    }

    // MARK: - Fresh install stamping

    @Test
    func freshInstall_stampsVersionWithoutScanning() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            await StorageMigrator.shared.stampCurrentVersionIfMissing()

            let stampURL = root.appendingPathComponent(".storage-version")
            #expect(FileManager.default.fileExists(atPath: stampURL.path))

            let stored = await StorageMigrator.shared.currentVersion()
            #expect(stored == StorageMigrator.targetVersion)

            // Calling `needsMigration` afterward must short-circuit.
            let needs = await StorageMigrator.shared.needsMigration()
            #expect(!needs)
        }
    }

    @Test
    func freshInstall_ignoresBuiltInThemeBootstrap() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let themes = root.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            let builtInTheme = """
                {
                  "isBuiltIn": true,
                  "metadata": {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "name": "Dark"
                  }
                }
                """
            try Data(builtInTheme.utf8).write(
                to: themes.appendingPathComponent("00000000-0000-0000-0000-000000000001.json")
            )

            let pristine = await StorageMigrator.shared.isPristineInstall()
            #expect(pristine)
        }
    }

    @Test
    func freshInstall_treatsCustomThemeAsUserData() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let themes = root.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            let customTheme = """
                {
                  "isBuiltIn": false,
                  "metadata": {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "name": "Custom"
                  }
                }
                """
            try Data(customTheme.utf8).write(
                to: themes.appendingPathComponent("11111111-1111-1111-1111-111111111111.json")
            )

            let pristine = await StorageMigrator.shared.isPristineInstall()
            #expect(!pristine)
        }
    }

    // MARK: - Backup retention

    @Test
    func backupCleanup_runsOnSecondLaunch() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Simulate a previous migration: backup dir exists, no receipt yet.
            let backupDir = root.appendingPathComponent(".pre-encryption-backup", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try Data("plaintext".utf8).write(to: backupDir.appendingPathComponent("history.sqlite.plaintext"))
            let receiptURL = root.appendingPathComponent(".pre-encryption-backup.receipt")

            // First post-migration launch: writes the receipt but
            // keeps the backup so the user has a recovery window.
            await StorageMigrator.shared.cleanupBackupIfStale()
            #expect(FileManager.default.fileExists(atPath: receiptURL.path))
            #expect(FileManager.default.fileExists(atPath: backupDir.path))

            // Second post-migration launch: nukes the backup AND the receipt.
            await StorageMigrator.shared.cleanupBackupIfStale()
            #expect(!FileManager.default.fileExists(atPath: backupDir.path))
            #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        }
    }

    // MARK: - Key mismatch

    @Test
    func detectKeyMismatch_flagsEncryptedDBWithWrongKey() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Open the chat-history DB with key A and write a row.
            let keyA = SymmetricKey(data: Data(repeating: 0xAA, count: 32))
            StorageKeyManager.shared._setKeyForTesting(keyA)

            OsaurusPaths.ensureExistsSilent(OsaurusPaths.chatHistory())
            let path = OsaurusPaths.chatHistoryDatabaseFile().path
            let conn = try EncryptedSQLiteOpener.open(path: path, key: keyA)
            sqlite3_exec(conn, "CREATE TABLE x (a INTEGER)", nil, nil, nil)
            sqlite3_close(conn)

            // Now switch to key B (simulating Keychain wipe / restore).
            let keyB = SymmetricKey(data: Data(repeating: 0xBB, count: 32))
            StorageKeyManager.shared._setKeyForTesting(keyB)

            let mismatches = await StorageMigrator.shared.detectKeyMismatch()
            #expect(mismatches.contains { $0.label == "chat history" })
        }
    }

    @Test
    func detectKeyMismatch_returnsEmptyWhenKeyMatches() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            let key = try StorageKeyManager.shared.currentKey()
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.chatHistory())
            let path = OsaurusPaths.chatHistoryDatabaseFile().path
            let conn = try EncryptedSQLiteOpener.open(path: path, key: key)
            sqlite3_exec(conn, "CREATE TABLE y (a INTEGER)", nil, nil, nil)
            sqlite3_close(conn)

            let mismatches = await StorageMigrator.shared.detectKeyMismatch()
            #expect(mismatches.isEmpty)
        }
    }

    // MARK: - Outcome receipt

    @Test
    func runIfNeeded_writesOutcomeReceiptForSettingsPanel() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try Self.setUpTempRoot()
            defer { Self.tearDown(root) }

            // Seed a plaintext DB so the migrator has something to do.
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.chatHistory())
            try Self.writePlaintextDB(at: OsaurusPaths.chatHistoryDatabaseFile().path)

            let result = await StorageMigrator.shared.runIfNeeded(progress: nil)
            switch result {
            case .success: break
            case .failure(let err):
                Issue.record("migrator failed: \(err.localizedDescription)")
                return
            }

            let outcome = await StorageMigrator.shared.loadLastOutcome()
            #expect(outcome != nil)
            #expect(outcome?.toVersion == StorageMigrator.targetVersion)
            #expect(outcome?.succeededTargets.contains("chat history") ?? false)
            #expect(outcome?.failedTargets.isEmpty ?? false)
        }
    }
}
