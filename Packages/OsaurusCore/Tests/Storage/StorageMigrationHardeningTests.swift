//
//  StorageMigrationHardeningTests.swift
//  osaurusTests
//
//  Hardening for the opt-in at-rest encryption migration, ahead of a wide
//  rollout. Each test pins one of the residual crash/hang/data-loss vectors
//  closed in the convergence path:
//
//  - R1: plugin (and agent) DBs are not registered maintenance handles, so
//    convergence/rotation must close their LIVE connections explicitly via
//    `PluginDatabase.closeAllOpen()` before swapping the file underneath them,
//    or the swap corrupts an open store. Proven by closing a live connection
//    and by running `converge()` against an open plugin DB with data intact.
//  - R2: `converge()` is single-flight. Concurrent calls serialize through the
//    task chain instead of interleaving their gate begin/end + atomic swaps;
//    proven by firing several at once and asserting exactly one conversion.
//  - R3: the FileVault probe's timeout primitive returns promptly on slow work
//    (so a wedged `fdesetup` can never stall launch convergence).
//  - R5: `swap()` replaces first, then drops stale sidecars — no temp/sidecar
//    residue and the swapped file stays openable with its data.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageMigrationHardeningTests {

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-hardening-tests-\(UUID().uuidString)"
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

    // MARK: - R1: plugin DB quiesce

    /// `PluginDatabase.closeAllOpen()` force-closes a live connection (what the
    /// convergence/rotation paths call before swapping the file), and committed
    /// rows survive the close — the connection reopens lazily afterwards.
    @Test
    func pluginCloseAllOpenClosesLiveConnectionAndPreservesData() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = self.tempDir()
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()

            let db = PluginDatabase(pluginId: "com.test.hardening.r1")
            try db.open()
            _ = db.exec(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", paramsJSON: nil)
            _ = db.exec(sql: "INSERT INTO t (v) VALUES ('keep')", paramsJSON: nil)

            // The convergence/rotation quiesce step.
            PluginDatabase.closeAllOpen()

            // Live connection is now closed: queries report not-open.
            #expect(db.query(sql: "SELECT v FROM t LIMIT 1", paramsJSON: nil).contains("Database not open"))

            // Reopen: the committed row survived the forced close.
            try db.open()
            #expect(db.query(sql: "SELECT v FROM t LIMIT 1", paramsJSON: nil).contains("keep"))
            db.close()
        }
    }

    /// End-to-end R1: a plugin DB left OPEN with committed data is correctly
    /// quiesced by `converge()` before the file is swapped, so the file is
    /// converted to the target format AND the data survives (no corruption,
    /// no lost writes from a swap under a live fd).
    @Test
    func convergeQuiescesOpenPluginDBAndConvertsWithDataIntact() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = self.tempDir()
            OsaurusPaths.overrideRoot = root
            let k = self.key(seed: 0x6A)
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared._setKeyForTesting(k)

            // Plugin id WITHOUT a `com.test.` prefix so the storage catalog
            // discovers its on-disk DB (test-prefixed ids are filtered out).
            let pluginId = "hardeningR1Plugin"
            let db = PluginDatabase(pluginId: pluginId)
            try db.open()
            _ = db.exec(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", paramsJSON: nil)
            _ = db.exec(sql: "INSERT INTO t (v) VALUES ('survive')", paramsJSON: nil)

            let dbPath = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
            #expect(StorageFileFormat.detect(path: dbPath) == .plaintext)

            // Converge plaintext -> encrypted with the live connection still
            // open. The coordinator must close it before the swap.
            let report = await StorageMigrationCoordinator.shared.converge(to: .encrypted)
            #expect(report.converted >= 1)
            #expect(report.failed.isEmpty)
            #expect(report.skipped.isEmpty)

            // File converted, data intact under the key.
            #expect(StorageFileFormat.detect(path: dbPath) == .encrypted)
            let conn = try EncryptedSQLiteOpener.open(path: dbPath, key: k)
            #expect(self.readSingleText(conn, "SELECT v FROM t LIMIT 1") == "survive")
            sqlite3_close(conn)

            // Lazy reopen through the plugin connection still reads the data.
            try db.open()
            #expect(db.query(sql: "SELECT v FROM t LIMIT 1", paramsJSON: nil).contains("survive"))
            db.close()
        }
    }

    // MARK: - R2: serialized convergence

    /// Several `converge(to:)` calls fired at once must run strictly
    /// one-at-a-time. With the same target mode, exactly one performs the
    /// conversion and the rest find it already done — proving no interleaving
    /// (which would race the shared temp paths + atomic swaps and corrupt the
    /// store). The final on-disk file is clean and openable with data intact.
    @Test
    func concurrentConvergeSerializesWithoutDoubleConvertOrCorruption() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = self.tempDir()
            OsaurusPaths.overrideRoot = root
            let k = self.key(seed: 0x6B)
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared._setKeyForTesting(k)

            let path = OsaurusPaths.memoryDatabaseFile().path
            try self.seedDB(at: path, key: nil, body: "concurrent")

            let reports = await withTaskGroup(
                of: StorageMigrationCoordinator.Report.self
            ) { group -> [StorageMigrationCoordinator.Report] in
                for _ in 0 ..< 6 {
                    group.addTask {
                        await StorageMigrationCoordinator.shared.converge(to: .encrypted)
                    }
                }
                var out: [StorageMigrationCoordinator.Report] = []
                for await r in group { out.append(r) }
                return out
            }

            // Converted exactly once across all callers — never double, never
            // corrupted into a failure.
            #expect(reports.reduce(0) { $0 + $1.converted } == 1)
            #expect(reports.allSatisfy { $0.failed.isEmpty })

            #expect(StorageFileFormat.detect(path: path) == .encrypted)
            let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
            #expect(self.readSingleText(conn, "SELECT body FROM notes LIMIT 1") == "concurrent")
            sqlite3_close(conn)
        }
    }

    // MARK: - R3: bounded FileVault probe

    /// The probe's timeout primitive returns `false` promptly when its work
    /// outruns the timeout (a wedged `fdesetup` must not stall launch).
    @Test
    func probeTimeoutReturnsFalsePromptlyOnSlowWork() {
        let start = Date()
        let finished = FileVaultStatus.runWithTimeout(.milliseconds(100)) {
            Thread.sleep(forTimeInterval: 1.0)
        }
        #expect(finished == false)
        // Returned at the timeout, not after the full 1s of work.
        #expect(Date().timeIntervalSince(start) < 0.8)
    }

    /// Work that finishes within the budget reports success.
    @Test
    func probeTimeoutReturnsTrueWhenWorkFinishesInTime() {
        #expect(FileVaultStatus.runWithTimeout(.seconds(2)) {} == true)
    }

    // MARK: - R5: swap ordering

    /// After conversion the new file is in place and openable with its data,
    /// and neither the previous-format sidecars nor the converter's temp file
    /// linger (replace-first, then sidecar cleanup).
    @Test
    func swapLeavesNoTempOrStaleSidecarsAndKeepsDataReadable() throws {
        let path = tempDBPath()
        let k = key(seed: 0x5A)
        try seedDB(at: path, key: nil, body: "r5")
        // Stale WAL/SHM from the plaintext file's life.
        FileManager.default.createFile(atPath: path + "-wal", contents: Data([0x1]))
        FileManager.default.createFile(atPath: path + "-shm", contents: Data([0x2]))

        try StorageFormatConverter.encryptInPlace(path: path, key: k)

        #expect(StorageFileFormat.detect(path: path) == .encrypted)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
        #expect(readSingleText(conn, "SELECT body FROM notes LIMIT 1") == "r5")
        sqlite3_close(conn)

        #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: path + "-shm") == false)
        #expect(FileManager.default.fileExists(atPath: path + ".encrypted.tmp") == false)
        #expect(FileManager.default.fileExists(atPath: path + ".plaintext.tmp") == false)
    }

    // MARK: - Disk-space pre-flight (rollout safety)

    /// The pre-flight never blocks when it can't measure a real size (missing
    /// file) and passes a tiny real DB on any normal test volume.
    @Test
    func hasRoomToConvertUsesSafeDefaults() throws {
        let missing = tempDBPath("missing.sqlite")
        #expect(StorageMigrationCoordinator.hasRoomToConvert(path: missing) == true)

        let small = tempDBPath()
        try seedDB(at: small, key: nil, body: "tiny")
        #expect(StorageMigrationCoordinator.hasRoomToConvert(path: small) == true)
    }
}
