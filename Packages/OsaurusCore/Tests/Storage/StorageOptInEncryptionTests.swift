//
//  StorageOptInEncryptionTests.swift
//  osaurusTests
//
//  Covers the opt-in at-rest encryption walk-back:
//
//  - `StorageFileFormat.detect` classifies empty / plaintext / encrypted
//    from the on-disk header.
//  - `OsaurusStorageOpener.resolveKey` is detection-first: a plaintext file
//    never resolves a key (and never calls `currentKey()`), even when the
//    desired policy is `.encrypted` — so a stale flag or missing Keychain key
//    can't brick a plaintext store.
//  - `StorageFormatConverter` round-trips plaintext <-> encrypted in place and
//    drops stale `-wal`/`-shm` sidecars.
//  - `StorageFile` sidecar cleanup + quarantine (move, never delete).
//  - `StorageMigrationCoordinator.detectOnDiskPosture` + `needsConversion`.
//  - `StorageMigrationCoordinator.resolveLaunchMode` is FileVault-aware:
//    existing encrypted installs decrypt only when FileVault is on, are kept
//    encrypted when it's off, and an explicit marker is always honored.
//  - `StorageEncryptionPolicy.persistedMode` is nil with no marker.
//  - The 0.21.0 storage opt-in notice was removed (invisible migration).
//  - `StorageOpenIssueKind.classify` maps real errors to recovery categories.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageOptInEncryptionTests {

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-optin-tests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempDBPath(_ name: String = "db.sqlite") -> String {
        tempDir().appendingPathComponent(name).path
    }

    private func key(seed: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    private func rawBytes(_ k: SymmetricKey) -> Data {
        k.withUnsafeBytes { Data($0) }
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

    /// Seed a SQLite DB at `path` (plaintext when `key` is nil) holding a
    /// single `notes(body)` row with `body`.
    private func seedDB(at path: String, key k: SymmetricKey?, body: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
        try execute(conn, "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")
        try execute(conn, "INSERT INTO notes (body) VALUES ('\(body)')")
        sqlite3_close(conn)
    }

    // MARK: - Detection

    @Test
    func detectMissingFileIsEmpty() {
        let path = tempDir().appendingPathComponent("does-not-exist.sqlite").path
        #expect(StorageFileFormat.detect(path: path) == .empty)
    }

    @Test
    func detectZeroLengthFileIsEmpty() throws {
        let path = tempDBPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(StorageFileFormat.detect(path: path) == .empty)
    }

    @Test
    func detectDirectoryIsEmpty() {
        let dir = tempDir()
        #expect(StorageFileFormat.detect(path: dir.path) == .empty)
    }

    @Test
    func detectPlaintextSQLite() throws {
        let path = tempDBPath()
        try seedDB(at: path, key: nil, body: "plain")
        #expect(StorageFileFormat.detect(path: path) == .plaintext)
        #expect(StorageFileFormat.isEncrypted(path: path) == false)
    }

    @Test
    func detectEncryptedSQLCipher() throws {
        let path = tempDBPath()
        try seedDB(at: path, key: key(seed: 0x10), body: "secret")
        #expect(StorageFileFormat.detect(path: path) == .encrypted)
        #expect(StorageFileFormat.isEncrypted(path: path) == true)
    }

    // MARK: - Detection-first opener (the brick-proof guarantee)

    @Test
    func resolveKeyForPlaintextNeverTouchesKeychain() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            // Worst case for the old bug: the user opted in to encryption, but
            // the file on disk is plaintext. Detection must win — no key.
            try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
            StorageKeyManager.shared.wipeCache()

            let path = tempDBPath()
            try seedDB(at: path, key: nil, body: "plain")

            let resolved = try OsaurusStorageOpener.resolveKey(for: path)
            #expect(resolved == nil)
            // If `currentKey()` had been called it would have cached a key (or
            // thrown). Neither happened: the plaintext branch returned first.
            #expect(StorageKeyManager.shared.hasCachedKey == false)
        }
    }

    @Test
    func resolveKeyForEncryptedFileReturnsKey() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            let k = key(seed: 0x20)
            StorageKeyManager.shared._setKeyForTesting(k)

            let path = tempDBPath()
            try seedDB(at: path, key: k, body: "secret")

            let resolved = try OsaurusStorageOpener.resolveKey(for: path)
            #expect(resolved != nil)
            #expect(resolved.map(rawBytes) == rawBytes(k))
        }
    }

    @Test
    func resolveKeyForEmptyFollowsPolicy() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            let missing = tempDBPath("missing.sqlite")

            // Plaintext policy -> no key for a brand-new file.
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()
            #expect(try OsaurusStorageOpener.resolveKey(for: missing) == nil)
            #expect(StorageKeyManager.shared.hasCachedKey == false)

            // Encrypted policy -> the DEK is required for a brand-new file.
            try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
            let k = key(seed: 0x21)
            StorageKeyManager.shared._setKeyForTesting(k)
            #expect(try OsaurusStorageOpener.resolveKey(for: missing).map(rawBytes) == rawBytes(k))
        }
    }

    // MARK: - Converter round-trip

    @Test
    func converterRoundTripPlaintextEncryptedPlaintext() throws {
        let path = tempDBPath()
        let k = key(seed: 0x42)
        try seedDB(at: path, key: nil, body: "round-trip")
        #expect(StorageFileFormat.detect(path: path) == .plaintext)

        // plaintext -> encrypted
        try StorageFormatConverter.encryptInPlace(path: path, key: k)
        #expect(StorageFileFormat.detect(path: path) == .encrypted)
        let enc = try EncryptedSQLiteOpener.open(path: path, key: k)
        #expect(readSingleText(enc, "SELECT body FROM notes LIMIT 1") == "round-trip")
        sqlite3_close(enc)

        // encrypted -> plaintext
        try StorageFormatConverter.decryptInPlace(path: path, key: k)
        #expect(StorageFileFormat.detect(path: path) == .plaintext)
        let plain = try EncryptedSQLiteOpener.open(path: path, key: nil)
        #expect(readSingleText(plain, "SELECT body FROM notes LIMIT 1") == "round-trip")
        sqlite3_close(plain)
    }

    @Test
    func converterIsNoOpWhenAlreadyInTargetFormat() throws {
        let path = tempDBPath()
        try seedDB(at: path, key: nil, body: "noop")
        // Decrypting a plaintext file is a no-op (no key needed despite arg).
        try StorageFormatConverter.decryptInPlace(path: path, key: key(seed: 0x01))
        #expect(StorageFileFormat.detect(path: path) == .plaintext)
    }

    @Test
    func converterDropsStaleSidecarsAfterSwap() throws {
        let path = tempDBPath()
        let k = key(seed: 0x55)
        try seedDB(at: path, key: nil, body: "wal")
        // Simulate leftover WAL/SHM from the previous (plaintext) file.
        FileManager.default.createFile(atPath: path + "-wal", contents: Data([0x1]))
        FileManager.default.createFile(atPath: path + "-shm", contents: Data([0x2]))

        try StorageFormatConverter.encryptInPlace(path: path, key: k)
        #expect(StorageFileFormat.detect(path: path) == .encrypted)
        #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: path + "-shm") == false)
    }

    // MARK: - StorageFile sidecars + quarantine

    @Test
    func storageFileRemovesSidecars() throws {
        let path = tempDBPath()
        FileManager.default.createFile(atPath: path, contents: Data([0x0]))
        FileManager.default.createFile(atPath: path + "-wal", contents: Data([0x1]))
        FileManager.default.createFile(atPath: path + "-shm", contents: Data([0x2]))

        StorageFile.removeSidecars(for: path)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: path + "-shm") == false)

        StorageFile.remove(path: path)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test
    func quarantineMovesFileAndSidecarsNeverDeletes() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer { OsaurusPaths.overrideRoot = nil }

            let path = root.appendingPathComponent("memory.sqlite").path
            FileManager.default.createFile(atPath: path, contents: Data([0xAB]))
            FileManager.default.createFile(atPath: path + "-wal", contents: Data([0x1]))

            let dest = StorageFile.quarantine(path: path, reason: "test")
            #expect(dest != nil)
            // Original moved out...
            #expect(FileManager.default.fileExists(atPath: path) == false)
            #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
            // ...into the quarantine directory (never deleted).
            if let dest {
                #expect(FileManager.default.fileExists(atPath: dest.path))
                #expect(dest.path.hasPrefix(StorageFile.quarantineDirectory().path))
            }
        }
    }

    // MARK: - Posture detection + needsConversion

    @Test
    func detectOnDiskPostureReflectsRealFiles() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }

            // Nothing on disk yet.
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .empty)

            // One plaintext core DB -> plaintext.
            try seedDB(at: OsaurusPaths.chatHistoryDatabaseFile().path, key: nil, body: "c")
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .plaintext)

            // Add an encrypted core DB -> mixed.
            try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: key(seed: 0x30), body: "m")
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .mixed)
        }
    }

    @Test
    func needsConversionMatchesDesiredMode() throws {
        let plain = tempDBPath("p.sqlite")
        try seedDB(at: plain, key: nil, body: "p")
        let enc = tempDBPath("e.sqlite")
        try seedDB(at: enc, key: key(seed: 0x31), body: "e")
        let missing = tempDBPath("missing.sqlite")

        // Plaintext file only needs conversion when encryption is desired.
        #expect(StorageMigrationCoordinator.needsConversion(path: plain, to: .plaintext) == false)
        #expect(StorageMigrationCoordinator.needsConversion(path: plain, to: .encrypted) == true)
        // Encrypted file only needs conversion when plaintext is desired.
        #expect(StorageMigrationCoordinator.needsConversion(path: enc, to: .encrypted) == false)
        #expect(StorageMigrationCoordinator.needsConversion(path: enc, to: .plaintext) == true)
        // Empty/missing files are created in the desired mode on first open.
        #expect(StorageMigrationCoordinator.needsConversion(path: missing, to: .encrypted) == false)
        #expect(StorageMigrationCoordinator.needsConversion(path: missing, to: .plaintext) == false)
    }

    // MARK: - End-to-end convergence (launch path)

    /// The structural brick-proof guarantee at the coordinator level: a
    /// plaintext install has nothing to convert, so `converge(to: .plaintext)`
    /// returns *before* it ever asks `StorageKeyManager` for a key. A missing
    /// Keychain DEK therefore can't stall or brick a plaintext launch.
    @Test
    func convergeIsNoOpForPlaintextInstallAndNeverMintsKey() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)

            // A typical plaintext install: a couple of core DBs already plaintext.
            try seedDB(at: OsaurusPaths.chatHistoryDatabaseFile().path, key: nil, body: "c")
            try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: nil, body: "m")

            StorageKeyManager.shared.wipeCache()
            let report = await StorageMigrationCoordinator.shared.converge(to: .plaintext)

            #expect(report.converted == 0)
            #expect(report.locked.isEmpty)
            #expect(report.failed.isEmpty)
            // Nothing needed conversion, so `currentKey()` was never called and
            // no key was minted/cached for the plaintext install.
            #expect(StorageKeyManager.shared.hasCachedKey == false)
        }
    }

    /// Faithful migration proof across the *whole* core catalog: seed every
    /// core database encrypted, decrypt the lot in place (the launch
    /// walk-back), verify data survives and sidecars are gone, then opt back
    /// in and re-encrypt. Exercises the exact catalog enumeration +
    /// `StorageFormatConverter` calls the coordinator delegates to, without
    /// touching the global handle registry.
    @Test
    func convergeCatalogRoundTripAllCoreStores() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            let k = key(seed: 0x77)
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            StorageKeyManager.shared._setKeyForTesting(k)

            // Seed every core catalog DB encrypted, each with a distinct payload
            // so a mixed-up path/key would surface as a wrong/missing body.
            let targets = StorageDatabaseCatalog.databaseTargets()
            #expect(targets.count >= 6)
            for t in targets {
                try seedDB(at: t.path, key: k, body: "enc-\(t.label)")
                // Leftover sidecars from a prior plaintext life must not survive.
                FileManager.default.createFile(atPath: t.path + "-wal", contents: Data([0x1]))
                #expect(StorageFileFormat.detect(path: t.path) == .encrypted)
            }

            // encrypted -> plaintext (the default post-walk-back convergence).
            for t in targets {
                try StorageFormatConverter.decryptInPlace(path: t.path, key: k)
            }
            for t in targets {
                #expect(StorageFileFormat.detect(path: t.path) == .plaintext)
                let c = try EncryptedSQLiteOpener.open(path: t.path, key: nil)
                #expect(readSingleText(c, "SELECT body FROM notes LIMIT 1") == "enc-\(t.label)")
                sqlite3_close(c)
                #expect(FileManager.default.fileExists(atPath: t.path + "-wal") == false)
                #expect(FileManager.default.fileExists(atPath: t.path + "-shm") == false)
            }
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .plaintext)

            // Opt back in: plaintext -> encrypted, data still intact under the key.
            for t in targets {
                try StorageFormatConverter.encryptInPlace(path: t.path, key: k)
            }
            for t in targets {
                #expect(StorageFileFormat.detect(path: t.path) == .encrypted)
                let c = try EncryptedSQLiteOpener.open(path: t.path, key: k)
                #expect(readSingleText(c, "SELECT body FROM notes LIMIT 1") == "enc-\(t.label)")
                sqlite3_close(c)
            }
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .encrypted)
        }
    }

    // MARK: - FileVault-aware launch resolver

    /// Fresh / never-encrypted install resolves to plaintext and writes a
    /// sticky marker — even with FileVault off, since there's nothing
    /// encrypted to protect.
    @Test
    func resolveLaunchModeFreshInstallIsPlaintext() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            FileVaultStatus.overrideForTesting = false
            defer {
                OsaurusPaths.overrideRoot = nil
                FileVaultStatus.overrideForTesting = nil
                StorageEncryptionPolicy.shared.invalidateCache()
            }
            #expect(StorageEncryptionPolicy.shared.persistedMode() == nil)

            let mode = StorageMigrationCoordinator.resolveLaunchMode()
            #expect(mode == .plaintext)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .plaintext)
        }
    }

    /// Existing encrypted install + FileVault ON -> decrypt to plaintext: the
    /// disk is already encrypted at rest, so SQLCipher is redundant and the
    /// reliable plaintext posture is chosen (and persisted).
    @Test
    func resolveLaunchModeEncryptedWithFileVaultOnDecrypts() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            FileVaultStatus.overrideForTesting = true
            defer {
                OsaurusPaths.overrideRoot = nil
                FileVaultStatus.overrideForTesting = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: key(seed: 0x40), body: "m")
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .encrypted)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == nil)

            let mode = StorageMigrationCoordinator.resolveLaunchMode()
            #expect(mode == .plaintext)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .plaintext)
        }
    }

    /// Existing encrypted install + FileVault OFF -> keep encrypted: decrypting
    /// would silently strip the data's only at-rest protection, so the
    /// encrypted posture is kept and persisted instead.
    @Test
    func resolveLaunchModeEncryptedWithFileVaultOffKeepsEncrypted() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            FileVaultStatus.overrideForTesting = false
            defer {
                OsaurusPaths.overrideRoot = nil
                FileVaultStatus.overrideForTesting = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: key(seed: 0x41), body: "m")
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .encrypted)

            let mode = StorageMigrationCoordinator.resolveLaunchMode()
            #expect(mode == .encrypted)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .encrypted)
        }
    }

    /// A marker already on disk is authoritative: even with encrypted data and
    /// FileVault off (which would otherwise resolve to `.encrypted`), an
    /// explicit plaintext marker is honored verbatim — no silent re-migration.
    @Test
    func resolveLaunchModeHonorsExistingMarker() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            FileVaultStatus.overrideForTesting = false
            defer {
                OsaurusPaths.overrideRoot = nil
                FileVaultStatus.overrideForTesting = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            try seedDB(at: OsaurusPaths.memoryDatabaseFile().path, key: key(seed: 0x42), body: "m")
            #expect(StorageMigrationCoordinator.detectOnDiskPosture() == .encrypted)

            #expect(StorageMigrationCoordinator.resolveLaunchMode() == .plaintext)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .plaintext)
        }
    }

    // MARK: - Persisted marker peek

    /// `persistedMode()` is nil with no marker (so the launch resolver can tell
    /// a never-decided install apart from one that chose plaintext) and mirrors
    /// the value once set.
    @Test
    func persistedModeNilWhenNoMarkerThenReflectsSet() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
            }
            #expect(StorageEncryptionPolicy.shared.persistedMode() == nil)

            try StorageEncryptionPolicy.shared.setDesiredMode(.encrypted)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .encrypted)

            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            #expect(StorageEncryptionPolicy.shared.persistedMode() == .plaintext)
        }
    }

    // MARK: - Invisible migration (no What's New notice)

    /// The storage opt-in migration is fully invisible. 0.21.0 still ships its
    /// own What's New release (image generation + spawn), but nothing in any
    /// release announces the storage encryption opt-in: no page id references it
    /// and no page links to the storage settings or the plaintext export.
    @Test
    func whatsNewNoLongerListsStorageNotice() {
        let pages = WhatsNewContent.releases.flatMap(\.pages)
        #expect(pages.contains { $0.id.contains("storage-optin") } == false)
        #expect(
            pages.contains {
                $0.action == .openStorageSettings || $0.action == .exportPlaintextBackup
            } == false
        )
    }

    // MARK: - Issue classification (recovery categories)

    @Test
    func classifyMapsErrorsToRecoveryKinds() {
        #expect(
            StorageOpenIssueKind.classify(StorageKeyError.keyUnavailableForExistingData) == .locked
        )
        let corrupt = NSError(
            domain: "test",
            code: 26,
            userInfo: [NSLocalizedDescriptionKey: "file is not a database"]
        )
        #expect(StorageOpenIssueKind.classify(corrupt) == .corrupt)
        let migration = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "schema migration to v9 failed"]
        )
        #expect(StorageOpenIssueKind.classify(migration) == .migration)
        let unknown = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "???"]
        )
        #expect(StorageOpenIssueKind.classify(unknown) == .unknown)
    }
}
