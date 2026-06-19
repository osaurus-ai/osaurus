//
//  StorageFileFormat.swift
//  osaurus
//
//  Deterministic on-disk format detection for Osaurus SQLite databases.
//
//  A plaintext SQLite 3 file always begins with the fixed 16-byte magic
//  string "SQLite format 3\0". A SQLCipher-encrypted file encrypts page 1
//  (header included), so its first bytes are indistinguishable from random
//  and never match that magic.
//
//  This lets the storage layer pick the correct open path *from the file
//  itself* rather than from a flag that can drift out of sync — the
//  cornerstone of the "a missing key can never brick a plaintext store"
//  reliability guarantee. See `OsaurusStorageOpener`.
//

import Foundation

public enum StorageFileFormat: Equatable, Sendable {
    /// File is missing or zero-length — caller should create it in the
    /// policy's desired mode.
    case empty
    /// File starts with the SQLite 3 magic header — open plaintext.
    case plaintext
    /// Non-empty file without the SQLite magic — assume SQLCipher.
    case encrypted

    /// The 16-byte magic prefix of every plaintext SQLite 3 database.
    /// ("SQLite format 3" + a trailing NUL byte.)
    static let sqliteMagic: [UInt8] = Array("SQLite format 3\u{0}".utf8)

    /// Inspect the first 16 bytes of `path` to classify its format.
    ///
    /// Never throws: an unreadable or short file is treated as `.empty`
    /// (recreate per policy) unless it is non-empty-but-not-plaintext, in
    /// which case it is assumed `.encrypted` so we still attempt the key.
    public static func detect(path: String) -> StorageFileFormat {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return .empty
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            // Exists but unreadable (permissions). Don't claim plaintext;
            // let the encrypted path try the key and surface a real error.
            return .encrypted
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if head.isEmpty { return .empty }
        if head.count >= 16, Array(head) == sqliteMagic { return .plaintext }
        return .encrypted
    }

    /// Convenience: true when the file is a SQLCipher-encrypted database.
    public static func isEncrypted(path: String) -> Bool {
        detect(path: path) == .encrypted
    }
}
