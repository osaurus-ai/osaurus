//
//  MasterMnemonicStore.swift
//  osaurus
//
//  Persistent store for the 24-word BIP39 backup of the master seed.
//
//  Shape mirrors `MasterKey`: iCloud Keychain item under the shared
//  `com.osaurus.account` service, gated behind biometric auth on read.
//  The mnemonic is exactly equivalent to the seed in trust level — anyone
//  who can read either can reconstruct the other — so storing it next to
//  the seed adds no attack surface. What it buys us is a frictionless
//  "View recovery phrase" experience in Settings without needing to
//  re-derive from the seed every time, and lets onboarding skip the
//  "write these 24 words down" gate entirely.
//

import Foundation
import LocalAuthentication
import Security

public struct MasterMnemonicStore: Sendable {
    static let service = MasterKey.service
    static let account = "master-mnemonic"

    // MARK: - Store

    /// Persist the supplied 24-word phrase into iCloud Keychain alongside the
    /// master seed. If an entry already exists it is replaced — call sites
    /// (initial setup, recovery-from-mnemonic, lazy backfill) all want the
    /// stored phrase to reflect the most recently-installed master.
    public static func store(_ words: [String]) throws {
        guard words.count == 24 else {
            throw OsaurusIdentityError.mnemonicInvalidWordCount
        }
        let phrase = words.joined(separator: " ")
        guard let data = phrase.data(using: .utf8) else {
            throw OsaurusIdentityError.keychainWriteFailed
        }

        if exists() {
            delete()
        }

        let status = addToKeychain(data: data, synchronizable: true)
        if status != errSecSuccess {
            let fallback = addToKeychain(data: data, synchronizable: false)
            guard fallback == errSecSuccess else {
                throw OsaurusIdentityError.keychainWriteFailed
            }
        }
    }

    // Mirrors `MasterKey`: a synchronizable iCloud Keychain item.
    private static func addToKeychain(data: Data, synchronizable: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Osaurus Recovery Phrase",
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Existence

    /// Whether the stored phrase exists. No biometric prompt — used by
    /// callers (Settings → Identity) to decide between a direct read and
    /// the lazy backfill path for legacy installs that pre-date this
    /// store.
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

    /// Fetch the stored 24-word phrase. Triggers a biometric prompt — the
    /// phrase is the seed in a different encoding, so it carries the same
    /// access gate.
    public static func load(context: LAContext) throws -> [String] {
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
        guard status == errSecSuccess,
            let data = result as? Data,
            let phrase = String(data: data, encoding: .utf8)
        else {
            throw OsaurusIdentityError.keychainReadFailed
        }

        let words =
            phrase
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard words.count == 24 else {
            throw OsaurusIdentityError.mnemonicInvalidWordCount
        }
        return words
    }

    // MARK: - Delete

    /// Remove the stored phrase. Used by `OsaurusIdentity.wipe()` so a
    /// "Reset Identity" tears down the mnemonic alongside the master.
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
}
