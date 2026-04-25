//
//  StorageKeyManager.swift
//  osaurus
//
//  Manages the data-encryption key (DEK) used for at-rest encryption of
//  Osaurus's SQLite databases (via SQLCipher), VecturaKit indexes, JSON
//  configuration, archived sessions, and spilled attachment blobs.
//
//  The DEK is a 32-byte raw `SymmetricKey` stored in the macOS Keychain
//  with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Unlike the
//  Identity master key, the DEK is **not** biometric-gated — every app
//  launch and every background task needs to open the DBs without a
//  prompt. By default the DEK is a fresh `CSPRNG` 32-byte key persisted
//  to Keychain. An opt-in mode (`deriveFromMasterKey:`) replaces it
//  with `HKDF<SHA256>(masterKeyBytes, salt, info)` so the DEK is
//  reproducible alongside iCloud-synced identity for users who want
//  cross-device portability. That opt-in path requires a one-time
//  biometric prompt from `MasterKey.getPrivateKey`.
//
//  Design notes:
//  - We never write the master key out, only the derived DEK.
//  - The HKDF salt is stored alongside in plaintext (`~/.osaurus/.storage-key.salt`);
//    by itself it leaks nothing because HKDF without the master key is
//    not invertible.
//  - Once retrieved, the DEK is cached in-process; `wipeCache()` zeroes
//    the raw bytes on app shutdown.
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import os

public enum StorageKeyError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case derivationFailed
    case randomFailed
    case rotationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let s): return "Failed to write storage key to Keychain (status \(s))"
        case .keychainReadFailed(let s): return "Failed to read storage key from Keychain (status \(s))"
        case .derivationFailed: return "Failed to derive storage key from master key"
        case .randomFailed: return "Failed to generate cryptographically secure random bytes"
        case .rotationFailed(let m): return "Storage key rotation failed: \(m)"
        }
    }
}

/// Manages the symmetric data-encryption key used for at-rest encryption.
///
/// Threadsafe: backed by an unfair lock; the in-memory cached key is only
/// mutated under the lock. The first `currentKey()` call performs the
/// (potentially expensive) Keychain read + HKDF derivation; subsequent
/// calls return the cached value without IO.
public final class StorageKeyManager: @unchecked Sendable {
    public static let shared = StorageKeyManager()

    static let service = "com.osaurus.storage"
    static let keyAccount = "data-encryption-key"
    static let saltAccount = "data-encryption-salt"

    /// Domain-separation tag used in HKDF for v1 of the storage key
    /// derivation. Bumping requires a key rotation.
    static let hkdfInfo = Data("osaurus-storage-v1".utf8)

    /// Filename for the persisted salt (lives next to the encrypted
    /// artifacts so it travels with `~/.osaurus/`). Without the master
    /// key in Keychain the salt is useless.
    private static let saltFilename = ".storage-key.salt"

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.key")

    private var lock = os_unfair_lock_s()
    private var cachedKey: SymmetricKey?

    private init() {}

    // MARK: - Public API

    /// Returns the current data-encryption key, generating + persisting
    /// one on first call. Throws on Keychain or derivation failure.
    public func currentKey() throws -> SymmetricKey {
        os_unfair_lock_lock(&lock)
        if let cached = cachedKey {
            os_unfair_lock_unlock(&lock)
            return cached
        }
        os_unfair_lock_unlock(&lock)

        let key: SymmetricKey
        if let existing = try readKeychainKey() {
            key = SymmetricKey(data: existing)
        } else {
            key = try generateAndPersistKey()
        }

        os_unfair_lock_lock(&lock)
        cachedKey = key
        os_unfair_lock_unlock(&lock)
        return key
    }

    /// Returns true when a persisted key exists in Keychain. Cheap; no
    /// Touch ID prompt.
    public func keyExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.keyAccount,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Generate a new key, replacing the existing one. Caller is
    /// responsible for re-keying SQLCipher databases and re-wrapping
    /// `.osec` files. The cached key is updated atomically.
    public func rotate() throws -> SymmetricKey {
        let key = try generateAndPersistKey(forceFresh: true)
        os_unfair_lock_lock(&lock)
        cachedKey = key
        os_unfair_lock_unlock(&lock)
        return key
    }

    /// Atomically replace the cached + Keychain-persisted key with a
    /// caller-provided one. Used by `StorageExportService.rotateStorageKey`
    /// after it re-encrypts every artifact under the new key — we
    /// can't call `rotate()` because that would generate a *third*
    /// unrelated key.
    public func install(key: SymmetricKey) throws {
        let bytes = key.withUnsafeBytes { Data($0) }
        try persistKeychain(data: bytes)
        os_unfair_lock_lock(&lock)
        cachedKey = key
        os_unfair_lock_unlock(&lock)
    }

    /// Replace the current DEK with one deterministically derived from
    /// the Identity master key. **Triggers biometric prompt** because
    /// it must read the master key bytes. Use only as an explicit
    /// opt-in when the user wants their encrypted storage to be
    /// reproducible on another device with the same iCloud Keychain
    /// (and thus the same master key).
    public func deriveFromMasterKey(context: LAContext) throws -> SymmetricKey {
        guard MasterKey.exists() else {
            throw StorageKeyError.derivationFailed
        }
        var masterBytes = try MasterKey.getPrivateKey(context: context)
        defer {
            masterBytes.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                memset(base, 0, ptr.count)
            }
        }

        let salt = try fetchOrCreateSalt()
        let inputKey = SymmetricKey(data: masterBytes)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Self.hkdfInfo,
            outputByteCount: 32
        )
        let derivedBytes = derived.withUnsafeBytes { Data($0) }
        try persistKeychain(data: derivedBytes)

        let key = SymmetricKey(data: derivedBytes)
        os_unfair_lock_lock(&lock)
        cachedKey = key
        os_unfair_lock_unlock(&lock)
        log.info("Storage key re-derived from master key (HKDF-SHA256)")
        return key
    }

    /// Best-effort destruction of the in-memory cached key.
    public func wipeCache() {
        os_unfair_lock_lock(&lock)
        cachedKey = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Wipes both the in-memory cache and the Keychain entry. Intended
    /// for "Reset encrypted storage" in Settings or onboarding wipe.
    /// **Irreversible.** Caller is responsible for moving any encrypted
    /// data out first if it should be preserved.
    public func resetForWipe() {
        let queries: [[String: Any]] = [
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.keyAccount,
            ],
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.saltAccount,
            ],
        ]
        for q in queries {
            _ = SecItemDelete(q as CFDictionary)
        }
        try? FileManager.default.removeItem(at: saltFile())
        wipeCache()
    }

    // MARK: - Internal helpers

    private func generateAndPersistKey(forceFresh: Bool = false) throws -> SymmetricKey {
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else {
            throw StorageKeyError.randomFailed
        }
        let keyBytes = Data(raw)
        for i in raw.indices { raw[i] = 0 }
        try persistKeychain(data: keyBytes)
        log.info("Storage key generated (\(forceFresh ? "rotated" : "first-run")) and persisted")
        return SymmetricKey(data: keyBytes)
    }

    /// Fetch the persisted HKDF salt or create a fresh one. We persist
    /// to **both** Keychain and a sidecar file so neither single delete
    /// breaks reproducibility.
    private func fetchOrCreateSalt() throws -> Data {
        if let s = try readKeychainSalt() {
            try? writeSaltSidecar(s)
            return s
        }
        if let s = readSaltSidecar() {
            try? persistKeychainSalt(s)
            return s
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
            throw StorageKeyError.randomFailed
        }
        let salt = Data(bytes)
        try persistKeychainSalt(salt)
        try? writeSaltSidecar(salt)
        return salt
    }

    private func saltFile() -> URL {
        OsaurusPaths.root().appendingPathComponent(Self.saltFilename)
    }

    private func writeSaltSidecar(_ data: Data) throws {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        try data.write(to: saltFile(), options: [.atomic])
    }

    private func readSaltSidecar() -> Data? {
        let url = saltFile()
        return try? Data(contentsOf: url)
    }

    // MARK: - Keychain (key)

    private func persistKeychain(data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.keyAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Osaurus Storage Encryption Key",
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            log.error("Storage key SecItemUpdate failed: \(updateStatus)")
        }

        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StorageKeyError.keychainWriteFailed(addStatus)
        }
    }

    private func readKeychainKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw StorageKeyError.keychainReadFailed(status) }
        return result as? Data
    }

    // MARK: - Keychain (salt)

    private func persistKeychainSalt(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.saltAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Osaurus Storage Key Derivation Salt",
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StorageKeyError.keychainWriteFailed(status)
        }
    }

    private func readKeychainSalt() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.saltAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw StorageKeyError.keychainReadFailed(status) }
        return result as? Data
    }
}

// MARK: - Test injection

#if DEBUG
    extension StorageKeyManager {
        /// Inject a deterministic key for tests. Only available in DEBUG.
        /// Bypasses Keychain entirely.
        public func _setKeyForTesting(_ key: SymmetricKey) {
            os_unfair_lock_lock(&lock)
            cachedKey = key
            os_unfair_lock_unlock(&lock)
        }
    }
#endif
