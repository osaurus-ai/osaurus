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
//       silently mismatches the migrator)
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
//  Encryption can be skipped (in-memory test DBs, the migrator
//  reading legacy plaintext, etc.) by passing `key: nil`.
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
    ///           is opened plaintext (used by the migrator + tests).
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
    /// The migrator (`StorageMigrator.migrateOneDatabase`) writes
    /// every encrypted database with the raw-key form via
    /// `ATTACH DATABASE … KEY "x'<hex>'"`, so every open MUST also
    /// use the raw-key form or HMAC verification fails on page 1.
    /// Using `sqlite3_key_v2` with the raw 32 bytes is the
    /// pre-fix bug that produced
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

    // MARK: - Detection

    /// Returns true when the file at `path` looks like a SQLCipher
    /// database (cannot be opened with `key=nil` as a plaintext SQLite).
    /// Used by the migrator to skip already-encrypted files.
    public static func isEncryptedDatabase(path: String) -> Bool {
        var dbPointer: OpaquePointer?
        let result = sqlite3_open(path, &dbPointer)
        defer { sqlite3_close(dbPointer) }
        guard result == SQLITE_OK, let connection = dbPointer else { return false }

        // A plaintext SQLite file always succeeds at reading sqlite_master
        // without a key. An encrypted file fails with SQLITE_NOTADB.
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        if prepared != SQLITE_OK { return true }
        let step = sqlite3_step(stmt)
        return step != SQLITE_ROW
    }
}
