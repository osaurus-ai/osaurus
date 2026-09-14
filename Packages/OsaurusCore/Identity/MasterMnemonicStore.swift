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
        if KeychainQueryHelpers.disablesKeychainForProcess {
            throw OsaurusIdentityError.keychainWriteFailed
        }
        let phrase = words.joined(separator: " ")
        guard let data = phrase.data(using: .utf8) else {
            throw OsaurusIdentityError.keychainWriteFailed
        }

        if exists() {
            delete()
        }

        // Same write order as `MasterKey`: shared group first, default
        // group as the fallback for builds without the entitlement.
        let attempts: [(group: String?, synchronizable: Bool)] =
            (OsaurusKeychainGroup.shared.map { [($0, true), ($0, false)] } ?? [])
            + [(nil, true), (nil, false)]
        for attempt in attempts {
            if addToKeychain(data: data, synchronizable: attempt.synchronizable, accessGroup: attempt.group)
                == errSecSuccess
            {
                return
            }
        }
        throw OsaurusIdentityError.keychainWriteFailed
    }

    // Mirrors `MasterKey`: a synchronizable iCloud Keychain item.
    private static func addToKeychain(data: Data, synchronizable: Bool, accessGroup: String?) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Osaurus Recovery Phrase",
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
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

    // MARK: - Read

    /// Fetch the stored 24-word phrase. Triggers a biometric prompt — the
    /// phrase is the seed in a different encoding, so it carries the same
    /// access gate.
    public static func load(context: LAContext) throws -> [String] {
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
        migrateToSharedGroupIfNeeded(data: data)
        return words
    }

    /// Once per process, mirror of `MasterKey`'s migration: move a phrase
    /// written before the shared access group existed into that group.
    private static let migrationLock = NSLock()
    private nonisolated(unsafe) static var migrationAttempted = false

    private static func migrateToSharedGroupIfNeeded(data: Data) {
        guard let group = OsaurusKeychainGroup.shared else { return }
        migrationLock.lock()
        let alreadyTried = migrationAttempted
        migrationAttempted = true
        migrationLock.unlock()
        guard !alreadyTried else { return }
        MasterKey.migrateGenericPassword(
            service: service, account: account, label: "Osaurus Recovery Phrase",
            data: data, toGroup: group
        )
    }

    // MARK: - Delete

    /// Remove the stored phrase. Used by `OsaurusIdentity.wipe()` so a
    /// "Reset Identity" tears down the mnemonic alongside the master.
    @discardableResult
    public static func delete() -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
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
