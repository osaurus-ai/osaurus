//
//  Keychain.swift
//  osaurus
//
//  Shared generic-password (`kSecClassGenericPassword`) CRUD against the
//  macOS legacy (file-based login) keychain.
//

import Foundation
import Security

/// Generic-password CRUD used by every secret store in the app.
///
/// Reads run with `kSecUseAuthenticationUISkip` plus a non-interactive
/// `LAContext` so a query that the item's ACL would otherwise gate fails
/// silently (returns `nil`) instead of raising the "wants to use your
/// confidential information" password prompt. Because release builds keep a
/// stable Developer ID Designated Requirement (same cert + bundle id), the
/// keychain treats update N+1 as the same app as update N, so legitimately
/// owned items read back without any prompt across updates.
///
/// Callers apply their own `KeychainQueryHelpers.disablesKeychainForProcess`
/// short-circuit before calling these methods.
enum Keychain {
    /// Serial queue for fire-and-forget writes. `SecItemAdd`/`SecItemUpdate`
    /// are synchronous and can block for seconds under iCloud-keychain or
    /// first-unlock contention; running them here keeps that I/O off the main
    /// thread (a recurring app-hang source). Serial so concurrent writes to the
    /// same item don't race.
    private static let writeQueue = DispatchQueue(
        label: "com.dinoki.osaurus.keychain.write", qos: .utility)

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

    // MARK: - CRUD

    /// Upsert `data` for (`service`, `account`).
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

        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
        var add = base
        add.merge(attributes) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Fire-and-forget variant of `write` that runs the blocking SecItem call
    /// off the caller's thread. Use when the authoritative value is held in
    /// memory and the write result isn't needed synchronously, so the caller
    /// never blocks the main thread on Security-framework I/O. `data` is
    /// captured at call time, so callers can encode their snapshot first and
    /// return immediately.
    static func writeInBackground(
        service: String,
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) {
        writeQueue.async {
            _ = write(service: service, account: account, data: data, accessible: accessible)
        }
    }

    /// Read (`service`, `account`). Returns `nil` when the item is absent or
    /// the read would require interactive authorization.
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return data
    }

    /// Delete (`service`, `account`).
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        isResolved(SecItemDelete(baseQuery(service: service, account: account) as CFDictionary))
    }

    /// Every attribute dictionary stored under `service`, de-duplicated on
    /// account name.
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

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return [] }

        var merged: [String: [String: Any]] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            merged[account] = item
        }
        return Array(merged.values)
    }

    /// Account names stored under `service`.
    static func allAccounts(service: String) -> [String] {
        fetchAll(service: service, returnData: false)
            .compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
