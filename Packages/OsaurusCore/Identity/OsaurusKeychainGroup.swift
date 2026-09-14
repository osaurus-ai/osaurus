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
//  NOT SHIPPED YET. `keychain-access-groups` is a profile-managed entitlement
//  on macOS; the Developer ID release build carries no provisioning profile,
//  and adding the key made AMFI refuse to spawn 0.19.3 (#1288 → #1296, which
//  also added `RuntimePolicySourceTests` to keep it out). Neither the
//  entitlement nor the Info.plist key is present in `App/osaurus`, so `shared`
//  is `nil` in every shipped build and the dual-write / mirror paths below
//  are no-ops. Turning the group on means embedding a provisioning profile in
//  the release pipeline (or choosing a different sharing mechanism); the
//  code here is ready for either, gated on the Info.plist key alone.
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
    /// an item written before this change keep working and be mirrored.
    static func apply(to query: inout [String: Any]) {
        if let group = shared {
            query[kSecAttrAccessGroup as String] = group
        }
    }

    // MARK: - Dual-write / mirror policy (pure)

    /// One `SecItemAdd` attempt: which access group (nil = the app's
    /// default group, i.e. the layout every shipped build reads) and
    /// whether to ask for iCloud sync.
    public struct WriteTarget: Equatable, Sendable {
        public let accessGroup: String?
        public let synchronizable: Bool
    }

    /// Where a new identity item is written. Returns one list of attempts
    /// **per group**; within a group the caller stops at the first success
    /// (sync, then device-only), and the write counts as successful when at
    /// least one group took the item.
    ///
    /// The default group comes first and is always present. A Mac that is
    /// still on a build without the `keychain-access-groups` entitlement can
    /// only see that group, so writing there keeps a mixed-version fleet on
    /// one master. The shared group is an *additional* copy of the same
    /// bytes for same-team clients (iOS); it is never the only copy.
    static func writeAttemptGroups(sharedGroup: String?) -> [[WriteTarget]] {
        var groups: [[WriteTarget]] = [
            [WriteTarget(accessGroup: nil, synchronizable: true), WriteTarget(accessGroup: nil, synchronizable: false)]
        ]
        if let sharedGroup, !sharedGroup.isEmpty {
            groups.append([
                WriteTarget(accessGroup: sharedGroup, synchronizable: true),
                WriteTarget(accessGroup: sharedGroup, synchronizable: false),
            ])
        }
        return groups
    }

    /// What the Keychain already holds for one `(service, account)`: the
    /// item's access group (nil for the file-based login keychain, which has
    /// no groups) and whether it is an iCloud-synced item.
    public struct ExistingItem: Equatable, Sendable {
        public let accessGroup: String?
        public let synchronizable: Bool
    }

    /// Which copies are missing. Only ever *adds*; nothing is deleted, so a
    /// device on an older build never loses the item it can see.
    ///
    /// - A device-only item (nothing synced) is left alone: it was never
    ///   going to reach another device, so a grouped copy buys nothing.
    /// - `addShared`: a synced item exists but none in the shared group —
    ///   the pre-entitlement layout; copy it in so a same-team client sees it.
    /// - `addDefault`: every item is in the shared group (e.g. minted by a
    ///   client that only wrote there) — copy it to the default group so
    ///   builds without the entitlement can still read it.
    static func mirrorPlan(existing: [ExistingItem], sharedGroup: String) -> (addShared: Bool, addDefault: Bool) {
        guard !existing.isEmpty, existing.contains(where: \.synchronizable) else { return (false, false) }
        let hasShared = existing.contains { $0.accessGroup == sharedGroup }
        let hasDefault = existing.contains { $0.accessGroup != sharedGroup }
        return (addShared: !hasShared, addDefault: !hasDefault)
    }
}
