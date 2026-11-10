//
//  SpaceKeychainScope.swift
//  osaurus
//
//  Gives every non-Default Space its own Keychain entries. Default keeps the
//  bare service names it has always used, so existing installs see no change.
//

import Foundation
import OsaurusRepository
import Security

enum SpaceKeychainScope {
    /// The service name every Security-framework query must use for `base`
    /// in the active Space.
    static func service(_ base: String) -> String {
        service(base, spaceId: SpaceRegistry.activeSpaceId())
    }

    static func service(_ base: String, spaceId: String) -> String {
        spaceId == SpaceRegistry.defaultSpaceId ? base : "\(base).space.\(spaceId)"
    }

    /// Only Default may write synchronizable or shared-group items: a test
    /// Space's identity must never reach iCloud Keychain or other devices.
    static var allowsSharedAndSyncedItems: Bool {
        SpaceRegistry.isDefaultActive
    }

    static let wipedServices: [String] =
        OsaurusKeychainServices.all + [RegistryReviewWatchTokens.keychainService]

    /// Delete every Osaurus Keychain item belonging to a non-Default Space.
    /// Never touches Default's bare service names.
    static func wipe(spaceId: String) {
        guard spaceId != SpaceRegistry.defaultSpaceId, SpaceRegistry.isValidSpaceId(spaceId) else { return }
        guard !KeychainQueryHelpers.disablesKeychainForProcess else { return }
        for base in wipedServices {
            let scoped = service(base, spaceId: spaceId)
            for useDataProtection in [false, true] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: scoped,
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                ]
                if useDataProtection {
                    query[kSecUseDataProtectionKeychain as String] = true
                }
                let status = deleteAllItems(matching: query)
                if status != errSecSuccess && status != errSecItemNotFound {
                    print("[Spaces] Failed to wipe Keychain service \(scoped): \(status)")
                }
            }
        }
    }

    /// `SecItemDelete` removes only the first match from the file-based
    /// Keychain, so repeat until nothing matches. Returns `errSecSuccess`
    /// when at least one item was deleted and the last call ran out of
    /// matches, otherwise the failing status.
    @discardableResult
    static func deleteAllItems(matching query: [String: Any], limit: Int = 1024) -> OSStatus {
        var deletedAny = false
        for _ in 0..<limit {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess else {
                return status == errSecItemNotFound && deletedAny ? errSecSuccess : status
            }
            deletedAny = true
        }
        return errSecSuccess
    }
}
