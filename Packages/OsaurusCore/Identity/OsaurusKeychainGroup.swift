//
//  OsaurusKeychainGroup.swift
//  osaurus
//
//  The shared Keychain access group the Osaurus identity items (master key,
//  recovery phrase) live in. iCloud Keychain only hands a synchronizable
//  item to another app when that app is in the same access group, so a
//  future iOS/iPadOS Osaurus client signed by the same team gets the master
//  "for free" only if BOTH apps put the item in this group. Without it the
//  phone's only path is the 24-word phrase.
//
//  The group string is `<AppIdentifierPrefix>ai.osaurus.identity`. The
//  team-ID prefix is only known at build time, so the app's Info.plist
//  carries it (`OsaurusKeychainAccessGroup`, expanded by Xcode) and the
//  entitlement lists the same value. Processes without either — SwiftPM
//  tests, the eval CLI, ad-hoc dev builds — resolve to `nil` and keep using
//  the default (per-app) group exactly as before this file existed.
//

import Foundation
import Security

public enum OsaurusKeychainGroup {
    /// Info.plist key whose value is the fully expanded access group.
    public static let infoPlistKey = "OsaurusKeychainAccessGroup"
    /// Group suffix; the team-ID prefix is prepended by Xcode.
    public static let groupSuffix = "ai.osaurus.identity"

    /// `errSecMissingEntitlement`: the binary asked for an access group its
    /// entitlements do not grant (e.g. a dev build signed without the
    /// group). Callers fall back to the default group on this status.
    public static let missingEntitlementStatus: OSStatus = -34018

    /// Test seam. `.some(nil)` forces "no group"; `.some("x")` forces `x`.
    nonisolated(unsafe) static var overrideForTesting: String??

    /// The shared access group for this process, or `nil` when the build
    /// does not declare one. Resolved once.
    public static var shared: String? {
        if let override = overrideForTesting { return override }
        return resolved
    }

    private static let resolved: String? = resolve(
        infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
    )

    /// Pure resolution rule, split out for tests: the Info.plist value must
    /// be present, non-empty, fully expanded (no `$(`), and end in the
    /// expected suffix — anything else means the build isn't set up for
    /// the shared group and we must not ask the Keychain for it.
    static func resolve(infoValue: String?) -> String? {
        guard let raw = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        guard !raw.contains("$("), raw.hasSuffix(groupSuffix), raw.count > groupSuffix.count else {
            return nil
        }
        return raw
    }

    /// Add `kSecAttrAccessGroup` to a Keychain *write* query when the
    /// group resolves. Read/delete queries deliberately omit the group so
    /// they match items in every group the app can see — that is what lets
    /// an item written before this change keep working and be migrated.
    static func apply(to query: inout [String: Any]) {
        if let group = shared {
            query[kSecAttrAccessGroup as String] = group
        }
    }
}
