//
//  StorageExportService.swift
//  osaurus
//
//  Plaintext export + key rotation admin operations for at-rest
//  encrypted storage. Two flows:
//
//   1. `exportPlaintextBackup(to:)` — read every encrypted artifact
//      under `~/.osaurus/`, decrypt, and write a self-contained
//      directory tree the user can `zip` or hand to a forensic tool.
//      Useful before reinstalling macOS or migrating to a new Mac
//      without iCloud Keychain. Result is **plaintext** — caller
//      must protect the destination.
//
//   2. `rotateStorageKey()` — generate a fresh data-encryption key
//      and re-key SQLCipher + re-wrap every `.osec` file. Called
//      from Settings ("Reset storage encryption key") or after a
//      suspected compromise.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import os

public enum StorageExportError: LocalizedError {
    case keyUnavailable
    case writeFailed(String)
    case rekeyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "Storage encryption key is unavailable"
        case .writeFailed(let m): return "Backup write failed: \(m)"
        case .rekeyFailed(let m): return "Key rotation failed: \(m)"
        }
    }
}

public actor StorageExportService {
    public static let shared = StorageExportService()

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.export")

    private init() {}

    // MARK: - Plaintext backup

    public struct ExportSummary: Sendable {
        public var databasesExported: Int
        public var jsonFilesDecrypted: Int
        public var blobsDecrypted: Int
        public var destination: URL
    }

    /// Walk every encrypted artifact under `~/.osaurus/`, decrypt
    /// in-place, and write the cleartext copies under `destination`.
    /// `destination` must be writable and ideally on an
    /// already-encrypted volume (FileVault).
    public func exportPlaintextBackup(to destination: URL) async throws -> ExportSummary {
        let key: SymmetricKey
        do {
            key = try StorageKeyManager.shared.currentKey()
        } catch {
            throw StorageExportError.keyUnavailable
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw StorageExportError.writeFailed(error.localizedDescription)
        }

        var summary = ExportSummary(
            databasesExported: 0,
            jsonFilesDecrypted: 0,
            blobsDecrypted: 0,
            destination: destination
        )

        // 1. Databases — export via SQLCipher's sqlcipher_export to
        //    a plaintext sibling.
        for target in StorageMigrator.databaseTargets() {
            let result = exportOneDatabase(target: target, key: key, to: destination)
            switch result {
            case .success: summary.databasesExported += 1
            case .failure(let err):
                log.error("export: skipped \(target.label): \(err.localizedDescription)")
            }
        }

        // 2. JSON files — decrypt every `.osec` under known dirs.
        let osecRoots = [
            OsaurusPaths.agents(),
            OsaurusPaths.themes(),
            OsaurusPaths.schedules(),
            OsaurusPaths.watchers(),
            OsaurusPaths.providers(),
            OsaurusPaths.config(),
            OsaurusPaths.sessionsArchive(),
            OsaurusPaths.sandboxPluginLibrary(),
            OsaurusPaths.toolSpecs(),
        ]
        for root in osecRoots {
            summary.jsonFilesDecrypted += decryptOSecTree(under: root, key: key, into: destination)
        }

        // 3. Blobs — decrypt content-addressed attachments.
        let blobsDir = AttachmentBlobStore.blobsDir()
        if fm.fileExists(atPath: blobsDir.path) {
            summary.blobsDecrypted = decryptBlobsDir(blobsDir, key: key, into: destination)
        }

        // 4. Metadata stamp so the user knows what they have.
        let stamp = """
            Osaurus plaintext backup
            Generated: \(ISO8601DateFormatter().string(from: Date()))
            Storage key version: 1

            This directory is the cleartext copy of the encrypted
            artifacts under ~/.osaurus. The data here is NOT
            encrypted — protect it like a password store.
            """
        try? stamp.data(using: .utf8)?.write(to: destination.appendingPathComponent("README.txt"))

        return summary
    }

    // MARK: - Key rotation

    /// Generate a brand-new data-encryption key, re-key every
    /// SQLCipher database (via `PRAGMA rekey`), and re-wrap every
    /// `.osec` file under `~/.osaurus/`. This is destructive in the
    /// sense that any backup made with the previous key becomes
    /// unreadable on this Mac (the old key is overwritten in
    /// Keychain). Use with care.
    ///
    /// Sequencing:
    ///   1. Snapshot the current key.
    ///   2. Generate a new 256-bit key (NOT yet installed).
    ///   3. Quiesce every registered DB handle (close their SQLite
    ///      connections) so SQLCipher gets exclusive access for the
    ///      `PRAGMA rekey` step.
    ///   4. Rekey every SQLCipher DB.
    ///   5. Re-wrap every `.osec` file under `~/.osaurus/`.
    ///   6. Install the new key in the Keychain (atomic with cache).
    ///   7. Reopen the DB handles. The app keeps working seamlessly
    ///      because `OsaurusDatabaseHandle.withAllHandlesQuiesced`
    ///      restores them on the way out.
    ///
    /// If any step before (6) fails we roll back: handles are
    /// reopened with the old key (still in Keychain), the new key
    /// is discarded.
    @discardableResult
    public func rotateStorageKey() async throws -> SymmetricKey {
        // Block every other DB-open path while we mutate. Anything
        // that hits `StorageMigrationCoordinator.awaitReady()` (sync
        // or async) parks until we call `endMutating()` below.
        //
        // We can't use `defer { Task { @MainActor in endMutating() } }`
        // here because `defer { Task { ... } }` would let
        // `rotateStorageKey()` return before `endMutating()` actually
        // runs, leaving callers parked on `awaitReady()` for an extra
        // hop. Use a do/catch with explicit `await endMutating` on
        // every exit instead.
        await MainActor.run { StorageMigrationCoordinator.shared.beginMutating() }

        let result: Result<SymmetricKey, Error>
        do {
            let key = try await performRotation()
            result = .success(key)
        } catch {
            result = .failure(error)
        }

        await MainActor.run { StorageMigrationCoordinator.shared.endMutating() }

        switch result {
        case .success(let key): return key
        case .failure(let error): throw error
        }
    }

    /// Body of `rotateStorageKey` extracted so the gate
    /// `begin/endMutating` lifecycle is auditably linear.
    private func performRotation() async throws -> SymmetricKey {
        let oldKey: SymmetricKey
        do {
            oldKey = try StorageKeyManager.shared.currentKey()
        } catch {
            throw StorageExportError.keyUnavailable
        }

        var newRaw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &newRaw) == errSecSuccess else {
            throw StorageExportError.rekeyFailed("CSPRNG failed")
        }
        let newKey = SymmetricKey(data: Data(newRaw))
        for i in newRaw.indices { newRaw[i] = 0 }

        // Quiesce the open SQLCipher handles before rekeying so they
        // don't fight us for exclusive access. They're reopened on
        // the way out (with the new key, which we install before
        // the reopen).
        try OsaurusDatabaseHandle.withAllHandlesQuiesced {
            for target in StorageMigrator.databaseTargets() {
                do {
                    try rekeyDatabase(path: target.path, oldKey: oldKey, newKey: newKey)
                    log.info("storage rekey: \(target.label) done")
                } catch {
                    log.error("storage rekey: \(target.label) FAILED: \(error.localizedDescription)")
                    throw StorageExportError.rekeyFailed("\(target.label): \(error.localizedDescription)")
                }
            }
            rewrapOSecTree(under: OsaurusPaths.root(), oldKey: oldKey, newKey: newKey)

            // Install the new key BEFORE the quiesced handles get
            // reopened — otherwise the reopen path would try the old
            // key against the now-rekeyed files and fail.
            do {
                try StorageKeyManager.shared.install(key: newKey)
            } catch {
                throw StorageExportError.rekeyFailed("Keychain install failed: \(error.localizedDescription)")
            }
        }
        return newKey
    }

    // MARK: - Orphan cleanup

    public struct OrphanedPluginCleanupSummary: Sendable {
        public var directoriesRemoved: Int
        public var removedPluginIds: [String]
    }

    /// Walk `~/.osaurus/Tools/` and remove the data dir for any
    /// plugin whose `data.db` cannot be opened with the current
    /// storage key. Used by the Storage settings panel "Clean up
    /// orphaned plugin data" action when the migrator's
    /// `detectKeyMismatch()` reports plugin-only failures (the
    /// "real" failure case we need to surface for users — a plugin
    /// was uninstalled or its DB drifted out of sync with the
    /// current key).
    ///
    /// Safe by construction:
    ///   - Skips databases that decrypt successfully (those are
    ///     real, in-use plugin data — never deleted).
    ///   - Skips plugin IDs that are NOT already on the migrator's
    ///     key-mismatch list, so we never remove a directory the
    ///     caller didn't already authorize via the UI.
    ///   - Removes the **whole plugin directory** for each
    ///     orphan, not just the `data.db`. Otherwise we'd leave
    ///     `Tools/<pluginId>/` empty and the migrator would
    ///     re-discover it on next launch as a zero-DB target
    ///     (harmless, but pollution).
    public func cleanupOrphanedPluginDatabases(
        targets: [StorageMigrator.DatabaseTarget]
    ) async -> OrphanedPluginCleanupSummary {
        let fm = FileManager.default
        var removed: [String] = []

        for target in targets {
            // Only touch plugin targets. Core DBs return `nil` from
            // `pluginId` so this guard alone keeps them safe even if
            // a future caller mis-builds the mismatch list.
            guard let pluginId = target.pluginId else { continue }
            let pluginDir = OsaurusPaths.pluginDirectory(for: pluginId)
            guard fm.fileExists(atPath: pluginDir.path) else { continue }
            do {
                try fm.removeItem(at: pluginDir)
                removed.append(pluginId)
                log.notice("orphan cleanup: removed plugin dir \(pluginId)")
            } catch {
                log.error(
                    "orphan cleanup: failed to remove \(pluginId): \(error.localizedDescription)"
                )
            }
        }

        return OrphanedPluginCleanupSummary(
            directoriesRemoved: removed.count,
            removedPluginIds: removed
        )
    }

    // MARK: - Internals: per-DB

    private func exportOneDatabase(
        target: StorageMigrator.DatabaseTarget,
        key: SymmetricKey,
        to destination: URL
    ) -> Result<Void, Error> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return .success(()) }

        let outPath =
            destination
            .appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: target.path).lastPathComponent + ".plaintext")
        do {
            try fm.createDirectory(at: outPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        try? fm.removeItem(at: outPath)

        var srcDB: OpaquePointer?
        guard sqlite3_open(target.path, &srcDB) == SQLITE_OK, let src = srcDB else {
            return .failure(StorageExportError.writeFailed("open \(target.path)"))
        }
        defer { sqlite3_close(src) }

        let keyHex = key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        let keySQL = "PRAGMA key = \"x'\(keyHex)'\""
        if sqlite3_exec(src, keySQL, nil, nil, nil) != SQLITE_OK {
            return .failure(StorageExportError.writeFailed("PRAGMA key"))
        }
        for pragma in [
            "PRAGMA cipher_memory_security = OFF",
            "PRAGMA cipher_page_size = 4096",
            "PRAGMA kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(src, pragma, nil, nil, nil)
        }

        let attach =
            "ATTACH DATABASE '\(outPath.path.replacingOccurrences(of: "'", with: "''"))' AS plaintext KEY ''"
        if sqlite3_exec(src, attach, nil, nil, nil) != SQLITE_OK {
            return .failure(StorageExportError.writeFailed("attach plaintext"))
        }
        defer { _ = sqlite3_exec(src, "DETACH DATABASE plaintext", nil, nil, nil) }

        if sqlite3_exec(src, "SELECT sqlcipher_export('plaintext')", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(src))
            return .failure(StorageExportError.writeFailed("export: \(msg)"))
        }
        return .success(())
    }

    private func rekeyDatabase(path: String, oldKey: SymmetricKey, newKey: SymmetricKey) throws {
        var dbPointer: OpaquePointer?
        guard sqlite3_open(path, &dbPointer) == SQLITE_OK, let conn = dbPointer else {
            throw StorageExportError.rekeyFailed("open \(path)")
        }
        defer { sqlite3_close(conn) }

        // Apply old key first to unlock the DB.
        let oldHex = oldKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        if sqlite3_exec(conn, "PRAGMA key = \"x'\(oldHex)'\"", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("PRAGMA key")
        }
        for pragma in [
            "PRAGMA cipher_memory_security = OFF",
            "PRAGMA cipher_page_size = 4096",
            "PRAGMA kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(conn, pragma, nil, nil, nil)
        }
        // Force a read so we know the old key was correct.
        if sqlite3_exec(conn, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("verify old key")
        }

        // Now rekey to the new value.
        let newHex = newKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        if sqlite3_exec(conn, "PRAGMA rekey = \"x'\(newHex)'\"", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("PRAGMA rekey")
        }
    }

    // MARK: - Internals: file trees

    private func decryptOSecTree(under url: URL, key: SymmetricKey, into destination: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var count = 0
        for case let f as URL in enumerator {
            guard f.pathExtension == "osec" else { continue }
            let plaintext: Data
            do { plaintext = try EncryptedFileStore.read(f, key: key) } catch { continue }
            let plain = EncryptedFileStore.plaintextURL(for: f)
            let relPath = relativePath(from: OsaurusPaths.root(), to: plain) ?? plain.lastPathComponent
            let dest = destination.appendingPathComponent("config", isDirectory: true).appendingPathComponent(relPath)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plaintext.write(to: dest, options: [.atomic])
            count += 1
        }
        return count
    }

    private func decryptBlobsDir(_ url: URL, key: SymmetricKey, into destination: URL) -> Int {
        let fm = FileManager.default
        let outDir = destination.appendingPathComponent("blobs", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var count = 0
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "osec" {
            guard let plaintext = try? EncryptedFileStore.read(entry, key: key) else { continue }
            let dest = outDir.appendingPathComponent(entry.deletingPathExtension().lastPathComponent)
            try? plaintext.write(to: dest, options: [.atomic])
            count += 1
        }
        return count
    }

    private func rewrapOSecTree(under url: URL, oldKey: SymmetricKey, newKey: SymmetricKey) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in enumerator where f.pathExtension == "osec" {
            guard let plaintext = try? EncryptedFileStore.read(f, key: oldKey) else { continue }
            try? EncryptedFileStore.write(plaintext, to: f, key: newKey)
        }
    }

    private func relativePath(from base: URL, to target: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(basePath) else { return nil }
        var rel = String(targetPath.dropFirst(basePath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}
