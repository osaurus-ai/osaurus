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
        public var conversationsExported: Int = 0
        public var destination: URL
    }

    /// Walk every encrypted artifact under `~/.osaurus/`, decrypt
    /// in-place, and write the cleartext copies under `destination`.
    /// `destination` must be writable and ideally on an
    /// already-encrypted volume (FileVault).
    public func exportPlaintextBackup(to destination: URL) async throws -> ExportSummary {
        // Plaintext-by-default: a key may not exist at all. When it doesn't, we
        // simply copy the already-plaintext artifacts; only encrypted ones need
        // the key (and are skipped if it's gone rather than failing the whole
        // backup).
        let key = try? StorageKeyManager.shared.currentKey()

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
        for target in StorageDatabaseCatalog.databaseTargets() {
            let result = exportOneDatabase(target: target, key: key, to: destination)
            switch result {
            case .success: summary.databasesExported += 1
            case .failure(let err):
                log.error("export: skipped \(target.label): \(err.localizedDescription)")
            }
        }

        // 2. JSON files — decrypt every `.osec` under known dirs. Attachments
        //    are handled below.
        let blobsDir = AttachmentBlobStore.blobsDir()
        let osecRoots = StorageDatabaseCatalog.encryptedFileRoots().filter {
            $0.standardizedFileURL != blobsDir.standardizedFileURL
        }
        for root in osecRoots {
            summary.jsonFilesDecrypted += decryptOSecTree(under: root, key: key, into: destination)
        }

        // 3. Blobs — decrypt content-addressed attachments.
        if fm.fileExists(atPath: blobsDir.path) {
            summary.blobsDecrypted = decryptBlobsDir(blobsDir, key: key, into: destination)
        }

        // 4. Conversations — one directory per chat, from the sync store.
        if let core = SyncService.shared.core {
            let root = destination.appendingPathComponent("conversations", isDirectory: true)
            for conversation in (try? core.conversations()) ?? [] where conversation.kind == .conversation {
                let path = root.appendingPathComponent(conversation.scope, isDirectory: true).path
                do {
                    _ = try await core.exportConversation(scope: conversation.scope, path: path)
                    summary.conversationsExported += 1
                } catch {
                    log.error("export: skipped conversation: \(error.syncLogDetail, privacy: .public)")
                }
            }
        }

        // 5. Metadata stamp so the user knows what they have.
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
    ///   1. Snapshot the current key and generate a new one.
    ///   2. Stage the new key in the Keychain as the pending rotation
    ///      key, so a crash part-way through can still read every file.
    ///   3. Close every registered DB handle (and the plugin / agent
    ///      connections) so SQLCipher gets exclusive access.
    ///   4. Rekey every encrypted database and re-wrap every `.osec`
    ///      file the old key opens.
    ///   5. Install the new key, then drop the pending one.
    ///   6. End the mutation gate, then reopen the handles. Reopening
    ///      while the gate is held would park each reopen on the gate.
    ///
    /// If step 4 or 5 fails, everything already moved is put back under
    /// the old key. Anything left behind by a crash is moved back by
    /// `recoverInterruptedRotation()` on the next launch.
    @discardableResult
    public func rotateStorageKey() async throws -> SymmetricKey {
        // Key rotation only makes sense when at-rest encryption is enabled.
        // In the default plaintext posture there is no key to rotate.
        guard StorageEncryptionPolicy.shared.isEncryptionEnabled else {
            throw StorageExportError.rekeyFailed(
                "Key rotation is only available when at-rest encryption is enabled"
            )
        }
        // Block every other DB-open path while we mutate. Anything
        // that hits `StorageMutationGate.blockingAwaitNotMutating()`
        // (or the async `awaitNotMutating()`) parks until we call
        // `endMutating()` below.
        //
        // We can't use `defer { Task { @MainActor in endMutating() } }`
        // here because `defer { Task { ... } }` would let
        // `rotateStorageKey()` return before `endMutating()` actually
        // runs, leaving callers parked for an extra hop. Use a
        // do/catch with explicit `await endMutating` on every exit
        // instead.
        await MainActor.run { StorageMutationGate.shared.beginMutating() }
        let openHandles = OsaurusDatabaseHandle.allOpenHandles
        for handle in openHandles { handle.closer() }
        // Plugin and per-agent DBs aren't registered handles, so close
        // their live connections too. They reopen lazily.
        AgentDatabaseStore.shared.closeAll()
        PluginDatabase.closeAllOpen()

        let result = Result { try Self.performRotation() }

        await MainActor.run { StorageMutationGate.shared.endMutating() }
        for handle in openHandles { handle.reopener() }

        switch result {
        case .success(let key):
            // The SQLCipher `PRAGMA rekey` + OSec rewrap above cover the
            // encrypted databases and key-wrapped files, but NOT the
            // VecturaKit vector indexes under `memory/vectura/`. After a
            // rekey those are stale and a plaintext-at-rest gap, so discard
            // and rebuild them from the now-rekeyed SQLite source of truth.
            // Done after `endMutating()` so the rebuild's DB-open path isn't
            // parked on the mutation gate.
            await MemorySearchService.shared.resetAndRebuildAfterKeyRotation()
            return key
        case .failure(let error): throw error
        }
    }

    private static let rotationLog = Logger(subsystem: "ai.osaurus", category: "storage.export")

    /// Body of `rotateStorageKey`, run with every handle closed and the
    /// mutation gate held.
    private static func performRotation() throws -> SymmetricKey {
        let keyManager = StorageKeyManager.shared
        let oldKey: SymmetricKey
        do {
            oldKey = try keyManager.currentKey()
        } catch {
            throw StorageExportError.keyUnavailable
        }

        var newRaw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &newRaw) == errSecSuccess else {
            throw StorageExportError.rekeyFailed("CSPRNG failed")
        }
        let newKey = SymmetricKey(data: Data(newRaw))
        for i in newRaw.indices { newRaw[i] = 0 }

        do {
            try keyManager.stagePendingRotationKey(newKey)
        } catch {
            throw StorageExportError.rekeyFailed("Keychain staging failed: \(error.localizedDescription)")
        }

        var rekeyed: [StorageDatabaseCatalog.DatabaseTarget] = []
        var rewrapped: [URL] = []
        do {
            for target in StorageDatabaseCatalog.databaseTargets()
            where StorageFileFormat.detect(path: target.path) == .encrypted {
                try injectFaultForTesting(afterRekeying: rekeyed.count)
                do {
                    try rekeyDatabase(path: target.path, oldKey: oldKey, newKey: newKey)
                } catch {
                    throw StorageExportError.rekeyFailed("\(target.label): \(error.localizedDescription)")
                }
                rekeyed.append(target)
                rotationLog.info("storage rekey: \(target.label, privacy: .public) done")
            }
            try injectFaultForTesting(afterRekeying: rekeyed.count)
            try rewrapOSecTree(under: OsaurusPaths.root(), from: oldKey, to: newKey, rewrapped: &rewrapped)
            do {
                try keyManager.install(key: newKey)
            } catch {
                throw StorageExportError.rekeyFailed("Keychain install failed: \(error.localizedDescription)")
            }
        } catch {
            if case RotationCrashForTesting.crashed = error { throw error }
            rotationLog.error("storage rekey failed, rolling back: \(error.localizedDescription, privacy: .public)")
            if rollBack(rekeyed: rekeyed, rewrapped: rewrapped, oldKey: oldKey, newKey: newKey) {
                keyManager.clearPendingRotationKey()
            }
            throw error
        }
        keyManager.clearPendingRotationKey()
        return newKey
    }

    /// Put everything a failed rotation already moved back under `oldKey`.
    /// Returns false when something couldn't be moved back; the pending key
    /// is then kept so the next launch's recovery can finish the job.
    private static func rollBack(
        rekeyed: [StorageDatabaseCatalog.DatabaseTarget],
        rewrapped: [URL],
        oldKey: SymmetricKey,
        newKey: SymmetricKey
    ) -> Bool {
        var clean = true
        for target in rekeyed.reversed() {
            do {
                try rekeyDatabase(path: target.path, oldKey: newKey, newKey: oldKey)
            } catch {
                clean = false
                rotationLog.error(
                    "storage rekey rollback: \(target.label, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        for file in rewrapped {
            do {
                try EncryptedFileStore.write(EncryptedFileStore.read(file, key: newKey), to: file, key: oldKey)
            } catch {
                clean = false
                rotationLog.error(
                    "storage rewrap rollback: \(file.lastPathComponent, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return clean
    }

    /// Finish what a rotation interrupted by a crash or quit left behind:
    /// move every database and `.osec` file still under the pending key back
    /// to the current key, then drop the pending key. Run at launch before
    /// any store opens.
    public static func recoverInterruptedRotation() {
        let keyManager = StorageKeyManager.shared
        guard keyManager.rotationMayBeInterrupted else { return }
        let pending: SymmetricKey
        do {
            guard let staged = try keyManager.pendingRotationKey() else {
                keyManager.clearPendingRotationKey()
                return
            }
            pending = staged
        } catch {
            rotationLog.error("rotation recovery: pending key unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let current: SymmetricKey
        do {
            current = try keyManager.currentKey()
        } catch {
            rotationLog.error("rotation recovery: current key unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        if current.withUnsafeBytes({ Data($0) }) == pending.withUnsafeBytes({ Data($0) }) {
            keyManager.clearPendingRotationKey()
            return
        }

        var clean = true
        var moved = 0
        for target in StorageDatabaseCatalog.databaseTargets()
        where StorageFileFormat.detect(path: target.path) == .encrypted {
            if databaseOpens(path: target.path, key: current) { continue }
            guard databaseOpens(path: target.path, key: pending) else {
                rotationLog.error("rotation recovery: \(target.label, privacy: .public) opens with neither key")
                continue
            }
            do {
                try rekeyDatabase(path: target.path, oldKey: pending, newKey: current)
                moved += 1
            } catch {
                clean = false
                rotationLog.error(
                    "rotation recovery: \(target.label, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if let enumerator = FileManager.default.enumerator(at: OsaurusPaths.root(), includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "osec" {
                if (try? EncryptedFileStore.read(file, key: current)) != nil { continue }
                guard let plaintext = try? EncryptedFileStore.read(file, key: pending) else { continue }
                do {
                    try EncryptedFileStore.write(plaintext, to: file, key: current)
                    moved += 1
                } catch {
                    clean = false
                    rotationLog.error(
                        "rotation recovery: \(file.lastPathComponent, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        rotationLog.notice("rotation recovery: moved \(moved) artifact(s) back to the current key")
        if clean { keyManager.clearPendingRotationKey() }
    }

    private static func databaseOpens(path: String, key: SymmetricKey) -> Bool {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(path, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let conn = dbPointer else {
            sqlite3_close(dbPointer)
            return false
        }
        defer { sqlite3_close(conn) }
        return (try? applyKey(key, to: conn)) != nil
    }

    // MARK: - Fault injection

    enum RotationCrashForTesting: Error { case crashed }

    #if DEBUG
        /// What a test wants rotation to do after rekeying `afterDatabases`
        /// databases: fail normally (and roll back), or stop dead as if the
        /// process died.
        enum RotationFault {
            case fail(afterDatabases: Int)
            case crash(afterDatabases: Int)
        }

        private static let faultLock = NSLock()
        nonisolated(unsafe) private static var _faultForTesting: RotationFault?
        static var faultForTesting: RotationFault? {
            get { faultLock.withLock { _faultForTesting } }
            set { faultLock.withLock { _faultForTesting = newValue } }
        }
    #endif

    private static func injectFaultForTesting(afterRekeying count: Int) throws {
        #if DEBUG
            switch faultForTesting {
            case .fail(let n) where n == count:
                throw StorageExportError.rekeyFailed("injected failure after \(count) database(s)")
            case .crash(let n) where n == count:
                throw RotationCrashForTesting.crashed
            default:
                break
            }
        #endif
    }

    // MARK: - Internals: per-DB

    private func exportOneDatabase(
        target: StorageDatabaseCatalog.DatabaseTarget,
        key: SymmetricKey?,
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

        // Detection-first: a plaintext store is just copied; only an encrypted
        // store needs the key + sqlcipher_export.
        switch StorageFileFormat.detect(path: target.path) {
        case .empty:
            return .success(())
        case .plaintext:
            do {
                try fm.copyItem(atPath: target.path, toPath: outPath.path)
                return .success(())
            } catch {
                return .failure(StorageExportError.writeFailed("copy plaintext \(target.label)"))
            }
        case .encrypted:
            break  // fall through to the SQLCipher export below
        }
        guard let key else { return .failure(StorageExportError.keyUnavailable) }

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

    private static func rekeyDatabase(path: String, oldKey: SymmetricKey, newKey: SymmetricKey) throws {
        var dbPointer: OpaquePointer?
        guard sqlite3_open(path, &dbPointer) == SQLITE_OK, let conn = dbPointer else {
            sqlite3_close(dbPointer)
            throw StorageExportError.rekeyFailed("open \(path)")
        }
        defer { sqlite3_close(conn) }

        try applyKey(oldKey, to: conn)

        // Now rekey to the new value.
        let newHex = newKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        if sqlite3_exec(conn, "PRAGMA rekey = \"x'\(newHex)'\"", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("PRAGMA rekey")
        }
    }

    /// Key `conn` and force a read, so a wrong key fails here rather than on
    /// the first real query.
    private static func applyKey(_ key: SymmetricKey, to conn: OpaquePointer) throws {
        let hex = key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        if sqlite3_exec(conn, "PRAGMA key = \"x'\(hex)'\"", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("PRAGMA key")
        }
        for pragma in [
            "PRAGMA cipher_memory_security = OFF",
            "PRAGMA cipher_page_size = 4096",
            "PRAGMA kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(conn, pragma, nil, nil, nil)
        }
        if sqlite3_exec(conn, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            throw StorageExportError.rekeyFailed("verify key")
        }
    }

    // MARK: - Internals: file trees

    private func decryptOSecTree(under url: URL, key: SymmetricKey?, into destination: URL) -> Int {
        let fm = FileManager.default
        // `.osec` files require the key to decrypt; without it there's nothing
        // safe to do here (plaintext config is exported by other paths).
        guard let key else { return 0 }
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

    private func decryptBlobsDir(_ url: URL, key: SymmetricKey?, into destination: URL) -> Int {
        let fm = FileManager.default
        let outDir = destination.appendingPathComponent("blobs", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var count = 0
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !entry.hasDirectoryPath {
            if entry.pathExtension == "osec" {
                // Encrypted blob — needs the key to decrypt.
                guard let key, let plaintext = try? EncryptedFileStore.read(entry, key: key) else {
                    continue
                }
                let dest = outDir.appendingPathComponent(entry.deletingPathExtension().lastPathComponent)
                try? plaintext.write(to: dest, options: [.atomic])
                count += 1
            } else {
                // Already-plaintext blob — copy as-is.
                let dest = outDir.appendingPathComponent(entry.lastPathComponent)
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: entry, to: dest)) != nil { count += 1 }
            }
        }
        return count
    }

    /// Re-encrypt every `.osec` under `url` that `oldKey` opens. Files under
    /// another key (or unreadable) are left alone; a failed write throws so
    /// the rotation rolls back instead of installing a key some files lack.
    private static func rewrapOSecTree(
        under url: URL,
        from oldKey: SymmetricKey,
        to newKey: SymmetricKey,
        rewrapped: inout [URL]
    ) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in enumerator where f.pathExtension == "osec" {
            guard let plaintext = try? EncryptedFileStore.read(f, key: oldKey) else { continue }
            do {
                try EncryptedFileStore.write(plaintext, to: f, key: newKey)
            } catch {
                throw StorageExportError.rekeyFailed("rewrap \(f.lastPathComponent): \(error.localizedDescription)")
            }
            rewrapped.append(f)
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
