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
    private var cachedReadFailureStatus: OSStatus?
    private let keychainQueue = DispatchQueue(label: "ai.osaurus.storage-key.keychain")

    private init() {}

    // MARK: - Public API

    /// Live proof/test launches can set this to avoid reading or writing the
    /// user's login Keychain. Production launches leave it unset.
    public static var disablesKeychainForProcess: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"] == "1"
    }

    /// Returns the current data-encryption key, generating + persisting
    /// one on first call. Throws on Keychain or derivation failure.
    public func currentKey() throws -> SymmetricKey {
        os_unfair_lock_lock(&lock)
        if let cached = cachedKey {
            os_unfair_lock_unlock(&lock)
            return cached
        }
        if let cachedFailure = cachedReadFailureStatus {
            os_unfair_lock_unlock(&lock)
            throw StorageKeyError.keychainReadFailed(cachedFailure)
        }
        os_unfair_lock_unlock(&lock)

        return try keychainQueue.sync {
            os_unfair_lock_lock(&lock)
            if let cached = cachedKey {
                os_unfair_lock_unlock(&lock)
                return cached
            }
            if let cachedFailure = cachedReadFailureStatus {
                os_unfair_lock_unlock(&lock)
                throw StorageKeyError.keychainReadFailed(cachedFailure)
            }
            os_unfair_lock_unlock(&lock)

            let key: SymmetricKey
            if Self.disablesKeychainForProcess {
                key = try generateInMemoryKey()
            } else if let existing = try readKeychainKey() {
                key = SymmetricKey(data: existing)
            } else {
                key = try generateAndPersistKey()
            }

            os_unfair_lock_lock(&lock)
            cachedKey = key
            cachedReadFailureStatus = nil
            os_unfair_lock_unlock(&lock)
            return key
        }
    }

    /// True only when the key is already resident in this process. This never
    /// touches Keychain, so startup/UI code can fail closed without prompting.
    public var hasCachedKey: Bool {
        os_unfair_lock_lock(&lock)
        let cached = cachedKey != nil
        os_unfair_lock_unlock(&lock)
        return cached
    }

    /// Populate the in-process key cache before storage database queues start
    /// opening. This keeps later `currentKey()` calls off the slow Keychain path.
    public func prewarmCurrentKey() throws {
        _ = try currentKey()
    }

    /// Prewarm from a libdispatch worker instead of pinning a Swift
    /// cooperative-executor thread inside synchronous Keychain APIs.
    public func prewarmCurrentKeyOffCooperativeExecutor() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.prewarmCurrentKey()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns true when a persisted key exists in Keychain. Cheap; no
    /// Touch ID prompt.
    public func keyExists() -> Bool {
        if Self.disablesKeychainForProcess {
            return hasCachedKey
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.keyAccount,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        if SecItemCopyMatching(KeychainQueryHelpers.dataProtection(base) as CFDictionary, nil) == errSecSuccess {
            return true
        }
        return SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess
    }

    /// Generate a new key, replacing the existing one. Caller is
    /// responsible for re-keying SQLCipher databases and re-wrapping
    /// `.osec` files. The cached key is updated atomically.
    public func rotate() throws -> SymmetricKey {
        let key = try generateAndPersistKey(forceFresh: true)
        os_unfair_lock_lock(&lock)
        cachedKey = key
        cachedReadFailureStatus = nil
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
        if !Self.disablesKeychainForProcess {
            try persistKeychain(data: bytes)
        }
        os_unfair_lock_lock(&lock)
        cachedKey = key
        cachedReadFailureStatus = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Replace the current DEK with one deterministically derived from
    /// the Identity master key. **Triggers biometric prompt** because
    /// it must read the master key bytes. Use only as an explicit
    /// opt-in when the user wants their encrypted storage to be
    /// reproducible on another device with the same iCloud Keychain
    /// (and thus the same master key).
    public func deriveFromMasterKey(context: LAContext) throws -> SymmetricKey {
        if Self.disablesKeychainForProcess {
            let key = try generateInMemoryKey()
            os_unfair_lock_lock(&lock)
            cachedKey = key
            cachedReadFailureStatus = nil
            os_unfair_lock_unlock(&lock)
            return key
        }
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
        cachedReadFailureStatus = nil
        os_unfair_lock_unlock(&lock)
        log.info("Storage key re-derived from master key (HKDF-SHA256)")
        return key
    }

    /// Best-effort destruction of the in-memory cached key.
    public func wipeCache() {
        os_unfair_lock_lock(&lock)
        cachedKey = nil
        cachedReadFailureStatus = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Wipes both the in-memory cache and the Keychain entry. Intended
    /// for "Reset encrypted storage" in Settings or onboarding wipe.
    /// **Irreversible.** Caller is responsible for moving any encrypted
    /// data out first if it should be preserved.
    public func resetForWipe() {
        if Self.disablesKeychainForProcess {
            try? FileManager.default.removeItem(at: saltFile())
            wipeCache()
            return
        }
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
            _ = SecItemDelete(KeychainQueryHelpers.dataProtection(q) as CFDictionary)
            _ = SecItemDelete(q as CFDictionary)
        }
        try? FileManager.default.removeItem(at: saltFile())
        wipeCache()
    }

    // MARK: - Internal helpers

    private static func requiresUserInteraction(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    private func cacheReadFailureIfNonInteractiveBlocked(_ status: OSStatus) {
        guard Self.requiresUserInteraction(status) else { return }
        os_unfair_lock_lock(&lock)
        cachedReadFailureStatus = status
        os_unfair_lock_unlock(&lock)
    }

    private func generateAndPersistKey(forceFresh: Bool = false) throws -> SymmetricKey {
        if Self.disablesKeychainForProcess {
            return try generateInMemoryKey()
        }
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

    private func generateInMemoryKey() throws -> SymmetricKey {
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else {
            throw StorageKeyError.randomFailed
        }
        let keyBytes = Data(raw)
        for i in raw.indices { raw[i] = 0 }
        log.info("Storage key generated in-memory for OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS")
        return SymmetricKey(data: keyBytes)
    }

    /// Fetch the persisted HKDF salt or create a fresh one. We persist
    /// to **both** Keychain and a sidecar file so neither single delete
    /// breaks reproducibility.
    private func fetchOrCreateSalt() throws -> Data {
        if Self.disablesKeychainForProcess {
            if let s = readSaltSidecar() {
                return s
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
                throw StorageKeyError.randomFailed
            }
            let salt = Data(bytes)
            try? writeSaltSidecar(salt)
            return salt
        }
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
        if Self.disablesKeychainForProcess { return }
        try persistItem(account: Self.keyAccount, data: data, label: "Osaurus Storage Encryption Key")
    }

    private func readKeychainKey() throws -> Data? {
        if Self.disablesKeychainForProcess { return nil }
        return try readItem(account: Self.keyAccount, label: "Osaurus Storage Encryption Key")
    }

    // MARK: - Keychain (salt)

    private func persistKeychainSalt(_ data: Data) throws {
        if Self.disablesKeychainForProcess { return }
        try persistItem(account: Self.saltAccount, data: data, label: "Osaurus Storage Key Derivation Salt")
    }

    private func readKeychainSalt() throws -> Data? {
        if Self.disablesKeychainForProcess { return nil }
        return try readItem(account: Self.saltAccount, label: "Osaurus Storage Key Derivation Salt")
    }

    // MARK: - Data-protection keychain (with legacy fallback)
    //
    // The DEK + salt are written to the data-protection keychain so launching a
    // re-signed build never raises the legacy login-keychain ACL password
    // prompt. Items written by older builds are read from the legacy keychain
    // and migrated forward on first read. See `KeychainQueryHelpers.dataProtection`.

    /// Write `attributes` for `account` to the data-protection keychain,
    /// falling back to the legacy keychain when the entitlement is unavailable.
    /// On a successful data-protection write the stale legacy copy is removed so
    /// a later read can never return an outdated key.
    private func persistItem(account: String, data: Data, label: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: label,
        ]

        // Data-protection keychain first.
        let dpQuery = KeychainQueryHelpers.dataProtection(baseQuery)
        let dpUpdate = SecItemUpdate(dpQuery as CFDictionary, attributes as CFDictionary)
        if dpUpdate == errSecSuccess {
            _ = SecItemDelete(baseQuery as CFDictionary)
            return
        }
        if dpUpdate == errSecItemNotFound {
            var add = dpQuery
            add.merge(attributes) { _, new in new }
            let dpAdd = SecItemAdd(add as CFDictionary, nil)
            if dpAdd == errSecSuccess {
                _ = SecItemDelete(baseQuery as CFDictionary)
                return
            }
            if !KeychainQueryHelpers.isMissingEntitlement(dpAdd) {
                throw StorageKeyError.keychainWriteFailed(dpAdd)
            }
        } else if !KeychainQueryHelpers.isMissingEntitlement(dpUpdate) {
            log.error("Storage item SecItemUpdate(data-protection) failed: \(dpUpdate)")
        }

        // Legacy fallback (data-protection keychain unavailable on this host).
        let legacyUpdate = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if legacyUpdate == errSecSuccess { return }
        if legacyUpdate != errSecItemNotFound {
            log.error("Storage item SecItemUpdate(legacy) failed: \(legacyUpdate)")
        }
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StorageKeyError.keychainWriteFailed(addStatus)
        }
    }

    /// Read `account` from the data-protection keychain, falling back to the
    /// legacy keychain (and migrating the value forward) when absent there.
    private func readItem(account: String, label: String) throws -> Data? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(KeychainQueryHelpers.dataProtection(base) as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        if status != errSecItemNotFound && !KeychainQueryHelpers.isMissingEntitlement(status) {
            cacheReadFailureIfNonInteractiveBlocked(status)
            throw StorageKeyError.keychainReadFailed(status)
        }

        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(base as CFDictionary, &legacyResult)
        if legacyStatus == errSecItemNotFound { return nil }
        if legacyStatus != errSecSuccess {
            cacheReadFailureIfNonInteractiveBlocked(legacyStatus)
            throw StorageKeyError.keychainReadFailed(legacyStatus)
        }
        guard let data = legacyResult as? Data else { return nil }
        // Migrate forward so subsequent reads use the data-protection keychain.
        try? persistItem(account: account, data: data, label: label)
        return data
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
