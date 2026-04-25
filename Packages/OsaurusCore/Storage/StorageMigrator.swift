//
//  StorageMigrator.swift
//  osaurus
//
//  One-shot, idempotent at-rest encryption migrator. Runs on first
//  launch of a build that ships SQLCipher + EncryptedFileStore, and
//  on any subsequent launch where `~/.osaurus/.storage-version` is
//  older than `Self.targetVersion`.
//
//  Steps (in order, fail-soft per step):
//
//   1. Load (or create) the storage encryption key via
//      `StorageKeyManager`.
//   2. For each of the five plaintext SQLite databases under
//      `~/.osaurus/`, re-encrypt via SQLCipher's
//      `sqlcipher_export` and atomically replace.
//   3. Re-encrypt every JSON file under the encrypt-on-disk
//      directories (agents, themes, schedules, watchers, …).
//   4. Bump `~/.osaurus/.storage-version` to `Self.targetVersion`.
//   5. Move the original plaintext files into
//      `~/.osaurus/.pre-encryption-backup/` (kept for one app
//      version, then auto-cleaned on the launch after that).
//   6. Trigger an async `MemorySearchService.shared.rebuildIndex()`
//      so the per-agent vector dirs come back populated.
//
//  Concurrency: synchronous from the caller's perspective, runs on
//  whichever queue/actor invokes it. Designed to be called from the
//  main-actor `WhatsNewGate` while a "Securing your data" overlay
//  is shown, *before* any app code opens a database — opening
//  SQLCipher against a still-plaintext file and then hot-swapping
//  it underneath is a recipe for crashes. The migrator itself never
//  uses the shared `Database.shared` singletons; it operates on
//  raw paths so the regular code path is free to open the encrypted
//  DBs immediately afterwards.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import os

public enum StorageMigratorError: LocalizedError {
    case keyUnavailable
    case sqlcipherExportFailed(String, String)  // (dbPath, message)
    case fileEncryptionFailed(String)
    case versionWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "Storage migrator could not obtain encryption key"
        case .sqlcipherExportFailed(let p, let m): return "SQLCipher export failed for \(p): \(m)"
        case .fileEncryptionFailed(let p): return "File encryption failed for \(p)"
        case .versionWriteFailed(let m): return "Failed to write storage-version stamp: \(m)"
        }
    }
}

public actor StorageMigrator {
    public static let shared = StorageMigrator()

    /// Bump when adding new at-rest encryption steps. The migrator is
    /// idempotent per step so re-running an already-migrated DB is
    /// safe.
    public static let targetVersion: Int = 1

    private static let versionFilename = ".storage-version"
    private static let backupDirName = ".pre-encryption-backup"
    private static let backupReceiptFilename = ".pre-encryption-backup.receipt"

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.migrator")

    public struct Progress: Sendable {
        public var stepLabel: String
        public var completed: Int
        public var total: Int
    }

    /// Outcome summary persisted to disk so Settings + tests can
    /// inspect the most recent migration result without re-running it.
    public struct OutcomeSummary: Codable, Sendable {
        public var fromVersion: Int
        public var toVersion: Int
        public var succeededTargets: [String]
        public var failedTargets: [String: String]  // label → message
        public var jsonFilesEncrypted: Int
        public var ranAt: Date
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    private init() {}

    // MARK: - Public entrypoint

    /// Returns true when there's at least one un-migrated artifact on
    /// disk. Cheap; reads `.storage-version` only.
    public func needsMigration() -> Bool {
        currentVersion() < Self.targetVersion
    }

    /// Run the migrator. Safe to call repeatedly: completed steps
    /// detect themselves and short-circuit.
    @discardableResult
    public func runIfNeeded(progress: ProgressHandler? = nil) async -> Result<Int, StorageMigratorError> {
        let from = currentVersion()
        guard from < Self.targetVersion else { return .success(from) }

        // Step 1 — key.
        let key: SymmetricKey
        do {
            key = try StorageKeyManager.shared.currentKey()
        } catch {
            log.error("storage migrator: key unavailable: \(error.localizedDescription)")
            return .failure(.keyUnavailable)
        }

        OsaurusPaths.ensureExistsSilent(backupDir())
        var outcome = OutcomeSummary(
            fromVersion: from,
            toVersion: Self.targetVersion,
            succeededTargets: [],
            failedTargets: [:],
            jsonFilesEncrypted: 0,
            ranAt: Date()
        )

        // Step 2 — SQLite re-encryption.
        let dbs = Self.databaseTargets()
        for (idx, target) in dbs.enumerated() {
            progress?(Progress(stepLabel: "Encrypting \(target.label)", completed: idx, total: dbs.count + 1))
            do {
                try migrateOneDatabase(target: target, key: key)
                outcome.succeededTargets.append(target.label)
            } catch let error as StorageMigratorError {
                log.error("storage migrator: \(target.label) — \(error.localizedDescription)")
                outcome.failedTargets[target.label] = error.localizedDescription
                // Fail-soft: keep going so other DBs don't get blocked.
            } catch {
                log.error("storage migrator: db \(target.label) failed: \(error.localizedDescription)")
                outcome.failedTargets[target.label] = error.localizedDescription
            }
        }

        // Step 3 — JSON re-encryption.
        progress?(Progress(stepLabel: "Encrypting configuration files", completed: dbs.count, total: dbs.count + 1))
        outcome.jsonFilesEncrypted = encryptJSONTrees(key: key)

        // Step 4 — version stamp + outcome receipt.
        do {
            try writeVersion(Self.targetVersion)
        } catch {
            log.error("storage migrator: \(error.localizedDescription)")
            return .failure(.versionWriteFailed(error.localizedDescription))
        }
        try? writeOutcomeReceipt(outcome)

        // Step 5 — best-effort vector rebuild from the now-encrypted SQL.
        Task.detached { [log] in
            log.info("storage migrator: rebuilding per-agent vector indexes")
            await MemorySearchService.shared.rebuildIndex()
        }

        progress?(Progress(stepLabel: "Done", completed: dbs.count + 1, total: dbs.count + 1))
        log.info(
            "storage migrator: completed (from v\(from) → v\(Self.targetVersion), \(outcome.succeededTargets.count) DBs OK, \(outcome.failedTargets.count) failed, \(outcome.jsonFilesEncrypted) JSON files)"
        )
        return .success(Self.targetVersion)
    }

    // MARK: - Fresh-install version stamp

    /// On a fresh install (or the first launch of a build that ships
    /// SQLCipher onto a brand-new `~/.osaurus/`), there's nothing to
    /// migrate but we still want to write the version stamp so the
    /// gate code doesn't re-scan disk every launch. Idempotent.
    public func stampCurrentVersionIfMissing() {
        guard currentVersion() < Self.targetVersion else { return }
        do {
            try writeVersion(Self.targetVersion)
            log.info("storage migrator: stamped fresh-install version v\(Self.targetVersion)")
        } catch {
            log.warning("storage migrator: failed to stamp fresh-install version: \(error.localizedDescription)")
        }
    }

    // MARK: - Backup retention

    /// Delete `~/.osaurus/.pre-encryption-backup/` once the user has
    /// successfully launched the post-migration build at least once.
    /// Two-launch retention: migration writes a receipt; on the
    /// **next** clean launch (with `isReady == true` and no errors),
    /// we delete the backup. Caller is the coordinator, called only
    /// after the gate has cleared.
    public func cleanupBackupIfStale() {
        let receipt = backupReceiptURL()
        let backup = backupDir()
        let fm = FileManager.default

        // No receipt + no backup → nothing to do.
        let receiptExists = fm.fileExists(atPath: receipt.path)
        let backupExists = fm.fileExists(atPath: backup.path)
        guard receiptExists || backupExists else { return }

        if receiptExists {
            // Second launch after migration: clear the receipt and
            // the backup. The receipt is written at the END of
            // `runIfNeeded` and read on subsequent launches.
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: receipt)
            log.info("storage migrator: cleaned pre-encryption backup")
        } else if backupExists {
            // Backup but no receipt — this should be the immediate
            // post-migration launch. Drop a receipt so we'll clean
            // it next time.
            try? Data().write(to: receipt)
        }
    }

    // MARK: - Outcome receipt persistence

    /// Writes a JSON receipt of the most recent migration outcome.
    /// Used by the Storage settings panel to surface partial failures
    /// + by the backup cleanup logic.
    private func writeOutcomeReceipt(_ outcome: OutcomeSummary) throws {
        let url = OsaurusPaths.root().appendingPathComponent(".storage-migration.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(outcome)
        try data.write(to: url, options: [.atomic])
    }

    /// Read the most recent migration outcome, if any. Used by
    /// `StorageSettingsView` to surface partial failures.
    public func loadLastOutcome() -> OutcomeSummary? {
        let url = OsaurusPaths.root().appendingPathComponent(".storage-migration.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OutcomeSummary.self, from: data)
    }

    // MARK: - Key-mismatch detection

    /// Returns the list of database targets that are encrypted on
    /// disk but **cannot be opened** with the current key. Surfaces
    /// the "moved Keychain / wrong key" recovery scenario.
    ///
    /// Cheap: just calls `EncryptedSQLiteOpener.open(... key: ...)`
    /// for each target and counts failures.
    public func detectKeyMismatch() -> [DatabaseTarget] {
        let key: SymmetricKey?
        do {
            key = try StorageKeyManager.shared.currentKey()
        } catch {
            // No key at all → every encrypted DB is a mismatch.
            return Self.databaseTargets().filter { target in
                FileManager.default.fileExists(atPath: target.path)
                    && EncryptedSQLiteOpener.isEncryptedDatabase(path: target.path)
            }
        }
        guard let key else { return [] }

        var mismatches: [DatabaseTarget] = []
        for target in Self.databaseTargets() {
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            guard EncryptedSQLiteOpener.isEncryptedDatabase(path: target.path) else { continue }
            do {
                let conn = try EncryptedSQLiteOpener.open(path: target.path, key: key)
                sqlite3_close(conn)
            } catch {
                mismatches.append(target)
            }
        }
        return mismatches
    }

    private func backupReceiptURL() -> URL {
        OsaurusPaths.root().appendingPathComponent(Self.backupReceiptFilename)
    }

    // MARK: - SQLite path

    /// One unified target description so the migrator loop stays flat.
    public struct DatabaseTarget: Sendable {
        public let label: String
        public let path: String
    }

    public static func databaseTargets() -> [DatabaseTarget] {
        var targets: [DatabaseTarget] = [
            .init(label: "chat history", path: OsaurusPaths.chatHistoryDatabaseFile().path),
            .init(label: "memory", path: OsaurusPaths.memoryDatabaseFile().path),
            .init(label: "methods", path: OsaurusPaths.methodsDatabaseFile().path),
            .init(label: "tool index", path: OsaurusPaths.toolIndexDatabaseFile().path),
        ]
        // Plugin DBs — one per installed plugin. We can discover them
        // by walking `Tools/<pluginId>/data/data.db`.
        let toolsDir = OsaurusPaths.tools()
        if let plugins = try? FileManager.default.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil) {
            for plugin in plugins {
                let dbPath = OsaurusPaths.pluginDatabaseFile(for: plugin.lastPathComponent).path
                if FileManager.default.fileExists(atPath: dbPath) {
                    targets.append(.init(label: "plugin \(plugin.lastPathComponent)", path: dbPath))
                }
            }
        }
        return targets
    }

    /// Re-encrypt one SQLite database. Idempotent: detects already-
    /// encrypted DBs (`isEncryptedDatabase`) and skips them.
    private func migrateOneDatabase(target: DatabaseTarget, key: SymmetricKey) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            log.info("storage migrator: \(target.label) — no DB on disk, skipping")
            return
        }
        if EncryptedSQLiteOpener.isEncryptedDatabase(path: target.path) {
            log.info("storage migrator: \(target.label) — already encrypted, skipping")
            return
        }

        let plaintextPath = target.path
        let encryptedPath = plaintextPath + ".enc.tmp"
        try? fm.removeItem(atPath: encryptedPath)

        // Open plaintext source.
        var srcDB: OpaquePointer?
        guard sqlite3_open(plaintextPath, &srcDB) == SQLITE_OK, let src = srcDB else {
            throw StorageMigratorError.sqlcipherExportFailed(plaintextPath, "open source")
        }
        defer { sqlite3_close(src) }

        // ATTACH the encrypted target with the key.
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let keyHex = keyBytes.map { String(format: "%02x", $0) }.joined()
        let attachSQL =
            "ATTACH DATABASE '\(escape(encryptedPath))' AS encrypted KEY \"x'\(keyHex)'\""
        if sqlite3_exec(src, attachSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(src))
            throw StorageMigratorError.sqlcipherExportFailed(plaintextPath, "attach: \(msg)")
        }

        // Apply the same cipher_* PRAGMAs that EncryptedSQLiteOpener
        // sets on regular open. SQLCipher requires these on the
        // attached DB before sqlcipher_export.
        for pragma in [
            "PRAGMA encrypted.cipher_memory_security = OFF",
            "PRAGMA encrypted.cipher_page_size = 4096",
            "PRAGMA encrypted.kdf_iter = 256000",
        ] {
            _ = sqlite3_exec(src, pragma, nil, nil, nil)
        }

        // Export.
        if sqlite3_exec(src, "SELECT sqlcipher_export('encrypted')", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(src))
            _ = sqlite3_exec(src, "DETACH DATABASE encrypted", nil, nil, nil)
            try? fm.removeItem(atPath: encryptedPath)
            throw StorageMigratorError.sqlcipherExportFailed(plaintextPath, "export: \(msg)")
        }

        // Forward user_version so migrations don't think we're a fresh DB.
        var userVersion: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(src, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            if sqlite3_step(s) == SQLITE_ROW { userVersion = sqlite3_column_int(s, 0) }
            sqlite3_finalize(s)
        }
        if userVersion > 0 {
            _ = sqlite3_exec(src, "PRAGMA encrypted.user_version = \(userVersion)", nil, nil, nil)
        }

        _ = sqlite3_exec(src, "DETACH DATABASE encrypted", nil, nil, nil)

        // Move plaintext to backup, encrypted into place.
        let backup = backupDir().appendingPathComponent(
            URL(fileURLWithPath: plaintextPath).lastPathComponent + ".plaintext"
        )
        try? fm.removeItem(at: backup)
        try? fm.moveItem(atPath: plaintextPath, toPath: backup.path)
        do {
            try fm.moveItem(atPath: encryptedPath, toPath: plaintextPath)
        } catch {
            // Roll back the swap.
            try? fm.moveItem(atPath: backup.path, toPath: plaintextPath)
            throw StorageMigratorError.sqlcipherExportFailed(plaintextPath, "rename: \(error.localizedDescription)")
        }

        // WAL/SHM siblings of the original plaintext are stale once
        // we swap the file underneath; remove them so SQLite doesn't
        // attempt to recover from a foreign WAL.
        for sibling in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: plaintextPath + sibling)
        }

        log.info("storage migrator: encrypted \(target.label)")
    }

    private func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - JSON re-encryption

    private func encryptJSONTrees(key: SymmetricKey) -> Int {
        let directories: [URL] = [
            OsaurusPaths.agents(),
            OsaurusPaths.themes(),
            OsaurusPaths.schedules(),
            OsaurusPaths.watchers(),
            OsaurusPaths.providers(),
            OsaurusPaths.sandboxPluginLibrary(),
            OsaurusPaths.toolSpecs(),
            OsaurusPaths.sessionsArchive(),
        ]
        var total = 0
        for dir in directories {
            total += encryptJSONFilesInDir(dir, key: key)
        }
        // Top-level config dir, but skip the runtime/* subtree —
        // other Osaurus processes need it as plaintext for service
        // discovery.
        total += encryptJSONFilesInDir(
            OsaurusPaths.config(),
            key: key,
            recursive: true,
            skipDir: OsaurusPaths.runtime()
        )
        return total
    }

    @discardableResult
    private func encryptJSONFilesInDir(
        _ dir: URL,
        key: SymmetricKey,
        recursive: Bool = false,
        skipDir: URL? = nil
    ) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return 0 }

        let enumerator: FileManager.DirectoryEnumerator?
        if recursive {
            enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        } else {
            enumerator = nil
        }

        let candidates: [URL] = {
            if let enumerator {
                var found: [URL] = []
                for case let url as URL in enumerator {
                    if let skip = skipDir, url.path.hasPrefix(skip.path) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !isDir, url.pathExtension.lowercased() == "json" {
                        found.append(url)
                    }
                }
                return found
            }
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return entries.filter { $0.pathExtension.lowercased() == "json" }
        }()

        var encrypted = 0
        for url in candidates {
            let encryptedURL = EncryptedFileStore.encryptedURL(for: url)
            if fm.fileExists(atPath: encryptedURL.path) { continue }
            do {
                let data = try Data(contentsOf: url)
                if EncryptedFileStore.looksLikeEnvelope(data) { continue }
                try EncryptedFileStore.write(data, to: encryptedURL, key: key)
                let backupURL = backupDir()
                    .appendingPathComponent("json")
                    .appendingPathComponent(url.lastPathComponent)
                OsaurusPaths.ensureExistsSilent(backupURL.deletingLastPathComponent())
                try? fm.moveItem(at: url, to: backupURL)
                log.info("storage migrator: encrypted \(url.lastPathComponent)")
                encrypted += 1
            } catch {
                log.warning("storage migrator: skip \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return encrypted
    }

    // MARK: - Version stamp

    public func currentVersion() -> Int {
        let url = versionFile()
        guard let data = try? Data(contentsOf: url),
            let s = String(data: data, encoding: .utf8),
            let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return v
    }

    private func writeVersion(_ v: Int) throws {
        let url = versionFile()
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        do {
            try String(v).data(using: .utf8)?.write(to: url, options: [.atomic])
        } catch {
            throw StorageMigratorError.versionWriteFailed(error.localizedDescription)
        }
    }

    private func versionFile() -> URL {
        OsaurusPaths.root().appendingPathComponent(Self.versionFilename)
    }

    private func backupDir() -> URL {
        OsaurusPaths.root().appendingPathComponent(Self.backupDirName, isDirectory: true)
    }
}
