//
//  OsaurusStorageOpener.swift
//  osaurus
//
//  The single chokepoint every on-disk `*Database` uses to open its
//  connection. It chooses plaintext vs encrypted *from the file's actual
//  on-disk format* (detection-first), falling back to the user's desired
//  `StorageEncryptionPolicy` mode only for brand-new/empty files.
//
//  Why detection-first matters: in the default (plaintext) world this never
//  calls `StorageKeyManager.currentKey()`, so a missing/locked Keychain key
//  can no longer brick a store. An existing encrypted file is still opened
//  with the key until the launch-time migration converges it to plaintext.
//

import CryptoKit
import Foundation

public enum OsaurusStorageOpener {
    /// Open a storage database at `path`, selecting the key based on the
    /// file's detected format and the desired policy mode.
    public static func open(
        path: String,
        applyPerfPragmas: Bool = true,
        applyForeignKeys: Bool = true
    ) throws -> OpaquePointer {
        let key = try resolveKey(for: path)
        return try EncryptedSQLiteOpener.open(
            path: path,
            key: key,
            applyPerfPragmas: applyPerfPragmas,
            applyForeignKeys: applyForeignKeys
        )
    }

    /// Decide whether `path` needs an encryption key to open:
    ///   - existing plaintext file -> `nil` (never touches the Keychain)
    ///   - existing encrypted file -> the current DEK (may throw if locked)
    ///   - new/empty file          -> follows the desired policy mode
    public static func resolveKey(for path: String) throws -> SymmetricKey? {
        switch StorageFileFormat.detect(path: path) {
        case .plaintext:
            return nil
        case .encrypted:
            return try StorageKeyManager.shared.currentKey()
        case .empty:
            switch StorageEncryptionPolicy.shared.desiredMode() {
            case .plaintext:
                return nil
            case .encrypted:
                return try StorageKeyManager.shared.currentKey()
            }
        }
    }
}
