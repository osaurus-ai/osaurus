//
//  StorageFormatConverter.swift
//  osaurus
//
//  In-place conversion of a single SQLite database between plaintext and
//  SQLCipher-encrypted form, using SQLCipher's `sqlcipher_export`. Mirrors
//  the proven ATTACH/export dance in `StorageExportService` but writes the
//  result back over the original file atomically.
//
//  Both directions:
//    1. Open the source connection (encrypted needs the key; plaintext none).
//    2. ATTACH a fresh sibling DB in the *target* format and
//       `SELECT sqlcipher_export(...)` into it.
//    3. Close the source, verify the temp file's on-disk format, then
//       atomically replace the original and drop stale `-wal`/`-shm`.
//
//  The temp file is always cleaned up on failure, so a crashed/aborted run
//  leaves the original untouched and detection-first open still works.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import os

public enum StorageConversionError: LocalizedError {
    case openFailed(String)
    case keyVerificationFailed(String)
    case exportFailed(String)
    case verifyFailed(String)
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Storage conversion open failed: \(m)"
        case .keyVerificationFailed(let m): return "Storage conversion key verification failed: \(m)"
        case .exportFailed(let m): return "Storage conversion export failed: \(m)"
        case .verifyFailed(let m): return "Storage conversion verification failed: \(m)"
        case .replaceFailed(let m): return "Storage conversion replace failed: \(m)"
        }
    }
}

public enum StorageFormatConverter {
    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.convert")

    private static let cipherPragmas = [
        "PRAGMA cipher_memory_security = OFF",
        "PRAGMA cipher_page_size = 4096",
        "PRAGMA kdf_iter = 256000",
    ]

    private static func keyHex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    private static func sqlEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Public conversions

    /// Decrypt the SQLCipher database at `path` to a plaintext SQLite file in
    /// place. No-op when the file is already plaintext or empty.
    public static func decryptInPlace(path: String, key: SymmetricKey) throws {
        guard StorageFileFormat.detect(path: path) == .encrypted else { return }
        let tmp = path + ".plaintext.tmp"
        StorageFile.remove(path: tmp)
        do {
            try exportEncryptedToPlaintext(srcPath: path, key: key, dstPath: tmp)
            guard StorageFileFormat.detect(path: tmp) == .plaintext else {
                throw StorageConversionError.verifyFailed("export did not produce a plaintext file")
            }
            try swap(from: tmp, to: path)
        } catch {
            StorageFile.remove(path: tmp)
            throw error
        }
        log.info("decrypted \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
    }

    /// Encrypt the plaintext SQLite database at `path` to SQLCipher form in
    /// place. No-op when the file is already encrypted or empty.
    public static func encryptInPlace(path: String, key: SymmetricKey) throws {
        guard StorageFileFormat.detect(path: path) == .plaintext else { return }
        let tmp = path + ".encrypted.tmp"
        StorageFile.remove(path: tmp)
        do {
            try exportPlaintextToEncrypted(srcPath: path, key: key, dstPath: tmp)
            guard StorageFileFormat.detect(path: tmp) == .encrypted else {
                throw StorageConversionError.verifyFailed("export did not produce an encrypted file")
            }
            try swap(from: tmp, to: path)
        } catch {
            StorageFile.remove(path: tmp)
            throw error
        }
        log.info("encrypted \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
    }

    // MARK: - General export primitive

    /// Copy a SQLite database from `srcPath` (opened with `srcKey`, nil =
    /// plaintext) into a freshly-created `dstPath` in the format implied by
    /// `dstKey` (nil = plaintext, otherwise SQLCipher), via `sqlcipher_export`.
    ///
    /// The destination must not already exist (callers use a temp path).
    /// Powers in-place conversion here and agent-bundle import/export, which
    /// move data across arbitrary keys/postures.
    static func export(
        from srcPath: String,
        srcKey: SymmetricKey?,
        to dstPath: String,
        dstKey: SymmetricKey?
    ) throws {
        var srcDB: OpaquePointer?
        guard sqlite3_open(srcPath, &srcDB) == SQLITE_OK, let src = srcDB else {
            let m = String(cString: sqlite3_errmsg(srcDB))
            sqlite3_close(srcDB)
            throw StorageConversionError.openFailed(m)
        }
        defer { sqlite3_close(src) }

        if let srcKey {
            if sqlite3_exec(src, "PRAGMA key = \"x'\(keyHex(srcKey))'\"", nil, nil, nil) != SQLITE_OK {
                throw StorageConversionError.openFailed("PRAGMA key")
            }
            for pragma in cipherPragmas { _ = sqlite3_exec(src, pragma, nil, nil, nil) }
        }
        // Force a decrypt/read so a wrong key (or non-DB) fails here.
        if sqlite3_exec(src, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            let m = String(cString: sqlite3_errmsg(src))
            throw srcKey == nil
                ? StorageConversionError.openFailed(m)
                : StorageConversionError.keyVerificationFailed(m)
        }

        let attachKeyLiteral = dstKey.map { "x'\(keyHex($0))'" } ?? ""
        let attach =
            "ATTACH DATABASE '\(sqlEscape(dstPath))' AS conv KEY \"\(attachKeyLiteral)\""
        if sqlite3_exec(src, attach, nil, nil, nil) != SQLITE_OK {
            throw StorageConversionError.exportFailed("attach: \(String(cString: sqlite3_errmsg(src)))")
        }
        defer { _ = sqlite3_exec(src, "DETACH DATABASE conv", nil, nil, nil) }

        if dstKey != nil {
            // Match the runtime opener's cipher posture (also the SQLCipher 4
            // defaults, so the file stays openable even if a schema-qualified
            // PRAGMA is ignored on the attach).
            for pragma in ["PRAGMA conv.cipher_page_size = 4096", "PRAGMA conv.kdf_iter = 256000"] {
                _ = sqlite3_exec(src, pragma, nil, nil, nil)
            }
        }
        if sqlite3_exec(src, "SELECT sqlcipher_export('conv')", nil, nil, nil) != SQLITE_OK {
            throw StorageConversionError.exportFailed(String(cString: sqlite3_errmsg(src)))
        }
    }

    private static func exportEncryptedToPlaintext(srcPath: String, key: SymmetricKey, dstPath: String) throws {
        try export(from: srcPath, srcKey: key, to: dstPath, dstKey: nil)
    }

    private static func exportPlaintextToEncrypted(srcPath: String, key: SymmetricKey, dstPath: String) throws {
        try export(from: srcPath, srcKey: nil, to: dstPath, dstKey: key)
    }

    // MARK: - Atomic swap

    /// Atomically replace `dst` with `src`, then drop the previous format's
    /// stale `-wal`/`-shm` so they can't re-attach to the freshly swapped file.
    ///
    /// The replace happens FIRST: deleting `dst`'s sidecars beforehand left a
    /// (tiny) crash window where the original had already lost its WAL but had
    /// not yet been replaced. Convergence holds the `StorageMutationGate` across
    /// this whole call, so nothing can open `dst` between the replace and the
    /// sidecar cleanup — re-attach is still impossible, but the window is gone.
    private static func swap(from src: String, to dst: String) throws {
        let fm = FileManager.default
        let dstURL = URL(fileURLWithPath: dst)
        let srcURL = URL(fileURLWithPath: src)
        do {
            if fm.fileExists(atPath: dst) {
                _ = try fm.replaceItemAt(dstURL, withItemAt: srcURL)
            } else {
                try fm.moveItem(at: srcURL, to: dstURL)
            }
        } catch {
            throw StorageConversionError.replaceFailed(error.localizedDescription)
        }
        // Now that the new file is in place, drop the old (previous-format)
        // sidecars left next to `dst` and any sidecars the export produced
        // next to `src`.
        StorageFile.removeSidecars(for: dst)
        StorageFile.removeSidecars(for: src)
    }
}
