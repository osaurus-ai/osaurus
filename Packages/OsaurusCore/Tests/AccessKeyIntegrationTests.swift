//
//  AccessKeyIntegrationTests.swift
//  OsaurusCoreTests
//
//  End-to-end tests that build osk-v1 tokens the same way
//  APIKeyManager.generate() does, then validate them through
//  APIKeyValidator — exercising the full pipeline without
//  Keychain or biometric dependencies.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AccessKeyIntegrationTests {

    // MARK: - Full Pipeline: Master Key

    @Test func masterKey_generateAndValidate_roundtrip() throws {
        let masterKey = TestKeys.alicePrivateKey
        let masterAddress = TestKeys.aliceAddress
        let nonce = "e2e00000000000000000000000000001"

        let token = try TokenBuilder.build(
            privateKey: masterKey,
            iss: masterAddress,
            aud: masterAddress,
            nonce: nonce,
            cnt: 1
        )

        #expect(token.hasPrefix("osk-v1."))
        let parts = token.split(separator: ".", maxSplits: 2)
        #expect(parts.count == 3)

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(issuer.lowercased() == masterAddress.lowercased())
    }

    // MARK: - Full Pipeline: Agent Key

    @Test func agentKey_generateAndValidate_roundtrip() throws {
        let masterKey = TestKeys.alicePrivateKey
        let agentIndex: UInt32 = 3
        let agentChildKey = AgentKey.derive(masterKey: masterKey, index: agentIndex)
        let agentAddress = try AgentKey.deriveAddress(masterKey: masterKey, index: agentIndex)

        let nonce = "e2e00000000000000000000000000002"
        let token = try TokenBuilder.build(
            privateKey: agentChildKey,
            iss: agentAddress,
            aud: agentAddress,
            nonce: nonce,
            cnt: 5
        )

        let validator = APIKeyValidator.forAlice(
            agentAddress: agentAddress,
            extraWhitelist: [agentAddress]
        )
        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid for agent key, got \(result)")
            return
        }
        #expect(issuer.lowercased() == agentAddress.lowercased())
    }

    // MARK: - Master Signs for Agent Scope

    @Test func masterSigned_agentAudience_validOnAgentValidator() throws {
        let masterKey = TestKeys.alicePrivateKey
        let masterAddress = TestKeys.aliceAddress
        let agentAddress = try AgentKey.deriveAddress(masterKey: masterKey, index: 0)

        let token = try TokenBuilder.build(
            privateKey: masterKey,
            iss: masterAddress,
            aud: masterAddress
        )

        let validator = APIKeyValidator.forAlice(agentAddress: agentAddress)
        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Master-scoped token should be accepted by agent validator, got \(result)")
            return
        }
    }

    // MARK: - Agent Token Rejected by Different Agent

    @Test func agentToken_rejectedByDifferentAgent() throws {
        let masterKey = TestKeys.alicePrivateKey
        let agent0Key = AgentKey.derive(masterKey: masterKey, index: 0)
        let agent0Address = try AgentKey.deriveAddress(masterKey: masterKey, index: 0)
        let agent1Address = try AgentKey.deriveAddress(masterKey: masterKey, index: 1)

        let token = try TokenBuilder.build(
            privateKey: agent0Key,
            iss: agent0Address,
            aud: agent0Address
        )

        let validatorForAgent1 = APIKeyValidator.forAlice(
            agentAddress: agent1Address,
            extraWhitelist: [agent0Address]
        )
        let result = validatorForAgent1.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Agent0 token should fail on Agent1's validator, got \(result)")
            return
        }
        #expect(reason.contains("Audience"))
    }

    // MARK: - Whitelist Gating: External Issuer

    @Test func externalIssuer_whitelisted_generatesValidToken() throws {
        let bobToken = try TokenBuilder.build(
            privateKey: TestKeys.bobPrivateKey,
            iss: TestKeys.bobAddress,
            aud: TestKeys.aliceAddress
        )

        let validatorWithBob = APIKeyValidator.forAlice(extraWhitelist: [TestKeys.bobAddress])
        let result = validatorWithBob.validate(rawKey: bobToken)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid for whitelisted Bob, got \(result)")
            return
        }
        #expect(issuer.lowercased() == TestKeys.bobAddress.lowercased())

        let validatorWithoutBob = APIKeyValidator.forAlice()
        let rejected = validatorWithoutBob.validate(rawKey: bobToken)
        guard case .invalid(let reason) = rejected else {
            Issue.record("Expected .invalid when Bob not whitelisted, got \(rejected)")
            return
        }
        #expect(reason.contains("whitelisted"))
    }

    // MARK: - Revoke Then Validate

    @Test func revokeByNonce_thenValidate_rejected() throws {
        let nonce = "to_be_revoked_nonce"
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: nonce,
            cnt: 10
        )

        let preRevoke = APIKeyValidator.forAlice()
        guard case .valid = preRevoke.validate(rawKey: token) else {
            Issue.record("Token should be valid before revocation")
            return
        }

        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: nonce)
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let postRevoke = APIKeyValidator.forAlice(revocations: snapshot)

        guard case .revoked = postRevoke.validate(rawKey: token) else {
            Issue.record("Token should be revoked after nonce revocation")
            return
        }
    }

    @Test func bulkRevoke_thenValidate_olderKeysRejected() throws {
        let oldToken = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            cnt: 5
        )
        let newToken = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            cnt: 15
        )

        let snapshot = RevocationSnapshot(
            revokedKeys: [],
            counterThresholds: [TestKeys.aliceAddress.lowercased(): 10]
        )
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        guard case .revoked = validator.validate(rawKey: oldToken) else {
            Issue.record("Old token (cnt=5) should be revoked with threshold 10")
            return
        }
        guard case .valid = validator.validate(rawKey: newToken) else {
            Issue.record("New token (cnt=15) should still be valid with threshold 10")
            return
        }
    }

    // MARK: - Token Format Integrity

    @Test func tokenFormat_threePartsWithCorrectPrefix() throws {
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let parts = token.split(separator: ".", maxSplits: 2)
        #expect(parts.count == 3)
        #expect(parts[0] == "osk-v1")

        let payloadData = Data(base64urlEncoded: String(parts[1]))
        #expect(payloadData != nil)

        let sigData = Data(hexEncoded: String(parts[2]))
        #expect(sigData != nil)
        #expect(sigData?.count == 65)
    }

    @Test func tokenPayload_containsExpectedFields() throws {
        let now = Int(Date().timeIntervalSince1970)
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "fieldcheck",
            cnt: 42,
            iat: now,
            exp: now + 3600,
            lbl: "my label"
        )

        let parts = token.split(separator: ".", maxSplits: 2)
        let payloadData = Data(base64urlEncoded: String(parts[1]))!
        let payload = try JSONDecoder().decode(AccessKeyPayload.self, from: payloadData)

        #expect(payload.iss.lowercased() == TestKeys.aliceAddress.lowercased())
        #expect(payload.aud.lowercased() == TestKeys.aliceAddress.lowercased())
        #expect(payload.nonce == "fieldcheck")
        #expect(payload.cnt == 42)
        #expect(payload.iat == now)
        #expect(payload.exp == now + 3600)
        #expect(payload.lbl == "my label")
    }

    // MARK: - Multiple Keys: Independent Validation

    @Test func multipleKeys_independentlyValid() throws {
        let validator = APIKeyValidator.forAlice()

        let token1 = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "key1"
        )
        let token2 = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "key2"
        )

        guard case .valid = validator.validate(rawKey: token1) else {
            Issue.record("Token 1 should be valid")
            return
        }
        guard case .valid = validator.validate(rawKey: token2) else {
            Issue.record("Token 2 should be valid")
            return
        }

        #expect(token1 != token2)
    }

    @Test func revokeOneKey_otherStillValid() throws {
        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: "key1")
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token1 = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "key1"
        )
        let token2 = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "key2"
        )

        guard case .revoked = validator.validate(rawKey: token1) else {
            Issue.record("Token 1 should be revoked")
            return
        }
        guard case .valid = validator.validate(rawKey: token2) else {
            Issue.record("Token 2 should still be valid")
            return
        }
    }
}
