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

        return osaurusId
    }

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

    // MARK: - Read

    /// Retrieve the Osaurus ID (triggers biometric auth).
    public static func getOsaurusId(context: LAContext) throws -> OsaurusID {
        var key = try getPrivateKey(context: context)
        defer { key.zeroOut() }
        return try deriveOsaurusId(from: key)
    }

    /// Retrieve the raw Master Key bytes from Keychain (triggers biometric auth).
    static func getPrivateKey(context: LAContext) throws -> Data {
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Memory Safety

    private static func zeroBytes(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = 0 }
    }
}
