//
//  StorageEncryptionToggleTests.swift
//  osaurusTests
//
//  The opt-in encryption toggle against the real key resolution path
//  (issue #3385). `StorageKeyManager.keychainForTesting` stands in for the
//  login Keychain, so `currentKey()` runs its fail-closed guard instead of
//  the ephemeral key `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS` hands out.
//
//  - An install that never had a key (every install since the plaintext
//    default) can turn encryption on, and its stores end up encrypted.
//  - A missing key still fails closed when encrypted data exists, whether
//    it's a database or an `.osec` file, and a locked Keychain never mints.
//  - A stale provisioned marker alone no longer blocks a new key.
//  - Failures are reported: no key means a thrown toggle error and an
//    unchanged posture, not "Encrypted 0 stores".
//  - An install left stuck by the old bug converges on its next launch.
//  - Convergence carries the `sync-local/` state files along and leaves the
//    raw importer ledger alone.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Security
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageEncryptionToggleTests {

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-toggle-tests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func key(seed: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    private func execute(_ conn: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(conn, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "test", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func readSingleText(_ conn: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func seedDB(at path: String, key k: SymmetricKey?, body: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
        try execute(conn, "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")
        try execute(conn, "INSERT INTO notes (body) VALUES ('\(body)')")
        sqlite3_close(conn)
    }

    private func storedKey(_ keychain: StorageKeyTestKeychain) -> SymmetricKey? {
        keychain.value(StorageKeyManager.keyAccount).map { SymmetricKey(data: $0) }
    }

    /// Run `body` against a fresh root and an empty test Keychain, with no key
    /// resident and every live handle from other suites closed (they reopen
    /// against their own root afterwards). Call under `StoragePathsTestLock`.
    private func withFreshInstall(
        _ body: (URL, StorageKeyTestKeychain) async throws -> Void
    ) async throws {
        let previousRoot = OsaurusPaths.overrideRoot
        let previousKey =
            StorageKeyManager.shared.hasCachedKey ? try StorageKeyManager.shared.currentKey() : nil
        let handles = OsaurusDatabaseHandle.allOpenHandles
        for handle in handles { handle.closer() }
        let root = tempDir()
        let keychain = StorageKeyTestKeychain()
        OsaurusPaths.overrideRoot = root
        StorageKeyManager.keychainForTesting = keychain
        StorageEncryptionPolicy.shared.invalidateCache()
        StorageKeyManager.shared.wipeCache()
        defer {
            StorageKeyManager.keychainForTesting = nil
            OsaurusPaths.overrideRoot = previousRoot
            StorageEncryptionPolicy.shared.invalidateCache()
            StorageKeyManager.shared.wipeCache()
            StorageMigrationCoordinator.clearKeyUnavailable()
            if let previousKey { StorageKeyManager.shared._setKeyForTesting(previousKey) }
            for handle in handles { handle.reopener() }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root, keychain)
    }

    // MARK: - #3385: opting in on an install with data

    /// The reported bug. Plaintext stores on disk and no key ever created:
    /// turning encryption on must create a key and encrypt them, not report
    /// "Encrypted 0 stores" and leave everything plaintext.
    @Test
    func enablingEncryptionOnPlaintextInstallWithNoKeyEncryptsStores() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
                let memory = OsaurusPaths.memoryDatabaseFile().path
                let tasks = OsaurusPaths.tasksDatabaseFile().path
                try seedDB(at: memory, key: nil, body: "remember")
                try seedDB(at: tasks, key: nil, body: "todo")
                #expect(keychain.contains(StorageKeyManager.keyAccount) == false)

                let report = try await StorageMigrationCoordinator.shared.setEncryptionEnabled(true)

                #expect(report.keyFailure == nil)
                #expect(report.locked.isEmpty)
                #expect(report.failed.isEmpty)
                #expect(report.converted == 2)
                #expect(StorageEncryptionPolicy.shared.persistedMode() == .encrypted)
                #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .encrypted)

                let k = try #require(storedKey(keychain))
                let conn = try EncryptedSQLiteOpener.open(path: memory, key: k)
                #expect(readSingleText(conn, "SELECT body FROM notes LIMIT 1") == "remember")
                sqlite3_close(conn)
            }
        }
    }

    /// An install left with the marker on `encrypted`, no key and plaintext
    /// files by the old bug converges on its next launch.
    @Test
    func installStuckByOldBugConvergesOnNextLaunch() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { root, keychain in
                try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
                // The old guard's own marker, written by an earlier key read.
                try Data([0x01]).write(to: root.appendingPathComponent(".storage-key.provisioned"))
                let memory = OsaurusPaths.memoryDatabaseFile().path
                try seedDB(at: memory, key: nil, body: "stuck")

                let mode = StorageMigrationCoordinator.resolveLaunchMode()
                #expect(mode == .encrypted)
                let report = await StorageMigrationCoordinator.shared.converge(to: mode)

                #expect(report.keyFailure == nil)
                #expect(report.converted == 1)
                #expect(StorageFileFormat.detect(path: memory) == .encrypted)
                #expect(storedKey(keychain) != nil)
            }
        }
    }

    // MARK: - The fail-closed guard

    @Test
    func missingKeyWithEncryptedDatabaseFailsClosed() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: key(seed: 0x31), body: "old")

                #expect(throws: StorageKeyError.self) {
                    _ = try StorageKeyManager.shared.currentKey()
                }
                #expect(keychain.contains(StorageKeyManager.keyAccount) == false)
                #expect(StorageKeyManager.shared.hasCachedKey == false)
            }
        }
    }

    /// Knowledge stores joined the catalog, so they count as evidence too.
    @Test
    func missingKeyWithEncryptedKnowledgeStoreFailsClosed() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try seedDB(at: OsaurusPaths.knowledgeWriteLogDatabaseFile().path, key: key(seed: 0x32), body: "undo")
                #expect(StorageKeyManager.encryptedArtifactsExist())
                #expect(throws: StorageKeyError.self) {
                    _ = try StorageKeyManager.shared.currentKey()
                }
                #expect(keychain.contains(StorageKeyManager.keyAccount) == false)
            }
        }
    }

    @Test
    func missingKeyWithEncryptedFileFailsClosed() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: nil, body: "plain")
                let blob = AttachmentBlobStore.blobsDir().appendingPathComponent("abc.osec")
                try EncryptedFileStore.write(Data("image".utf8), to: blob, key: key(seed: 0x33))

                #expect(throws: StorageKeyError.self) {
                    _ = try StorageKeyManager.shared.currentKey()
                }
                #expect(keychain.contains(StorageKeyManager.keyAccount) == false)
            }
        }
    }

    /// The provisioned marker outlives a decrypt; on its own it no longer
    /// blocks creating a key when nothing on disk is encrypted.
    @Test
    func staleProvisionedMarkerAloneDoesNotBlockANewKey() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { root, keychain in
                try Data([0x01]).write(to: root.appendingPathComponent(".storage-key.provisioned"))
                try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: nil, body: "plain")
                #expect(StorageKeyManager.encryptedArtifactsExist() == false)

                let k = try StorageKeyManager.shared.currentKey()
                #expect(storedKey(keychain).map { $0.withUnsafeBytes { Data($0) } } == k.withUnsafeBytes { Data($0) })
            }
        }
    }

    /// A Keychain that refuses the read (locked, prompt required) is never
    /// treated as "no key": nothing is minted over it.
    @Test
    func lockedKeychainNeverMintsAKey() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                keychain.readStatus = errSecInteractionNotAllowed
                #expect(throws: StorageKeyError.self) {
                    _ = try StorageKeyManager.shared.currentKey()
                }
                keychain.readStatus = errSecSuccess
                #expect(keychain.contains(StorageKeyManager.keyAccount) == false)
            }
        }
    }

    // MARK: - Failure reporting

    /// No key can be created: the toggle throws, the posture stays plaintext,
    /// and the files are untouched.
    @Test
    func enablingWithoutAUsableKeyThrowsAndKeepsPosture() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
                let memory = OsaurusPaths.memoryDatabaseFile().path
                try seedDB(at: memory, key: nil, body: "plain")
                keychain.writeStatus = errSecAuthFailed

                await #expect(throws: StorageMigrationCoordinator.ToggleError.self) {
                    try await StorageMigrationCoordinator.shared.setEncryptionEnabled(true)
                }
                #expect(StorageEncryptionPolicy.shared.persistedMode() == .plaintext)
                #expect(StorageFileFormat.detect(path: memory) == .plaintext)
            }
        }
    }

    /// Convergence that needs a key it can't get reports every store it
    /// couldn't convert and records the key problem for Settings and /health.
    @Test
    func convergenceWithoutKeyReportsEveryStoreAndRecordsHealth() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
                try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: nil, body: "plain")
                try seedDB(at: OsaurusPaths.methodsDatabaseFile().path, key: key(seed: 0x34), body: "old")
                keychain.writeStatus = errSecAuthFailed

                let report = await StorageMigrationCoordinator.shared.converge(to: .encrypted)

                #expect(report.keyFailure != nil)
                #expect(report.locked.contains("memory"))
                #expect(report.isFullyConverged == false)
                #expect(
                    PersistenceHealth.shared.storeIssue(for: StorageMigrationCoordinator.storageKeyIssueStore) != nil
                )
            }
        }
    }

    // MARK: - Policy-aware files

    @Test
    func convergenceCarriesSyncLocalStateAndSkipsTheRawLedger() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
                let dir = OsaurusPaths.syncLocalState()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let state = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
                let ledger = dir.appendingPathComponent("legacy-import.json")
                try Data(#"{"steps":1}"#.utf8).write(to: state)
                try Data(#"{"done":true,"imported":[]}"#.utf8).write(to: ledger)

                let report = try await StorageMigrationCoordinator.shared.setEncryptionEnabled(true)
                #expect(report.filesConverted == 1)
                #expect(report.filesFailed == 0)

                let k = try #require(storedKey(keychain))
                #expect(FileManager.default.fileExists(atPath: state.path) == false)
                let wrapped = EncryptedFileStore.encryptedURL(for: state)
                #expect(try EncryptedFileStore.read(wrapped, key: k) == Data(#"{"steps":1}"#.utf8))
                #expect(FileManager.default.fileExists(atPath: ledger.path))
                #expect(FileManager.default.fileExists(atPath: EncryptedFileStore.encryptedURL(for: ledger).path) == false)

                // And back again.
                let back = try await StorageMigrationCoordinator.shared.setEncryptionEnabled(false)
                #expect(back.filesConverted == 1)
                #expect(try Data(contentsOf: state) == Data(#"{"steps":1}"#.utf8))
                #expect(FileManager.default.fileExists(atPath: wrapped.path) == false)
            }
        }
    }

    /// A newer twin already written under the new posture wins over the stale
    /// one convergence finds.
    @Test
    func convergenceKeepsTheNewerTwin() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFreshInstall { _, keychain in
                let k = key(seed: 0x35)
                StorageKeyManager.shared._setKeyForTesting(k)
                let dir = OsaurusPaths.syncLocalState()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let state = dir.appendingPathComponent("host-runs.json")
                try Data("stale".utf8).write(to: state)
                try EncryptedFileStore.write(Data("newer".utf8), to: EncryptedFileStore.encryptedURL(for: state), key: k)

                let files = StorageMigrationCoordinator.convergeFiles(to: .encrypted, key: k)
                #expect(files.converted == 1)
                #expect(FileManager.default.fileExists(atPath: state.path) == false)
                #expect(try EncryptedFileStore.read(EncryptedFileStore.encryptedURL(for: state), key: k) == Data("newer".utf8))
            }
        }
    }
}
