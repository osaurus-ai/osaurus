//
//  EncryptedSQLiteOpener.swift
//  osaurus
//
//  Centralizes the (vendored) SQLCipher open-and-key dance + the
//  PRAGMAs every Osaurus database wants. All five `*Database` classes
//  delegate to this so the encryption posture is consistent and
//  auditable in one file.
//
//  Sequence (matches SQLCipher's required order — cipher_* PRAGMAs
//  must run BEFORE the first non-PRAGMA read):
//    1. sqlite3_open(path)
//    2. sqlite3_key_v2(db, nil, "x'<64-hex>'", 67)   (raw-key form;
//       see `rawKeyBlob` doc — anything else triggers PBKDF2 and
//       silently mismatches the stored key)
//    3. PRAGMA cipher_memory_security = OFF   (perf, OS already protects)
//    4. PRAGMA cipher_page_size = 4096
//    5. PRAGMA kdf_iter = 256000              (SQLCipher 4 default)
//    6. SELECT count(*) FROM sqlite_master    (verification — fails on bad key)
//    7. PRAGMA journal_mode = WAL
//    8. PRAGMA synchronous = NORMAL
//    9. PRAGMA temp_store = MEMORY
//   10. PRAGMA cache_size = -20000            (~20 MB)
//   11. PRAGMA foreign_keys = ON
//
//  Encryption can be skipped (in-memory test DBs, plaintext export,
//  etc.) by passing `key: nil`.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum EncryptedSQLiteError: Error, LocalizedError {
    case openFailed(String)
    case keyVerificationFailed(String)
    case pragmaFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "SQLCipher open failed: \(m)"
        case .keyVerificationFailed(let m): return "SQLCipher key verification failed: \(m)"
        case .pragmaFailed(let m): return "SQLCipher PRAGMA failed: \(m)"
        }
    }
}

public enum EncryptedSQLiteOpener {
    /// Open a (potentially encrypted) SQLite database at `path` and
    /// return its connection. Caller is responsible for `sqlite3_close`.
    ///
    /// - Parameters:
    ///   - path: Filesystem path or `:memory:`.
    ///   - key:  Optional 32-byte encryption key. When `nil`, the DB
    ///           is opened plaintext (used by plaintext export + tests).
    ///   - applyPerfPragmas: When true, sets WAL/synchronous/cache/temp PRAGMAs.
    ///   - applyForeignKeys: When true, sets `PRAGMA foreign_keys = ON`.
    public static func open(
        path: String,
        key: SymmetricKey?,
        applyPerfPragmas: Bool = true,
        applyForeignKeys: Bool = true
    ) throws -> OpaquePointer {
        var dbPointer: OpaquePointer?
        let openResult = sqlite3_open(path, &dbPointer)
        guard openResult == SQLITE_OK, let connection = dbPointer else {
            let msg = String(cString: sqlite3_errmsg(dbPointer))
            sqlite3_close(dbPointer)
            throw EncryptedSQLiteError.openFailed(msg)
        }

        if let key {
            try applyKey(connection: connection, key: key)
            try applyCipherPragmas(connection: connection)
            try verifyKey(connection: connection)
        }

        if applyPerfPragmas {
            try executePragma(connection, "PRAGMA journal_mode = WAL")
            try executePragma(connection, "PRAGMA synchronous = NORMAL")
            try executePragma(connection, "PRAGMA temp_store = MEMORY")
            try executePragma(connection, "PRAGMA cache_size = -20000")
        }
        if applyForeignKeys {
            try executePragma(connection, "PRAGMA foreign_keys = ON")
        }

        return connection
    }

    /// Open an encrypted DB, self-healing a file that cannot be decrypted
    /// with `key`. When the file exists but SQLCipher reports a
    /// key-verification failure (wrong/rotated key or first-page
    /// corruption — `SQLITE_NOTADB` / "file is not a database"), the dead
    /// file and its `-wal`/`-shm` sidecars are renamed aside to
    /// `<name>.orphaned-<epoch><suffix>` and a fresh encrypted DB is
    /// created with `key`. The caller's schema migrations then run against
    /// the new empty file, so the subsystem returns to service instead of
    /// staying permanently disabled.
    ///
    /// Recovery fires ONLY on `.keyVerificationFailed`. Transient failures
    /// (`.openFailed` — couldn't even open the handle) and PRAGMA failures
    /// are rethrown untouched, so a locked Keychain or busy file never
    /// triggers a destructive quarantine. Callers must therefore confirm
    /// the key is actually available (e.g. a sibling DB opened) before
    /// trusting recovery to mean "the old data was unrecoverable anyway".
    ///
    /// - Returns: the connection plus `recovered = true` when a quarantine
    ///   happened, so the caller can record it for `/health`.
    public static func openRecoveringUndecryptable(
        path: String,
        key: SymmetricKey,
        applyPerfPragmas: Bool = true,
        applyForeignKeys: Bool = true
    ) throws -> (connection: OpaquePointer, recovered: Bool) {
        do {
            let connection = try open(
                path: path, key: key,
                applyPerfPragmas: applyPerfPragmas, applyForeignKeys: applyForeignKeys
            )
            return (connection, false)
        } catch let error as EncryptedSQLiteError {
            guard case .keyVerificationFailed = error else { throw error }
            // The file exists but cannot be decrypted with the current key.
            // Quarantine it (preserving the bytes) and create a fresh DB.
            try quarantineUndecryptable(path: path)
            let connection = try open(
                path: path, key: key,
                applyPerfPragmas: applyPerfPragmas, applyForeignKeys: applyForeignKeys
            )
            return (connection, true)
        }
    }

    /// Rename an undecryptable database file and its WAL/SHM sidecars aside
    /// so a fresh DB can be created in its place. The main file MUST move
    /// (else we'd recreate on top of an unreadable file); sidecars are
    /// worthless without it, so if one can't be moved it is deleted.
    private static func quarantineUndecryptable(path: String) throws {
        let fm = FileManager.default
        let stamp = String(Int(Date().timeIntervalSince1970))
        for suffix in ["", "-wal", "-shm"] {
            let source = path + suffix
            guard fm.fileExists(atPath: source) else { continue }
            let dest = path + ".orphaned-" + stamp + suffix
            try? fm.removeItem(atPath: dest)
            do {
                try fm.moveItem(atPath: source, toPath: dest)
            } catch {
                if suffix.isEmpty { throw error }
                try? fm.removeItem(atPath: source)
            }
        }
    }

    /// Re-key an already-open SQLCipher database. Used by `rotate()`
    /// in `StorageKeyManager` and by tests. Wrong source key throws.
    public static func rekey(connection: OpaquePointer, newKey: SymmetricKey) throws {
        let blob = rawKeyBlob(newKey)
        let result = blob.withCString { ptr in
            sqlite3_rekey_v2(connection, nil, ptr, Int32(blob.utf8.count))
        }
        guard result == SQLITE_OK else {
            throw EncryptedSQLiteError.keyVerificationFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    // MARK: - Internals

    /// CRITICAL: SQLCipher's `sqlite3_key_v2` API accepts EITHER a
    /// passphrase OR a raw key blob. The discriminator is the
    /// **byte content** of the key argument:
    ///
    ///   - 32 raw bytes from `SecRandomCopyBytes` → SQLCipher treats
    ///     them as a passphrase and runs PBKDF2(key, salt, kdf_iter).
    ///   - The literal ASCII string `x'<64-hex>'` (67 bytes) →
    ///     SQLCipher interprets it as a raw 256-bit key, NO PBKDF2.
    ///
    /// Every encrypted database is keyed with the raw-key form, so
    /// every open MUST also use the raw-key form or HMAC verification
    /// fails on page 1. Using `sqlite3_key_v2` with the raw 32 bytes
    /// is the pre-fix bug that produced
    ///     ERROR CORE sqlcipher_page_cipher: hmac check failed for pgno=1
    /// even though the Keychain bytes hadn't changed.
    private static func rawKeyBlob(_ key: SymmetricKey) -> String {
        let hex = key.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
        return "x'\(hex)'"
    }

    private static func applyKey(connection: OpaquePointer, key: SymmetricKey) throws {
        let blob = rawKeyBlob(key)
        let result = blob.withCString { ptr in
            sqlite3_key_v2(connection, nil, ptr, Int32(blob.utf8.count))
        }
        guard result == SQLITE_OK else {
            throw EncryptedSQLiteError.openFailed("sqlite3_key_v2 returned \(result)")
        }
    }

    private static func applyCipherPragmas(connection: OpaquePointer) throws {
        // Order matters. cipher_memory_security off gives a meaningful
        // perf win and is acceptable for an OS-protected user-mode app.
        try executePragma(connection, "PRAGMA cipher_memory_security = OFF")
        try executePragma(connection, "PRAGMA cipher_page_size = 4096")
        // SQLCipher 4 default. We can't lower it on existing DBs
        // (the iteration count is burned into the file header and
        // must match on open), so the launch-time PBKDF2 cost is
        // instead capped upstream by lazy-opening per-plugin DBs
        // — see `PluginHostAPI.ensureDatabaseOpen()`. A future v3
        // `PRAGMA rekey` migration could drop this to ~4000 if we
        // want broader startup speedup; our key is a 256-bit
        // CSPRNG output so PBKDF2 stretching is overhead, not
        // protection.
        try executePragma(connection, "PRAGMA kdf_iter = 256000")
    }

    private static func verifyKey(connection: OpaquePointer) throws {
        // Reading sqlite_master forces SQLCipher to decrypt page 1.
        // If the key is wrong (or the file is plaintext), we get
        // SQLITE_NOTADB / SQLITE_ERROR here rather than later in a
        // surprising place.
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
        if result != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(connection))
            throw EncryptedSQLiteError.keyVerificationFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(connection))
            throw EncryptedSQLiteError.keyVerificationFailed(msg)
        }
    }

    @discardableResult
    private static func executePragma(_ connection: OpaquePointer, _ sql: String) throws -> Int32 {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let msg = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw EncryptedSQLiteError.pragmaFailed("\(sql): \(msg)")
        }
        return rc
    }
}
