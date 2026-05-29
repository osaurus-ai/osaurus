//
//  KeychainDataProtection.swift
//  osaurus
//
//  Shared SecItem helpers that target the macOS data-protection keychain.
//

import Foundation
import Security
import os

/// Generic-password (`kSecClassGenericPassword`) CRUD that targets the macOS
/// data-protection keychain (`kSecUseDataProtectionKeychain`) with a transparent
/// fallback to the legacy file-based keychain.
///
/// Why this exists: the legacy keychain authorizes reads against a per-binary
/// ACL, so a re-signed build raises the "wants to use your confidential
/// information" password prompt. The data-protection keychain authorizes by the
/// app's entitled access group instead, so reads never prompt. Items written by
/// older builds live in the legacy keychain; `read(...)` falls back to it and
/// migrates the value forward on first hit. Un-entitled hosts (e.g. `swift test`
/// binaries) get `errSecMissingEntitlement` and transparently use the legacy
/// keychain throughout. See `KeychainQueryHelpers.dataProtection`.
///
/// Callers are expected to apply their own `disablesKeychainForProcess` /
/// in-memory test short-circuits *before* calling these methods.
enum KeychainDataProtection {
    private static let log = Logger(subsystem: "ai.osaurus", category: "keychain.dp")

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func isResolved(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// Upsert `data` for (`service`, `account`). Prefers the data-protection
    /// keychain and removes the stale legacy copy on success so a later read can
    /// never return outdated data. Falls back to the legacy keychain when the
    /// data-protection keychain is unavailable.
    @discardableResult
    static func write(
        service: String,
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> Bool {
        let base = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]

        // Data-protection keychain first (update-or-add).
        let dpBase = KeychainQueryHelpers.dataProtection(base)
        if SecItemUpdate(dpBase as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            SecItemDelete(base as CFDictionary)
            return true
        }
        var dpAdd = dpBase
        dpAdd.merge(attributes) { _, new in new }
        let dpStatus = SecItemAdd(dpAdd as CFDictionary, nil)
        if dpStatus == errSecSuccess {
            SecItemDelete(base as CFDictionary)
            return true
        }
        guard KeychainQueryHelpers.isMissingEntitlement(dpStatus) else { return false }

        // Legacy fallback (data-protection keychain unavailable on this host).
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
        var legacyAdd = base
        legacyAdd.merge(attributes) { _, new in new }
        return SecItemAdd(legacyAdd as CFDictionary, nil) == errSecSuccess
    }

    /// Read (`service`, `account`), preferring the data-protection keychain and
    /// falling back to (and migrating from) the legacy keychain.
    static func read(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        query[kSecUseAuthenticationContext as String] = KeychainQueryHelpers.nonInteractiveContext()

        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(
            KeychainQueryHelpers.dataProtection(query) as CFDictionary, &result)
        if dpStatus == errSecSuccess { return result as? Data }

        // Only fall back to the legacy keychain when the data-protection item is
        // genuinely absent (never written there) or this host can't use the
        // data-protection keychain at all. Any other status — e.g.
        // `errSecInteractionNotAllowed` / `errSecAuthFailed` — means a
        // data-protection item *exists* but is intentionally inaccessible right
        // now; querying the legacy keychain there would risk a login-keychain
        // prompt and could return a stale value that shadows the real item. Fail
        // closed instead.
        guard dpStatus == errSecItemNotFound || KeychainQueryHelpers.isMissingEntitlement(dpStatus)
        else {
            log.error(
                "data-protection read for \(service, privacy: .public) failed (status \(dpStatus)); not falling back to legacy keychain"
            )
            return nil
        }

        var legacyResult: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &legacyResult) == errSecSuccess,
            let data = legacyResult as? Data
        else { return nil }
        write(service: service, account: account, data: data, accessible: accessible)
        return data
    }

    /// Delete (`service`, `account`) from both keychains.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let base = baseQuery(service: service, account: account)
        let dp = SecItemDelete(KeychainQueryHelpers.dataProtection(base) as CFDictionary)
        let legacy = SecItemDelete(base as CFDictionary)
        return isResolved(dp) && isResolved(legacy)
    }

    /// Every attribute dictionary stored under `service` across both keychains,
    /// de-duplicated on account name (the data-protection copy wins so migrated
    /// values shadow stale legacy data).
    static func fetchAll(service: String, returnData: Bool) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        if returnData { query[kSecReturnData as String] = true }

        // Legacy first so data-protection entries win on duplicate accounts.
        var merged: [String: [String: Any]] = [:]
        for q in [query, KeychainQueryHelpers.dataProtection(query)] {
            var result: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
                let items = result as? [[String: Any]]
            else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                merged[account] = item
            }
        }
        return Array(merged.values)
    }

    /// Account names stored under `service` across both keychains.
    static func allAccounts(service: String) -> [String] {
        fetchAll(service: service, returnData: false)
            .compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
