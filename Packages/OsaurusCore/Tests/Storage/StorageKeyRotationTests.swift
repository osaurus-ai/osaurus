//
//  StorageKeyRotationTests.swift
//  osaurusTests
//
//  Key rotation against the real key resolution path, with
//  `StorageKeyManager.keychainForTesting` standing in for the login Keychain.
//
//  - Rotation moves every encrypted database and `.osec` file to the new
//    key and leaves plaintext stores alone instead of failing on them.
//  - A failure part-way through puts everything back under the old key.
//  - A rotation cut off by a crash leaves a pending key behind, and the next
//    launch moves the stragglers back to the current key.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageKeyRotationTests {

    // MARK: - Helpers

    private func key(seed: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    private func bytes(_ key: SymmetricKey?) -> Data? {
        key?.withUnsafeBytes { Data($0) }
    }

    private func seedDB(at path: String, key k: SymmetricKey?) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
        defer { sqlite3_close(conn) }
        guard sqlite3_exec(conn, "CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('kept')", nil, nil, nil)
            == SQLITE_OK
        else { throw StorageExportError.writeFailed("seed \(path)") }
    }

    /// True when `path` opens under `key` and its seeded row reads back.
    private func opens(_ path: String, with k: SymmetricKey) -> Bool {
        guard let conn = try? EncryptedSQLiteOpener.open(path: path, key: k) else { return false }
        defer { sqlite3_close(conn) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, "SELECT body FROM notes", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: text) == "kept"
    }

    private func attachment() -> URL {
        AttachmentBlobStore.blobsDir().appendingPathComponent("rotation-probe.osec")
    }

    /// Fresh root, encryption on, and `oldKey` installed in an empty test
    /// Keychain. Call under `StoragePathsTestLock`.
    private func withEncryptedInstall(
        _ body: (StorageKeyTestKeychain, SymmetricKey) async throws -> Void
    ) async throws {
        let previousRoot = OsaurusPaths.overrideRoot
        let previousKey =
            StorageKeyManager.shared.hasCachedKey ? try StorageKeyManager.shared.currentKey() : nil
        let handles = OsaurusDatabaseHandle.allOpenHandles
        for handle in handles { handle.closer() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-rotation-tests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = StorageKeyTestKeychain()
        OsaurusPaths.overrideRoot = root
        StorageKeyManager.keychainForTesting = keychain
        StorageEncryptionPolicy.shared.invalidateCache()
        StorageKeyManager.shared.wipeCache()
        defer {
            StorageExportService.faultForTesting = nil
            StorageKeyManager.keychainForTesting = nil
            OsaurusPaths.overrideRoot = previousRoot
            StorageEncryptionPolicy.shared.invalidateCache()
            StorageKeyManager.shared.wipeCache()
            if let previousKey { StorageKeyManager.shared._setKeyForTesting(previousKey) }
            for handle in handles { handle.reopener() }
            try? FileManager.default.removeItem(at: root)
        }
        try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
        let oldKey = key(seed: 0xA1)
        try StorageKeyManager.shared.install(key: oldKey)
        try await body(keychain, oldKey)
    }

    // MARK: - Rotation

    @Test
    func rotationMovesEncryptedArtifactsAndSkipsPlaintextStores() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, oldKey in
                let memory = OsaurusPaths.memoryDatabaseFile().path
                let knowledge = OsaurusPaths.knowledgeDatabaseFile().path
                let tasks = OsaurusPaths.tasksDatabaseFile().path
                try seedDB(at: memory, key: oldKey)
                try seedDB(at: knowledge, key: oldKey)
                try seedDB(at: tasks, key: nil)
                try EncryptedFileStore.write(Data("blob".utf8), to: attachment(), key: oldKey)

                let newKey = try await StorageExportService.shared.rotateStorageKey()

                #expect(bytes(newKey) != bytes(oldKey))
                #expect(opens(memory, with: newKey))
                #expect(opens(knowledge, with: newKey))
                #expect(!opens(memory, with: oldKey))
                #expect(StorageFileFormat.detect(path: tasks) == .plaintext)
                #expect(try EncryptedFileStore.read(attachment(), key: newKey) == Data("blob".utf8))
                #expect(keychain.value(StorageKeyManager.keyAccount) == bytes(newKey))
                #expect(!keychain.contains(StorageKeyManager.pendingKeyAccount))
            }
        }
    }

    @Test
    func failedRotationPutsEverythingBackUnderTheOldKey() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, oldKey in
                let memory = OsaurusPaths.memoryDatabaseFile().path
                let methods = OsaurusPaths.methodsDatabaseFile().path
                try seedDB(at: memory, key: oldKey)
                try seedDB(at: methods, key: oldKey)
                try EncryptedFileStore.write(Data("blob".utf8), to: attachment(), key: oldKey)
                StorageExportService.faultForTesting = .fail(afterDatabases: 1)

                await #expect(throws: StorageExportError.self) {
                    try await StorageExportService.shared.rotateStorageKey()
                }

                #expect(opens(memory, with: oldKey))
                #expect(opens(methods, with: oldKey))
                #expect(try EncryptedFileStore.read(attachment(), key: oldKey) == Data("blob".utf8))
                #expect(keychain.value(StorageKeyManager.keyAccount) == bytes(oldKey))
                #expect(!keychain.contains(StorageKeyManager.pendingKeyAccount))
                #expect(bytes(try StorageKeyManager.shared.currentKey()) == bytes(oldKey))
            }
        }
    }

    // MARK: - Interrupted rotation

    @Test
    func rotationCutOffMidwayIsRecoveredOnNextLaunch() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, oldKey in
                let memory = OsaurusPaths.memoryDatabaseFile().path
                let methods = OsaurusPaths.methodsDatabaseFile().path
                try seedDB(at: memory, key: oldKey)
                try seedDB(at: methods, key: oldKey)
                StorageExportService.faultForTesting = .crash(afterDatabases: 1)

                await #expect(throws: StorageExportService.RotationCrashForTesting.self) {
                    try await StorageExportService.shared.rotateStorageKey()
                }
                let pending = try #require(keychain.value(StorageKeyManager.pendingKeyAccount))
                let pendingKey = SymmetricKey(data: pending)
                let movedCount = [memory, methods].filter { opens($0, with: pendingKey) }.count
                #expect(movedCount == 1)
                #expect(StorageKeyManager.shared.rotationMayBeInterrupted)

                StorageExportService.faultForTesting = nil
                StorageKeyManager.shared.wipeCache()
                await StorageMigrationCoordinator.recoverInterruptedRotation()

                #expect(opens(memory, with: oldKey))
                #expect(opens(methods, with: oldKey))
                #expect(!keychain.contains(StorageKeyManager.pendingKeyAccount))
                #expect(!StorageKeyManager.shared.rotationMayBeInterrupted)
            }
        }
    }

    @Test
    func recoveryRewrapsFilesLeftUnderThePendingKey() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, oldKey in
                let pendingKey = key(seed: 0xB2)
                try StorageKeyManager.shared.stagePendingRotationKey(pendingKey)
                try EncryptedFileStore.write(Data("blob".utf8), to: attachment(), key: pendingKey)

                await StorageMigrationCoordinator.recoverInterruptedRotation()

                #expect(try EncryptedFileStore.read(attachment(), key: oldKey) == Data("blob".utf8))
                #expect(!keychain.contains(StorageKeyManager.pendingKeyAccount))
            }
        }
    }

    /// Launch only consults the Keychain for a pending key when the on-disk
    /// rotation marker says a rotation was staged, so plaintext installs
    /// never read it at startup.
    @Test
    func recoveryWithoutTheRotationMarkerLeavesTheKeychainAlone() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, _ in
                let pendingKey = key(seed: 0xC3)
                try keychain.write(bytes(pendingKey)!, account: StorageKeyManager.pendingKeyAccount)
                try EncryptedFileStore.write(Data("blob".utf8), to: attachment(), key: pendingKey)
                #expect(!StorageKeyManager.shared.rotationMayBeInterrupted)

                await StorageMigrationCoordinator.recoverInterruptedRotation()

                #expect(try EncryptedFileStore.read(attachment(), key: pendingKey) == Data("blob".utf8))
                #expect(keychain.contains(StorageKeyManager.pendingKeyAccount))
            }
        }
    }

    @Test
    func recoveryIsANoOpWithoutAPendingKey() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withEncryptedInstall { keychain, oldKey in
                let memory = OsaurusPaths.memoryDatabaseFile().path
                try seedDB(at: memory, key: oldKey)

                await StorageMigrationCoordinator.recoverInterruptedRotation()

                #expect(opens(memory, with: oldKey))
                #expect(keychain.value(StorageKeyManager.keyAccount) == bytes(oldKey))
            }
        }
    }
}
