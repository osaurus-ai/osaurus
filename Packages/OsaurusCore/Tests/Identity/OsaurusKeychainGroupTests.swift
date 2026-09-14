//
//  OsaurusKeychainGroupTests.swift
//  OsaurusCoreTests
//
//  The shared Keychain access group is what lets a same-team iOS client see
//  the iCloud-synced master. These tests pin the resolution rule and the
//  attribute-building contract; the live migration (default group → shared
//  group on first unlock, and the `errSecMissingEntitlement` fallback) is a
//  Release-app proof row — see docs/IDENTITY.md — because SwiftPM tests run
//  without the entitlement and with the Keychain disabled.
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
