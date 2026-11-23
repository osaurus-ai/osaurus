//
//  MasterKeyArchive.swift
//  osaurus
//
//  Device-only copies of every Master Key this Mac has created, restored, or
//  read. The live master is one synced iCloud Keychain slot: a second
//  identity created on any Mac replaces it on every Mac, including the one
//  that held the original. This archive keeps one item per address that the
//  synced slot can't overwrite, so the Identity view can list previous
//  identities and switch back to one without the 24-word phrase.
//
//  Items are never synchronizable: an archive that synced would spread every
//  key ever used to every Mac, and the Mac that held the original identity
//  is the one that needs the copy.
//

import Foundation
import LocalAuthentication
import Security

public struct ArchivedIdentity: Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// Generated on this Mac (`MasterKey.generate`).
        case created
        /// Installed from a recovery phrase or a previous identity.
        case restored
        /// Read from the Keychain on this Mac: synced from another device or
        /// created by a build that predates the archive.
        case keychain
    }

    public let address: OsaurusID
    public let source: Source
    public let firstSeenAt: Date
    public let lastActiveAt: Date

    public var id: String { address.lowercased() }
}

public enum MasterKeyArchive {
    static let label = "Osaurus Previous Identity"

    /// Test seam: tests point the archive at a throwaway service. Without it,
    /// test processes skip archive writes so fixture seeds installed through
    /// `MasterKey` never land in the developer's real archive.
    nonisolated(unsafe) static var serviceOverrideForTesting: String?

    /// Unscoped service name; every query passes it through
    /// `SpaceKeychainScope.service(_:)`.
    static var baseService: String {
        serviceOverrideForTesting ?? OsaurusKeychainServices.accountArchive
    }

    private static var isDisabled: Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return serviceOverrideForTesting == nil && KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
    }

    private struct Metadata: Codable {
        var address: String
        var source: ArchivedIdentity.Source
        var firstSeenAt: Date
        var lastActiveAt: Date
    }

    // MARK: - Remember

    private static let rememberLock = NSLock()
    private nonisolated(unsafe) static var rememberedThisProcess: Set<String> = []

    /// Keep a device-only copy of `seed`. Adds the item the first time an
    /// address is seen; later calls only refresh `lastActiveAt`. Repeat calls
    /// for the same address within one process are skipped so the many
    /// `MasterKey.getPrivateKey` call sites cost one Keychain write at most.
    /// `force` bypasses that skip for an install, which is always worth
    /// recording.
    static func remember(seed: Data, source: ArchivedIdentity.Source, force: Bool = false) {
        guard !isDisabled, seed.count == 32, let address = try? deriveOsaurusId(from: seed) else { return }
        let account = address.lowercased()

        rememberLock.lock()
        let seen = rememberedThisProcess.contains(account)
        rememberedThisProcess.insert(account)
        rememberLock.unlock()
        if seen && !force { return }

        let now = Date()
        if var existing = metadata(account: account) {
            existing.lastActiveAt = now
            update(account: account, metadata: existing)
            return
        }
        let metadata = Metadata(address: address, source: source, firstSeenAt: now, lastActiveAt: now)
        guard let generic = try? JSONEncoder().encode(metadata) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecAttrGeneric as String: generic,
            kSecValueData as String: seed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - List

    /// Every archived identity, most recently active first. Reads attributes
    /// only, so it never raises a biometric or Keychain prompt.
    public static func list() -> [ArchivedIdentity] {
        guard !isDisabled else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let rows = result as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let generic = row[kSecAttrGeneric as String] as? Data,
                let metadata = try? JSONDecoder().decode(Metadata.self, from: generic)
            else { return nil }
            return ArchivedIdentity(
                address: metadata.address,
                source: metadata.source,
                firstSeenAt: metadata.firstSeenAt,
                lastActiveAt: metadata.lastActiveAt
            )
        }
        .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: - Load

    /// The archived seed for `address`. Gated the same way as
    /// `MasterKey.getPrivateKey`; pass one reused `LAContext` to read several
    /// entries behind a single prompt. The caller must zero the bytes.
    static func loadSeed(address: OsaurusID, context: LAContext) throws -> Data {
        guard !isDisabled else { throw OsaurusIdentityError.keychainReadFailed }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecAttrAccount as String: address.lowercased(),
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        if context.interactionNotAllowed {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, data.count == 32
        else {
            throw OsaurusIdentityError.keychainReadFailed
        }
        return data
    }

    // MARK: - Forget

    /// Remove one archived identity. Never touches the live master.
    @discardableResult
    public static func forget(address: OsaurusID) -> Bool {
        guard !isDisabled else { return true }
        let account = address.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecAttrAccount as String: account,
        ]
        let status = SpaceKeychainScope.deleteAllItems(matching: query)
        rememberLock.lock()
        rememberedThisProcess.remove(account)
        rememberLock.unlock()
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Clears the per-process skip set. Tests only.
    static func resetProcessCacheForTesting() {
        rememberLock.lock()
        rememberedThisProcess.removeAll()
        rememberLock.unlock()
    }

    // MARK: - Private

    private static func metadata(account: String) -> Metadata? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let row = result as? [String: Any],
            let generic = row[kSecAttrGeneric as String] as? Data
        else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: generic)
    }

    private static func update(account: String, metadata: Metadata) {
        guard let generic = try? JSONEncoder().encode(metadata) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SpaceKeychainScope.service(baseService),
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecAttrGeneric as String: generic]
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}
