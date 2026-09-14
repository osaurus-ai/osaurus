//
//  OsaurusKeychainGroupTests.swift
//  OsaurusCoreTests
//
//  The shared Keychain access group is what lets a same-team iOS client see
//  the iCloud-synced master. These tests pin the resolution rule, the
//  dual-write order, and the add-only mirror plan; the live Keychain rows
//  (grouped copy appears on first unlock, an older build on a second Mac
//  keeps unlocking, `errSecMissingEntitlement` fallback) are Release-app
//  proof rows — see docs/IDENTITY.md — because SwiftPM tests run without the
//  entitlement and with the Keychain disabled.
//

import Foundation
import Security
import Testing

@testable import OsaurusCore

@Suite("OsaurusKeychainGroup", .serialized)
struct OsaurusKeychainGroupTests {

    @Test func resolve_acceptsExpandedTeamPrefixedGroup() {
        #expect(
            OsaurusKeychainGroup.resolve(infoValue: "4W8QF9VR2F.ai.osaurus.identity")
                == "4W8QF9VR2F.ai.osaurus.identity"
        )
        #expect(
            OsaurusKeychainGroup.resolve(infoValue: "  4W8QF9VR2F.ai.osaurus.identity\n")
                == "4W8QF9VR2F.ai.osaurus.identity"
        )
    }

    @Test func resolve_rejectsMissingEmptyUnexpandedOrForeign() {
        #expect(OsaurusKeychainGroup.resolve(infoValue: nil) == nil)
        #expect(OsaurusKeychainGroup.resolve(infoValue: "") == nil)
        #expect(OsaurusKeychainGroup.resolve(infoValue: "   ") == nil)
        // Xcode didn't expand the build setting (e.g. plist copied verbatim).
        #expect(OsaurusKeychainGroup.resolve(infoValue: "$(AppIdentifierPrefix)ai.osaurus.identity") == nil)
        // Bare suffix without a team prefix can't be a real group.
        #expect(OsaurusKeychainGroup.resolve(infoValue: "ai.osaurus.identity") == nil)
        // Some other group must not be mistaken for ours.
        #expect(OsaurusKeychainGroup.resolve(infoValue: "4W8QF9VR2F.com.dinoki.osaurus") == nil)
    }

    @Test func swiftPMHarness_hasNoGroup_soWritesStayInDefaultGroup() {
        // No Info.plist in the test bundle → nil → no `kSecAttrAccessGroup`
        // is ever added. This is the "dev builds keep working" contract.
        OsaurusKeychainGroup.overrideForTesting = nil
        #expect(OsaurusKeychainGroup.shared == nil)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        OsaurusKeychainGroup.apply(to: &query)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func apply_addsGroupWhenResolved() {
        OsaurusKeychainGroup.overrideForTesting = .some("4W8QF9VR2F.ai.osaurus.identity")
        defer { OsaurusKeychainGroup.overrideForTesting = nil }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        OsaurusKeychainGroup.apply(to: &query)
        #expect(query[kSecAttrAccessGroup as String] as? String == "4W8QF9VR2F.ai.osaurus.identity")
    }

    @Test func override_canForceNoGroup() {
        OsaurusKeychainGroup.overrideForTesting = .some(nil)
        defer { OsaurusKeychainGroup.overrideForTesting = nil }
        #expect(OsaurusKeychainGroup.shared == nil)
    }

    @Test func missingEntitlementStatus_isErrSecMissingEntitlement() {
        #expect(OsaurusKeychainGroup.missingEntitlementStatus == errSecMissingEntitlement)
    }

    // MARK: dual-write order

    private typealias Target = OsaurusKeychainGroup.WriteTarget
    private let group = "4W8QF9VR2F.ai.osaurus.identity"

    /// The default group is written first and unconditionally: a Mac still
    /// on a build without the entitlement can only read that group, so it
    /// is the copy that keeps a mixed-version fleet on one master. The
    /// shared group is an additional copy, never the only one.
    @Test func writeAttempts_defaultGroupFirstAndAlways_sharedGroupAsExtraCopy() {
        let plan = OsaurusKeychainGroup.writeAttemptGroups(sharedGroup: group)
        #expect(
            plan == [
                [Target(accessGroup: nil, synchronizable: true), Target(accessGroup: nil, synchronizable: false)],
                [Target(accessGroup: group, synchronizable: true), Target(accessGroup: group, synchronizable: false)],
            ]
        )
    }

    @Test func writeAttempts_withoutGroup_isExactlyThePreviousLayout() {
        for sharedGroup in [nil, ""] as [String?] {
            #expect(
                OsaurusKeychainGroup.writeAttemptGroups(sharedGroup: sharedGroup) == [
                    [Target(accessGroup: nil, synchronizable: true), Target(accessGroup: nil, synchronizable: false)]
                ]
            )
        }
    }

    // MARK: mirror plan (add-only)

    private typealias Item = OsaurusKeychainGroup.ExistingItem

    /// Pre-entitlement layout: one synced item in the app's default group.
    /// Copy it into the shared group; the original stays (no delete).
    @Test func mirror_preEntitlementSyncedItem_addsSharedCopyOnly() {
        let plan = OsaurusKeychainGroup.mirrorPlan(
            existing: [Item(accessGroup: "4W8QF9VR2F.ai.osaurus", synchronizable: true)],
            sharedGroup: group
        )
        #expect(plan.addShared)
        #expect(!plan.addDefault)
    }

    /// Both copies present (already mirrored, or written by a dual-write
    /// build): nothing to do — the mirror must be idempotent.
    @Test func mirror_bothCopiesPresent_isNoop() {
        let plan = OsaurusKeychainGroup.mirrorPlan(
            existing: [
                Item(accessGroup: "4W8QF9VR2F.ai.osaurus", synchronizable: true),
                Item(accessGroup: group, synchronizable: true),
            ],
            sharedGroup: group
        )
        #expect(!plan.addShared)
        #expect(!plan.addDefault)
    }

    /// Only a shared-group copy (e.g. minted by a client that wrote just
    /// there): mirror it back to the default group so builds without the
    /// entitlement can still unlock.
    @Test func mirror_onlySharedCopy_addsDefaultCopy() {
        let plan = OsaurusKeychainGroup.mirrorPlan(
            existing: [Item(accessGroup: group, synchronizable: true)],
            sharedGroup: group
        )
        #expect(!plan.addShared)
        #expect(plan.addDefault)
    }

    /// A device-only master — in the data-protection default group or in
    /// the file-based login keychain (no access group at all) — is left
    /// exactly where it is. It was never going to reach another device, so
    /// a grouped copy would buy nothing.
    @Test func mirror_deviceOnlyItem_isLeftAlone() {
        for existing in [
            [Item(accessGroup: "4W8QF9VR2F.ai.osaurus", synchronizable: false)],
            [Item(accessGroup: nil, synchronizable: false)],
        ] {
            let plan = OsaurusKeychainGroup.mirrorPlan(existing: existing, sharedGroup: group)
            #expect(!plan.addShared)
            #expect(!plan.addDefault)
        }
    }

    @Test func mirror_nothingStored_isNoop() {
        let plan = OsaurusKeychainGroup.mirrorPlan(existing: [], sharedGroup: group)
        #expect(!plan.addShared)
        #expect(!plan.addDefault)
    }

    /// Login-keychain items report no access group; that still counts as
    /// "a default-layout copy exists", so only the shared copy is added.
    @Test func mirror_ungroupedSyncedItem_countsAsDefaultCopy() {
        let plan = OsaurusKeychainGroup.mirrorPlan(
            existing: [Item(accessGroup: nil, synchronizable: true)],
            sharedGroup: group
        )
        #expect(plan.addShared)
        #expect(!plan.addDefault)
    }

    /// Keychain-disabled harness: install/store must still refuse to write
    /// (they throw before any `SecItemAdd`), with or without a group.
    @Test func disabledKeychain_installAndStoreStillRefuse() {
        guard KeychainQueryHelpers.disablesKeychainForProcess else { return }
        OsaurusKeychainGroup.overrideForTesting = .some("4W8QF9VR2F.ai.osaurus.identity")
        defer { OsaurusKeychainGroup.overrideForTesting = nil }
        #expect(throws: OsaurusIdentityError.self) {
            try MasterKey.install(seed: Data(repeating: 7, count: 32), allowReplace: true)
        }
        #expect(throws: OsaurusIdentityError.self) {
            try MasterMnemonicStore.store(Array(repeating: "abandon", count: 24))
        }
    }
}
