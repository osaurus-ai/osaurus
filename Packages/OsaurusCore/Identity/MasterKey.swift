//
//  MasterKey.swift
//  osaurus
//
//  Manages the secp256k1 Master Key in iCloud Keychain.
//  This is the root of the Osaurus identity — syncs across devices via iCloud.
//

import Foundation
import LocalAuthentication
import Security

public struct MasterKey: Sendable {
    static let service = "com.osaurus.account"
    static let account = "master-key"

    // MARK: - Generate

    /// Generate a new Master Key, store it in iCloud Keychain, and return the Osaurus ID
    /// alongside the raw 32-byte seed (so callers can derive a BIP39 backup before
    /// zeroing it). The seed Data **must** be wiped by the caller after use.
    ///
    /// - Parameter allowReplace: When false (the default), refuses to run if a Master
    ///   Key already exists in Keychain. The "Reset Identity" flow is the only place
    ///   that should pass `true`.
    @discardableResult
    public static func generate(allowReplace: Bool = false) throws -> (osaurusId: OsaurusID, seed: Data) {
        if !allowReplace, exists() {
            throw OsaurusIdentityError.masterAlreadyExists
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
            throw OsaurusIdentityError.randomFailed
        }

        let keyData = Data(bytes)
        zeroBytes(&bytes)

        let osaurusId = try install(seed: keyData, allowReplace: allowReplace)
        return (osaurusId, keyData)
    }

    /// Install a caller-supplied 32-byte seed as the Master Key. Used by the
    /// recovery-from-mnemonic flow to restore a previous identity from a saved
    /// BIP39 phrase.
    ///
    /// - Parameter allowReplace: Mirrors `generate(allowReplace:)`. Defaults to false.
    @discardableResult
    public static func install(seed keyData: Data, allowReplace: Bool = false) throws -> OsaurusID {
        // Hermetic test/proof launches (OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1)
        // must not persist identity material into the user's login Keychain.
        // This is the same no-op-write contract every other Keychain wrapper
        // honors via `KeychainQueryHelpers.disablesKeychainForProcess`.
        if KeychainQueryHelpers.disablesKeychainForProcess {
            throw OsaurusIdentityError.keychainWriteFailed
        }
        if !allowReplace, exists() {
            throw OsaurusIdentityError.masterAlreadyExists
        }

        guard keyData.count == 32 else {
            throw OsaurusIdentityError.signingFailed
        }

        let osaurusId = try deriveOsaurusId(from: keyData)

        // If we are replacing, drop any existing key first so SecItemAdd doesn't
        // collide on the (service, account) pair.
        if exists() {
            delete()
        }

        let status = addToKeychain(keyData: keyData, synchronizable: true)
        if status != errSecSuccess {
            let fallback = addToKeychain(keyData: keyData, synchronizable: false)
            guard fallback == errSecSuccess else {
                throw OsaurusIdentityError.keychainWriteFailed
            }
        }

        setCachedExists(true)
        return osaurusId
    }

    // The Master Key is a synchronizable iCloud Keychain item.
    private static func addToKeychain(keyData: Data, synchronizable: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrLabel as String: "Osaurus Master Key",
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Existence Check

    /// Check if a Master Key exists in Keychain (no biometric prompt).
    public static func exists() -> Bool {
        // Keychain-disabled processes report "no identity" so identity-gated
        // paths (e.g. `AgentManager.assignAddress`) short-circuit before any
        // legacy login-Keychain read can raise a "wants to use your
        // confidential information" ACL prompt in a headless/differently-signed
        // process (the eval CLI).
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Cached Existence (hot UI paths)

    // `exists()` issues a synchronous `SecItemCopyMatching`, which blocks on the
    // Security daemon's keychain mutex. Calling it on every model-picker
    // recompute (the managed-router gate in `RemoteProviderManager`) has hung
    // the UI for seconds. This memo serves those hot, eventually-consistent
    // callers without a per-call keychain hit: it is updated in-process on
    // install/delete, seeded once lazily, and refreshed off the main thread to
    // pick up out-of-process iCloud Keychain syncs.
    private static let existsCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedExists: Bool?
    private nonisolated(unsafe) static var lastExistsRefresh: Date?
    private static let existsRefreshInterval: TimeInterval = 10.0

    /// Non-blocking, eventually-consistent variant of `exists()` for hot UI
    /// paths (e.g. the managed-router gate hit on every model-picker recompute).
    /// Once seeded it never issues a keychain query on the calling thread.
    /// Correctness-critical callers — identity creation/recovery guards and
    /// anything about to read or sign with the key — must keep using `exists()`.
    public static func existsCached() -> Bool {
        existsCacheLock.lock()
        let known = cachedExists
        existsCacheLock.unlock()

        if let known {
            refreshExistsInBackground()
            return known
        }
        // Cold: seed once from the keychain, then serve the memo thereafter.
        let probed = exists()
        setCachedExists(probed)
        return probed
    }

    private static func setCachedExists(_ value: Bool) {
        existsCacheLock.lock()
        cachedExists = value
        lastExistsRefresh = Date()
        existsCacheLock.unlock()
    }

    /// Seed `existsCached()` off the main thread (and off the Swift cooperative
    /// pool, which a synchronous keychain read would otherwise pin) so the first
    /// hot-path caller — e.g. the managed-router gate reached from the periodic
    /// badge recompute — never triggers a `SecItemCopyMatching` on a
    /// latency-sensitive thread. Call once at launch; idempotent.
    public static func warmExistsCacheInBackground() {
        DispatchQueue.global(qos: .utility).async {
            _ = existsCached()
        }
    }

    private static func refreshExistsInBackground() {
        let now = Date()
        existsCacheLock.lock()
        let recent = lastExistsRefresh.map { now.timeIntervalSince($0) < existsRefreshInterval } ?? false
        if recent {
            existsCacheLock.unlock()
            return
        }
        // Stamp now (under the lock) so concurrent callers don't each spawn a probe.
        lastExistsRefresh = now
        existsCacheLock.unlock()

        Task.detached(priority: .utility) {
            setCachedExists(exists())
        }
    }

    // MARK: - Read

    /// Retrieve the Osaurus ID (triggers biometric auth).
    public static func getOsaurusId(context: LAContext) throws -> OsaurusID {
        var key = try getPrivateKey(context: context)
        defer { key.zeroOut() }
        return try deriveOsaurusId(from: key)
    }

    /// Retrieve the raw Master Key bytes from Keychain (triggers biometric auth).
    static func getPrivateKey(context: LAContext) throws -> Data {
        // No-op read under the keychain-disable gate (hermetic test/proof runs).
        // The Master Key item lives in the legacy file-based login Keychain,
        // where `kSecUseAuthenticationUISkip` / `LAContext.interactionNotAllowed`
        // do NOT suppress the trusted-app ACL prompt — so the only safe headless
        // behavior is to not read at all.
        if KeychainQueryHelpers.disablesKeychainForProcess {
            throw OsaurusIdentityError.keychainReadFailed
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        if context.interactionNotAllowed {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw OsaurusIdentityError.keychainReadFailed
        }
        return data
    }

    // MARK: - Sign

    /// Sign a payload with the Master Key (triggers biometric auth).
    public static func sign(payload: Data, context: LAContext) throws -> Data {
        var key = try getPrivateKey(context: context)
        defer { key.zeroOut() }
        return try signPayload(payload, privateKey: key)
    }

    // MARK: - Delete

    /// Remove the Master Key from Keychain (irreversible).
    @discardableResult
    public static func delete() -> Bool {
        // No-op delete under the keychain-disable gate, mirroring the read/write
        // no-ops above and the documented wrapper contract.
        if KeychainQueryHelpers.disablesKeychainForProcess {
            setCachedExists(false)
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let gone = status == errSecSuccess || status == errSecItemNotFound
        if gone {
            setCachedExists(false)
        }
        return gone
    }

    // MARK: - Memory Safety

    private static func zeroBytes(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = 0 }
    }
}
