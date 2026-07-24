//
//  Keychain.swift
//  osaurus
//
//  Shared generic-password (`kSecClassGenericPassword`) CRUD against the
//  macOS legacy (file-based login) keychain.
//

import Foundation
import Security

/// Distinguishes an absent Keychain item from a denied/transient/corrupt read.
///
/// Existing `Keychain.read` callers still collapse non-values to `nil`; security-
/// critical paths that must not treat "could not read" as "empty" use this.
enum KeychainReadResult: Equatable, Sendable {
    /// No generic-password item exists for the query.
    case missing
    /// Item exists and its value was returned.
    case value(Data)
    /// Item may exist but the read failed (auth UI required, locked, transient
    /// error, unexpected payload type, etc.). Must not be treated as empty.
    case unavailable
}

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
        data: Data
    ) {
        _ = performOrderedWrite(waitUntilFinished: false) {
            write(service: service, account: account, data: data)
        }
    }

    /// Perform a checked write behind every previously-enqueued background
    /// write. Security-critical callers use this instead of calling `write`
    /// directly so an older fire-and-forget snapshot cannot land afterward
    /// and roll durable state back.
    @discardableResult
    static func writeAfterPendingWrites(
        service: String,
        account: String,
        data: Data
    ) -> Bool {
        performOrderedWrite(waitUntilFinished: true) {
            write(service: service, account: account, data: data)
        }
    }

    /// Internal deterministic seam for proving ordering without touching the
    /// login Keychain. All queued writes share the same serial executor.
    @discardableResult
    static func performOrderedWrite(
        waitUntilFinished: Bool,
        operation: @escaping @Sendable () -> Bool
    ) -> Bool {
        if waitUntilFinished {
            return writeQueue.sync(execute: operation)
        }
        writeQueue.async {
            _ = operation()
        }
        return true
    }

    /// Read (`service`, `account`) with an explicit missing vs unavailable result.
    static func readResult(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> KeychainReadResult {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        query[kSecUseAuthenticationContext as String] = KeychainQueryHelpers.nonInteractiveContext()

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .unavailable }
            return .value(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    /// Read (`service`, `account`). Returns `nil` when the item is absent or
    /// the read would require interactive authorization.
    static func read(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> Data? {
        if case .value(let data) = readResult(
            service: service, account: account, accessible: accessible)
        {
            return data
        }
        return nil
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
