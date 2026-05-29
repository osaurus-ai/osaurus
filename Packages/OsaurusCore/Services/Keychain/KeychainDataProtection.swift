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

    // MARK: - Data-protection keychain availability

    /// Whether the data-protection keychain is available in this process,
    /// determined once (lazily) via a sentinel write → read-back → delete.
    ///
    /// Un-entitled hosts — e.g. `swift test` binaries with no
    /// `keychain-access-groups` entitlement — get `errSecMissingEntitlement` from
    /// the data-protection keychain. Probing once lets `read`/`write` route those
    /// processes to the legacy keychain without repeating the check (and without
    /// ever deleting from it).
    static let isUsable: Bool = {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.osaurus.dpprobe",
            kSecAttrAccount as String: "roundtrip",
        ]
        let dpBase = KeychainQueryHelpers.dataProtection(base)
        let sentinel = Data("osaurus-dp-probe".utf8)

        // Clear any sentinel left by a prior launch so the add path is exercised.
        SecItemDelete(dpBase as CFDictionary)

        var add = dpBase
        add[kSecValueData as String] = sentinel
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            // `errSecMissingEntitlement` is the expected status on un-entitled
            // hosts (e.g. `swift test` binaries); anything else is unexpected.
            if KeychainQueryHelpers.isMissingEntitlement(addStatus) {
                log.debug("data-protection keychain unavailable (missing entitlement); using legacy keychain")
            } else {
                log.error("data-protection keychain probe add failed (status \(addStatus)); using legacy keychain")
            }
            return false
        }

        var readBack = dpBase
        readBack[kSecReturnData as String] = true
        readBack[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readBack as CFDictionary, &result)
        SecItemDelete(dpBase as CFDictionary)

        let roundTrips = readStatus == errSecSuccess && (result as? Data) == sentinel
        if !roundTrips {
            log.error(
                "data-protection keychain did not round-trip a probe write (read status \(readStatus)); using legacy keychain"
            )
        }
        return roundTrips
    }()

    // MARK: - CRUD

    /// Upsert `data` for (`service`, `account`). Writes to the data-protection
    /// keychain when it is usable, otherwise to the legacy keychain.
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

        if isUsable {
            // Data-protection keychain (update-or-add).
            //
            // IMPORTANT: do NOT issue a `SecItemDelete(base)` here to clean up a
            // legacy copy. On an app entitled for the data-protection keychain, a
            // delete query that omits `kSecUseDataProtectionKeychain` is not
            // reliably scoped to the legacy keychain — it matches and deletes the
            // data-protection item we just wrote, so every subsequent read returns
            // errSecItemNotFound. A stale legacy copy is harmless instead: `read`
            // checks the data-protection keychain first, and `delete` clears both.
            let dpBase = KeychainQueryHelpers.dataProtection(base)
            if SecItemUpdate(dpBase as CFDictionary, attributes as CFDictionary) == errSecSuccess {
                return true
            }
            var dpAdd = dpBase
            dpAdd.merge(attributes) { _, new in new }
            if SecItemAdd(dpAdd as CFDictionary, nil) == errSecSuccess {
                return true
            }
            // Unexpected: probe said the keychain works but this write didn't.
            // Fall through to the legacy keychain rather than losing the value.
        }

        // Legacy keychain. Never deletes — when the data-protection keychain is
        // unusable this is the only durable store.
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
        var legacyAdd = base
        legacyAdd.merge(attributes) { _, new in new }
        return SecItemAdd(legacyAdd as CFDictionary, nil) == errSecSuccess
    }

    /// Read (`service`, `account`), preferring the data-protection keychain (when
    /// usable) and falling back to — and migrating forward from — the legacy
    /// keychain.
    static func read(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> Data? {
        let base = baseQuery(service: service, account: account)

        if isUsable {
            // The data-protection items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
            // with no access control, so the query needs no authentication context
            // and there is no biometric/passcode UI to suppress.
            var dpQuery = KeychainQueryHelpers.dataProtection(base)
            dpQuery[kSecReturnData as String] = true
            dpQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(dpQuery as CFDictionary, &result) == errSecSuccess {
                return result as? Data
            }
            // Not in the data-protection keychain yet: fall through to the legacy
            // keychain and migrate the value forward on hit.
        }

        // Legacy query. Here the auth params matter: this is where the per-binary
        // ACL "wants to use your confidential information" password prompt would
        // appear, and `kSecUseAuthenticationUISkip` + a non-interactive
        // `LAContext` suppress it (the read simply fails instead of prompting).
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        var legacyResult: AnyObject?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
            let data = legacyResult as? Data
        else { return nil }

        // Migrate the legacy value into the data-protection keychain only when it
        // actually works; otherwise leave it where it is.
        if isUsable {
            write(service: service, account: account, data: data, accessible: accessible)
        }
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
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if returnData { base[kSecReturnData as String] = true }

        // The legacy query keeps the non-interactive auth params to suppress the
        // login-keychain password prompt; the data-protection query needs none.
        let dpQuery = KeychainQueryHelpers.dataProtection(base)
        var legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        if returnData { legacyQuery[kSecReturnData as String] = true }

        // Legacy first so data-protection entries win on duplicate accounts.
        var merged: [String: [String: Any]] = [:]
        for q in [legacyQuery, dpQuery] {
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
