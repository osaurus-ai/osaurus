//
//  LegacyKeyDetectionTests.swift
//  OsaurusCoreTests
//
//  Verifies the predicate that classifies a key as a pre-#950 master-scoped
//  paired credential. The migration banner relies on this to flag old keys
//  so users can choose to revoke + re-pair with stricter scope.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("APIKeyManager.isLegacyMasterScopedKey")
struct LegacyKeyDetectionTests {

    private func makeKey(
        label: String = "Paired – device.local",
        aud: String,
        expiration: AccessKeyExpiration,
        revoked: Bool = false,
        expiresAt: Date? = nil
    ) -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: label,
            prefix: "osk-v1.aaa",
            nonce: "nonce-\(UUID().uuidString)",
            cnt: 1,
            iss: aud,
            aud: aud,
            createdAt: Date(),
            expiration: expiration,
            expiresAt: expiresAt,
            revoked: revoked
        )
    }

    @Test
    func masterScopedNeverExpiring_isLegacy() {
        let agentAddrs: Set<String> = ["0xagent1", "0xagent2"]
        let key = makeKey(aud: "0xMASTER", expiration: .never)
        #expect(
            APIKeyManager.isLegacyMasterScopedKey(key, knownAgentAddressesLower: agentAddrs)
        )
    }

    @Test
    func agentScopedNeverExpiring_isNotLegacy() {
        // Agent-scoped key whose audience matches a known agent address —
        // the new pair flow's shape (sans the 90-day expiry).
        let agentAddrs: Set<String> = ["0xagent1"]
        let key = makeKey(aud: "0xagent1", expiration: .never)
        #expect(
            !APIKeyManager.isLegacyMasterScopedKey(key, knownAgentAddressesLower: agentAddrs)
        )
    }

    @Test
    func masterScopedFiniteExpiry_isNotLegacy() {
        // A user might intentionally generate a 90-day all-agents key from
        // the Settings UI. That isn't the audit issue and shouldn't be
        // flagged as legacy.
        let agentAddrs: Set<String> = ["0xagent1"]
        let key = makeKey(
            aud: "0xMASTER",
            expiration: .days90,
            expiresAt: Calendar.current.date(byAdding: .day, value: 89, to: Date())
        )
        #expect(
            !APIKeyManager.isLegacyMasterScopedKey(key, knownAgentAddressesLower: agentAddrs)
        )
    }

    @Test
    func revokedKey_isNotLegacy() {
        let agentAddrs: Set<String> = ["0xagent1"]
        let key = makeKey(aud: "0xMASTER", expiration: .never, revoked: true)
        #expect(
            !APIKeyManager.isLegacyMasterScopedKey(key, knownAgentAddressesLower: agentAddrs)
        )
    }

    @Test
    func audienceComparison_isCaseInsensitive() {
        // Agent address coming back from the validator is lower-cased; if
        // the stored key has mixed casing in `aud` we should still match.
        let agentAddrs: Set<String> = ["0xagentupper"]
        let key = makeKey(aud: "0xAGENTUPPER", expiration: .never)
        #expect(
            !APIKeyManager.isLegacyMasterScopedKey(key, knownAgentAddressesLower: agentAddrs)
        )
    }
}
