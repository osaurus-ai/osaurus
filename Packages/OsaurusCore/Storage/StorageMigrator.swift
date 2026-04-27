//
//  StorageMigrator.swift
//  osaurus
//
//  One-shot, idempotent at-rest encryption migrator. Runs on first
//  launch of a build that ships SQLCipher, and on any subsequent
//  launch where `~/.osaurus/.storage-version` is older than
//  `Self.targetVersion`. See the `targetVersion` doc-comment below
//  for the version-by-version step list.
//
//  Steps (in order, fail-soft per step):
//
//   1. Load (or create) the storage encryption key via
//      `StorageKeyManager`.
//   2a. v1→v2 recovery (only when bumping a v1-stamped install):
//       restore any leftover `.osec` JSON files back to plaintext —
//       see `recoverEncryptedJSON(key:)` for the rationale. No-op
//       when there's nothing to recover.
//   2b. For each of the four core SQLite databases plus every
//       discovered plugin DB under `~/.osaurus/`, re-encrypt via
//       SQLCipher's `sqlcipher_export` and atomically replace
//       (skipping any that are already SQLCipher-encrypted).
//   3.  Bump `~/.osaurus/.storage-version` to `Self.targetVersion`
//       and write an outcome receipt (`.storage-migration.json`)
//       for the Storage settings panel.
//   4.  Trigger an async `MemorySearchService.shared.rebuildIndex()`
//       so the per-agent vector dirs come back populated.
//
//  Originals of every replaced SQLite database are moved into
//  `~/.osaurus/.pre-encryption-backup/`, kept for one app version,
//  then auto-cleaned by `cleanupBackupIfStale()` on the second
//  launch after migration.
//
//  Concurrency: this is a Swift `actor`, but the actual work is
//  driven through `StorageMigrationCoordinator` which gates every
//  `*Database.shared.open()` call site (sync via
//  `blockingAwaitReady()` and async via `awaitReady()`) so the
//  app can't race SQLCipher against a still-plaintext file. The
//  migrator itself never uses the shared `Database.shared`
//  singletons — it operates on raw paths so the regular code path
//  is free to open the encrypted DBs as soon as we return.
//
//  Cross-process safety: `runIfNeeded` acquires an exclusive
//  `flock(2)` on `~/.osaurus/.storage-migration.lock` for the
//  entire run. Two Osaurus processes launched simultaneously
//  serialize on this lock; the loser short-circuits because the
//  winner stamped `.storage-version` before releasing.
//

import CryptoKit
import Darwin
import Foundation
import OsaurusSQLCipher
import os

public enum StorageMigratorError: LocalizedError {
    case keyUnavailable
    case sqlcipherExportFailed(String, String)  // (dbPath, message)
    case versionWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "Storage migrator could not obtain encryption key"
        case .sqlcipherExportFailed(let p, let m): return "SQLCipher export failed for \(p): \(m)"
        case .versionWriteFailed(let m): return "Failed to write storage-version stamp: \(m)"
        }
    }
}

/// Disambiguating shim for the libc `flock(int, int)` system call.
/// Swift's `Darwin.flock` resolves preferentially to the homonymous
/// `<sys/fcntl.h>` struct (used by `fcntl` for record locks), so a
/// bare `Darwin.flock(fd, op)` fails to compile with "argument
/// passed to call that takes no arguments". Calling through this
/// `@_silgen_name`'d shim binds directly to the libc function.
@_silgen_name("flock")
private func lockFile(_ fd: Int32, _ operation: Int32) -> Int32

public actor StorageMigrator {
    public static let shared = StorageMigrator()

    /// Bump when adding new at-rest encryption steps. The migrator is
    /// idempotent per step so re-running an already-migrated DB is
    /// safe.
    ///
    /// Version history:
    ///  - v1: SQLCipher-encrypt the five SQLite databases. (Initial
    ///        v1 builds also encrypted JSON files under `agents/`,
    ///        `themes/`, `config/`, etc., but the consuming stores
    ///        were never wired to read `.osec`, so `agents` /
    ///        `themes` / settings disappeared from the UI and
    ///        services that depend on them stalled the main
    ///        thread. v2 below auto-recovers from that bug.)
    ///  - v2: Restore any leftover `.osec` JSON files back to
    ///        plaintext `.json` (using `.pre-encryption-backup/json/`
    ///        when available, AES-GCM decrypt otherwise). v1 itself
    ///        no longer encrypts JSON.
    public static let targetVersion: Int = 2

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
    ///
    /// **Schema-evolution contract:** every field added after the
    /// initial v1 release MUST be optional with a sensible default
    /// in the custom decoder below, so a fresh build that ships a
    /// new field can still parse a receipt left behind by the
    /// previous build. Removing a field is a breaking change —
    /// don't.
    public struct OutcomeSummary: Codable, Sendable {
        public var fromVersion: Int
        public var toVersion: Int
        public var succeededTargets: [String]
        public var failedTargets: [String: String]  // label → message
        /// Number of `.osec` JSON files that v1→v2 recovery
        /// restored back to plaintext. Zero on a clean install or
        /// any launch after the user is on v2 already.
        public var jsonFilesRecovered: Int
        public var ranAt: Date

        public init(
            fromVersion: Int,
            toVersion: Int,
            succeededTargets: [String],
            failedTargets: [String: String],
            jsonFilesRecovered: Int,
            ranAt: Date
        ) {
            self.fromVersion = fromVersion
            self.toVersion = toVersion
            self.succeededTargets = succeededTargets
            self.failedTargets = failedTargets
            self.jsonFilesRecovered = jsonFilesRecovered
            self.ranAt = ranAt
        }

        // Custom decoder so future field additions don't break old
        // receipts. Every field is decoded with a sensible default
        // for forward + backward compatibility. The legacy
        // `jsonFilesEncrypted` key (written by initial v1 builds
        // before the v1→v2 recovery existed) maps onto the renamed
        // `jsonFilesRecovered` so the Settings panel still has a
        // number to show.
        private enum CodingKeys: String, CodingKey {
            case fromVersion, toVersion, succeededTargets, failedTargets, ranAt
            case jsonFilesRecovered
            case jsonFilesEncrypted  // legacy v1
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.fromVersion = (try? c.decode(Int.self, forKey: .fromVersion)) ?? 0
            self.toVersion = (try? c.decode(Int.self, forKey: .toVersion)) ?? 0
            self.succeededTargets = (try? c.decode([String].self, forKey: .succeededTargets)) ?? []
            self.failedTargets = (try? c.decode([String: String].self, forKey: .failedTargets)) ?? [:]
            self.jsonFilesRecovered =
                (try? c.decode(Int.self, forKey: .jsonFilesRecovered))
                ?? (try? c.decode(Int.self, forKey: .jsonFilesEncrypted))
                ?? 0
            self.ranAt = (try? c.decode(Date.self, forKey: .ranAt)) ?? Date(timeIntervalSince1970: 0)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(fromVersion, forKey: .fromVersion)
            try c.encode(toVersion, forKey: .toVersion)
            try c.encode(succeededTargets, forKey: .succeededTargets)
            try c.encode(failedTargets, forKey: .failedTargets)
            try c.encode(jsonFilesRecovered, forKey: .jsonFilesRecovered)
            try c.encode(ranAt, forKey: .ranAt)
        }
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
    ///
    /// Cross-process safety: acquires an exclusive `flock(2)` on
    /// `~/.osaurus/.storage-migration.lock` for the entire run.
    /// A second Osaurus process launched mid-migration blocks on
    /// the lock until the first one finishes, then re-checks
    /// `currentVersion()` and short-circuits because the first
    /// process already stamped it. Without this, two processes
    /// would race on the same `*.enc.tmp` filenames.
    @discardableResult
    public func runIfNeeded(progress: ProgressHandler? = nil) async -> Result<Int, StorageMigratorError> {
        let from = currentVersion()
        guard from < Self.targetVersion else { return .success(from) }

        // Acquire cross-process lock. Held until this function
        // returns (the deferred close releases the OS-level flock
        // too). `Darwin.flock` is shadowed by a struct of the same
        // name in `<sys/fcntl.h>`; use the explicit C-typedef'd
        // `Foundation.flock` re-export — same binding, unambiguous
        // name.
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        let lockPath = OsaurusPaths.root().appendingPathComponent(".storage-migration.lock").path
        let lockFD = lockPath.withCString { Darwin.open($0, O_RDWR | O_CREAT, 0o600) }
        if lockFD >= 0 {
            // LOCK_EX blocks until granted. The OS releases the
            // lock when the file descriptor closes (close below).
            _ = lockFile(lockFD, LOCK_EX)
        } else {
            log.warning(
                "storage migrator: could not open lock file at \(lockPath); proceeding without cross-process protection"
            )
        }
        defer {
            if lockFD >= 0 {
                _ = lockFile(lockFD, LOCK_UN)
                _ = Darwin.close(lockFD)
            }
        }

        // After acquiring the lock, re-read the version stamp — a
        // sibling process may have completed the migration while we
        // were blocked.
        let fromAfterLock = currentVersion()
        guard fromAfterLock < Self.targetVersion else {
            log.info("storage migrator: another process already migrated to v\(fromAfterLock); skipping")
            return .success(fromAfterLock)
        }

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
            fromVersion: fromAfterLock,
            toVersion: Self.targetVersion,
            succeededTargets: [],
            failedTargets: [:],
            jsonFilesRecovered: 0,
            ranAt: Date()
        )

        // Step 2a — v1→v2 recovery. The initial v1 build encrypted
        // every JSON file under `agents/`, `themes/`, `config/`, …
        // but the consuming stores (`AgentManager`, `ThemeManager`,
        // `*ConfigurationStore`, `ScheduleStore`, `WatcherStore`,
        // `SlashCommandStore`, `SandboxPluginLibrary`, etc.) were
        // never wired to read `.osec`, so the user's
        // agents/themes/config went dark and services that depend
        // on them stalled the main thread. v2 walks the tree once
        // and restores any leftover `.osec` JSON twins back to
        // plaintext (preferring the pre-encryption backup, falling
        // back to in-place AES-GCM decrypt). Cheap when there's
        // nothing to recover.
        //
        // Re-enabling JSON encryption is gated on first migrating
        // every consuming store to `EncryptedFileStore` — tracked
        // as a follow-up. The bulk of the security win is the
        // SQLCipher-encrypted DBs in step 2b.
        if fromAfterLock <= 1 {
            outcome.jsonFilesRecovered = recoverEncryptedJSON(key: key)
            if outcome.jsonFilesRecovered > 0 {
                log.info(
                    "storage migrator: v1→v2 recovery — restored \(outcome.jsonFilesRecovered) JSON files"
                )
            }
        }

        // Step 2b — SQLite re-encryption.
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

        // Step 3 — version stamp + outcome receipt.
        do {
            try writeVersion(Self.targetVersion)
        } catch {
            log.error("storage migrator: \(error.localizedDescription)")
            return .failure(.versionWriteFailed(error.localizedDescription))
        }
        try? writeOutcomeReceipt(outcome)

        // Step 4 — best-effort vector rebuild from the now-encrypted SQL.
        Task.detached { [log] in
            log.info("storage migrator: rebuilding per-agent vector indexes")
            await MemorySearchService.shared.rebuildIndex()
        }

        progress?(Progress(stepLabel: "Done", completed: dbs.count + 1, total: dbs.count + 1))
        log.info(
            "storage migrator: completed (from v\(fromAfterLock) → v\(Self.targetVersion), \(outcome.succeededTargets.count) DBs OK, \(outcome.failedTargets.count) failed, \(outcome.jsonFilesRecovered) JSON recovered)"
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
    ///
    /// Labels for the four core databases are short ("chat history",
    /// "memory", ...). Plugin databases use the `pluginLabelPrefix`
    /// + plugin ID format so callers (UI banner splits, cleanup
    /// service, tests) can recover the plugin ID via `pluginId`
    /// instead of substring-matching by hand.
    public struct DatabaseTarget: Sendable {
        public static let pluginLabelPrefix = "plugin "

        public let label: String
        public let path: String

        public init(label: String, path: String) {
            self.label = label
            self.path = path
        }

        /// Convenience constructor for plugin targets — keeps the
        /// label format ("plugin <id>") in one place.
        public static func plugin(id: String, path: String) -> DatabaseTarget {
            DatabaseTarget(label: pluginLabelPrefix + id, path: path)
        }

        /// `nil` for the four core targets, the plugin ID otherwise.
        /// Use this instead of `label.hasPrefix("plugin ")`.
        public var pluginId: String? {
            guard label.hasPrefix(Self.pluginLabelPrefix) else { return nil }
            return String(label.dropFirst(Self.pluginLabelPrefix.count))
        }
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
                let pluginId = plugin.lastPathComponent
                // Production safety net: any `com.test.*` plugin ID
                // can only exist on disk because a developer ran the
                // OsaurusCore test suite without isolating
                // `OsaurusPaths.overrideRoot` (see
                // `DispatchRateLimitTests` for the historical
                // offender). End users will never have one. Filtering
                // here keeps these out of `detectKeyMismatch()` so
                // the Storage settings panel doesn't surface a
                // scary "key doesn't match the encrypted databases"
                // banner full of test UUIDs.
                if Self.isLeakedTestPluginId(pluginId) { continue }
                let dbPath = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
                if FileManager.default.fileExists(atPath: dbPath) {
                    targets.append(.plugin(id: pluginId, path: dbPath))
                }
            }
        }
        return targets
    }

    /// True for plugin IDs that could only have been created by a
    /// leaked test run (anything with a `com.test.` prefix). Surfaced
    /// as a static helper so the cleanup command in
    /// `StorageExportService` and the unit tests share the same rule.
    public static func isLeakedTestPluginId(_ pluginId: String) -> Bool {
        pluginId.hasPrefix("com.test.")
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

    // MARK: - v1 → v2 JSON recovery

    /// One-shot recovery for users who ran the buggy initial v1
    /// migration (which encrypted JSON without teaching the
    /// consuming stores how to read `.osec`). Walks every directory
    /// under `~/.osaurus/` once, restores any `.osec` JSON twin
    /// back to plaintext at its original location, and removes the
    /// `.osec`.
    ///
    /// CRITICAL data-safety contract (2026-04 incident, providers/
    /// remote.json wipe): the `.osec` is the ground truth of what
    /// the user actually had. Any plaintext file already at the
    /// destination was almost certainly written by a consuming
    /// store that found no `.json`, called its own `load()`, got
    /// an empty default from `init()`, and persisted that empty
    /// state. Trusting that plaintext over the `.osec` silently
    /// deletes user data.
    ///
    /// Preference order, post-fix:
    ///
    ///   1. AES-GCM-decrypt the `.osec`. This is the user's data.
    ///   2. Compare with any plaintext already at the destination.
    ///      - Bytes identical → no-op, just remove the `.osec`.
    ///      - Bytes differ → write decrypted content to the
    ///        destination and stash the previous plaintext as a
    ///        sibling `<name>.replaced-by-recovery.json` so the
    ///        user can manually merge if anything was newer.
    ///   3. If the `.osec` itself can't be decrypted (key drift,
    ///      truncation), fall back to the backup directory.
    ///
    /// Returns the number of files restored. Idempotent and cheap
    /// when there's nothing to recover (single tree walk that prunes
    /// the backup dir, container state, and the chat-history blobs).
    private func recoverEncryptedJSON(key: SymmetricKey) -> Int {
        let fm = FileManager.default
        let root = OsaurusPaths.root()
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }

        // Pre-index the backup dir so we don't re-scan it for every
        // candidate — n × m → n + m.
        let backupRoot = backupDir().appendingPathComponent("json", isDirectory: true)
        var backupIndex: [String: URL] = [:]
        if let entries = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension.lowercased() == "json" {
                backupIndex[entry.lastPathComponent] = entry
            }
        }

        // Resolve through `standardizedFileURL` so paths like
        // `/var/...` and `/private/var/...` (the macOS tmpdir
        // symlink) compare equal. Without this the prune check
        // silently misses container/ and blobs/ during tests and
        // any time `OsaurusPaths.overrideRoot` resolves to a
        // symlinked directory.
        let prunePrefixes: [String] = [
            backupDir().standardizedFileURL.path,
            OsaurusPaths.container().standardizedFileURL.path,
            OsaurusPaths.chatHistory().appendingPathComponent("blobs").standardizedFileURL.path,
        ]

        var restored = 0
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            if prunePrefixes.contains(where: { path.hasPrefix($0) }) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "osec" else { continue }
            let plaintextURL = EncryptedFileStore.plaintextURL(for: url)
            // We only restore JSON .osec twins. Attachment blob
            // .osec files in `chat-history/blobs/` are pruned above.
            guard plaintextURL.pathExtension.lowercased() == "json" else { continue }

            // Step 1: decrypt the .osec. This is what the user
            // actually had before the buggy v1 migration. We do
            // this BEFORE inspecting the on-disk plaintext so the
            // .osec's authority is never traded away based on a
            // file the consuming store just synthesized.
            guard let osecData = try? EncryptedFileStore.read(url, key: key) else {
                // Decrypt failed (key drift, truncation). Try the
                // pre-encryption backup as a last resort.
                if !fm.fileExists(atPath: plaintextURL.path),
                    let src = backupIndex[plaintextURL.lastPathComponent],
                    let _ = try? fm.copyItem(at: src, to: plaintextURL)
                {
                    try? fm.removeItem(at: url)
                    restored += 1
                    log.warning(
                        "v1→v2 recovery: decrypt failed for \(url.lastPathComponent), restored from backup"
                    )
                } else {
                    log.error(
                        "v1→v2 recovery: decrypt AND backup BOTH failed for \(url.lastPathComponent) — leaving .osec in place for forensics"
                    )
                }
                continue
            }

            // Step 2: reconcile against any existing plaintext.
            if fm.fileExists(atPath: plaintextURL.path) {
                let existing = (try? Data(contentsOf: plaintextURL)) ?? Data()
                if existing == osecData {
                    // Already in sync — recovery already ran or
                    // the user manually restored. Just clean up.
                    try? fm.removeItem(at: url)
                    continue
                }

                // Plaintext exists AND differs from the .osec.
                // Almost always: consuming store wrote an empty
                // default while we were broken. Stash the
                // existing file before overwriting so a paranoid
                // user can diff/merge.
                let archive =
                    plaintextURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        plaintextURL.deletingPathExtension().lastPathComponent
                            + ".replaced-by-recovery.json"
                    )
                try? fm.removeItem(at: archive)
                if (try? fm.moveItem(at: plaintextURL, to: archive)) != nil {
                    log.notice(
                        "v1→v2 recovery: archived existing \(plaintextURL.lastPathComponent) (\(existing.count) bytes) → \(archive.lastPathComponent) before restoring \(osecData.count)-byte .osec"
                    )
                } else {
                    // Couldn't archive (read-only?). Don't proceed
                    // with the destructive write either.
                    log.error(
                        "v1→v2 recovery: cannot archive existing \(plaintextURL.lastPathComponent); leaving both files in place"
                    )
                    continue
                }
            }

            // Step 3: write the decrypted content into place.
            do {
                try osecData.write(to: plaintextURL, options: [.atomic])
                try? fm.removeItem(at: url)
                restored += 1
            } catch {
                log.warning(
                    "v1→v2 recovery: failed to write \(plaintextURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return restored
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
