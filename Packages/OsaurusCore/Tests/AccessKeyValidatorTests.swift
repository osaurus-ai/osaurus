//
//  AccessKeyValidatorTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct AccessKeyValidatorTests {

    // MARK: - Happy Path

    @Test func validToken_masterSigned_passes() throws {
        let validator = APIKeyValidator.forAlice()
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(issuer.lowercased() == TestKeys.aliceAddress.lowercased())
    }

    @Test func validToken_nonExpiringKey() throws {
        let validator = APIKeyValidator.forAlice()
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            exp: nil
        )

        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
    }

    @Test func validToken_agentSigned_audienceMatchesAgent() throws {
        let agentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let agentChildKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0)

        let validator = APIKeyValidator.forAlice(
            agentAddress: agentAddress,
            extraWhitelist: [agentAddress]
        )

        let token = try TokenBuilder.build(
            privateKey: agentChildKey,
            iss: agentAddress,
            aud: agentAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(issuer.lowercased() == agentAddress.lowercased())
    }

    @Test func validToken_masterSigned_audienceIsMaster_validForAgentValidator() throws {
        let agentAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
        let validator = APIKeyValidator.forAlice(agentAddress: agentAddress)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Expected .valid (master audience accepted by agent validator), got \(result)")
            return
        }
    }

    // MARK: - Tampered Token

    @Test func tamperedPayload_rejected() throws {
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let parts = token.split(separator: ".", maxSplits: 2)
        var payloadChars = Array(String(parts[1]))
        let idx = payloadChars.count / 2
        payloadChars[idx] = payloadChars[idx] == "A" ? "B" : "A"
        let tampered = "osk-v1.\(String(payloadChars)).\(parts[2])"

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: tampered)
        guard case .invalid = result else {
            Issue.record("Expected .invalid for tampered payload, got \(result)")
            return
        }
    }

    @Test func tamperedSignature_rejected() throws {
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        let parts = token.split(separator: ".", maxSplits: 2)
        var sigHex = String(parts[2])
        let idx = sigHex.index(sigHex.startIndex, offsetBy: 10)
        let original = sigHex[idx]
        let replacement: Character = original == "a" ? "b" : "a"
        sigHex.replaceSubrange(idx ... idx, with: String(replacement))
        let tampered = "osk-v1.\(parts[1]).\(sigHex)"

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: tampered)

        switch result {
        case .valid(let issuer):
            #expect(
                issuer.lowercased() != TestKeys.aliceAddress.lowercased(),
                "Tampered sig should not recover to original address"
            )
        case .invalid:
            break
        default:
            Issue.record("Expected .invalid or mismatched .valid, got \(result)")
        }
    }

    // MARK: - Wrong Audience

    @Test func wrongAudience_rejected() throws {
        let validator = APIKeyValidator.forAlice()

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.bobAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for wrong audience, got \(result)")
            return
        }
        #expect(reason.contains("Audience"))
    }

    // MARK: - Issuer Not Whitelisted

    @Test func issuerNotWhitelisted_rejected() throws {
        let validator = APIKeyValidator.forAlice()

        let token = try TokenBuilder.build(
            privateKey: TestKeys.bobPrivateKey,
            iss: TestKeys.bobAddress,
            aud: TestKeys.aliceAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for non-whitelisted issuer, got \(result)")
            return
        }
        #expect(reason.contains("whitelisted"))
    }

    @Test func whitelistedExternalIssuer_passes() throws {
        let validator = APIKeyValidator.forAlice(extraWhitelist: [TestKeys.bobAddress])

        let token = try TokenBuilder.build(
            privateKey: TestKeys.bobPrivateKey,
            iss: TestKeys.bobAddress,
            aud: TestKeys.aliceAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .valid(let issuer) = result else {
            Issue.record("Expected .valid for whitelisted Bob, got \(result)")
            return
        }
        #expect(issuer.lowercased() == TestKeys.bobAddress.lowercased())
    }

    // MARK: - Issuer Mismatch (forged iss field)

    @Test func forgedIssuer_rejected() throws {
        let validator = APIKeyValidator.forAlice(extraWhitelist: [TestKeys.bobAddress])

        let token = try TokenBuilder.build(
            privateKey: TestKeys.carolPrivateKey,
            iss: TestKeys.bobAddress,
            aud: TestKeys.aliceAddress
        )

        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for forged issuer, got \(result)")
            return
        }
        #expect(reason.contains("Issuer mismatch"))
    }

    // MARK: - Revocation

    @Test func individuallyRevokedKey_rejected() throws {
        let nonce = "revoked_nonce_12345"
        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: nonce)
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: nonce
        )

        let result = validator.validate(rawKey: token)
        guard case .revoked = result else {
            Issue.record("Expected .revoked, got \(result)")
            return
        }
    }

    @Test func bulkRevokedKey_counterBelowThreshold_rejected() throws {
        let snapshot = RevocationSnapshot(
            revokedKeys: [],
            counterThresholds: [TestKeys.aliceAddress.lowercased(): 100]
        )
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            cnt: 50
        )

        let result = validator.validate(rawKey: token)
        guard case .revoked = result else {
            Issue.record("Expected .revoked for bulk revocation, got \(result)")
            return
        }
    }

    @Test func bulkRevocation_counterAboveThreshold_passes() throws {
        let snapshot = RevocationSnapshot(
            revokedKeys: [],
            counterThresholds: [TestKeys.aliceAddress.lowercased(): 100]
        )
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            cnt: 101
        )

        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Expected .valid for counter above threshold, got \(result)")
            return
        }
    }

    @Test func revokedKey_nonRevokedNonce_passes() throws {
        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: "bad_nonce")
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: "good_nonce"
        )

        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Expected .valid for non-revoked nonce, got \(result)")
            return
        }
    }

    // MARK: - Expiration

    @Test func expiredKey_rejected() throws {
        let validator = APIKeyValidator.forAlice()
        let pastTimestamp = Int(Date().timeIntervalSince1970) - 3600

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            exp: pastTimestamp
        )

        let result = validator.validate(rawKey: token)
        guard case .expired = result else {
            Issue.record("Expected .expired, got \(result)")
            return
        }
    }

    @Test func futureExpiration_passes() throws {
        let validator = APIKeyValidator.forAlice()
        let futureTimestamp = Int(Date().timeIntervalSince1970) + 86400

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            exp: futureTimestamp
        )

        let result = validator.validate(rawKey: token)
        guard case .valid = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
    }

    // MARK: - Malformed Tokens

    @Test func emptyString_rejected() {
        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: "")
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for empty string, got \(result)")
            return
        }
        #expect(reason.contains("Unrecognized"))
    }

    @Test func wrongPrefix_rejected() {
        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: "osk-v0.abc.def")
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for wrong prefix, got \(result)")
            return
        }
        #expect(reason.contains("Unrecognized"))
    }

    @Test func missingParts_rejected() {
        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: "osk-v1.onlypayload")
        guard case .invalid = result else {
            Issue.record("Expected .invalid for missing parts")
            return
        }
    }

    @Test func invalidBase64_rejected() {
        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: "osk-v1.!!!invalid!!!.00" + String(repeating: "aa", count: 65))
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for bad base64, got \(result)")
            return
        }
        #expect(reason.contains("payload") || reason.contains("encoding"))
    }

    @Test func invalidHexSignature_rejected() throws {
        let payload = AccessKeyPayload(
            aud: "0x0",
            cnt: 1,
            exp: nil,
            iat: 1,
            iss: "0x0",
            lbl: nil,
            nonce: "n"
        )
        let data = try JSONEncoder().encode(payload)
        let token = "osk-v1.\(data.base64urlEncoded).NOT_HEX_AT_ALL"

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for bad hex sig, got \(result)")
            return
        }
        #expect(reason.contains("signature") || reason.contains("encoding"))
    }

    @Test func shortSignature_rejected() throws {
        let payload = AccessKeyPayload(
            aud: "0x0",
            cnt: 1,
            exp: nil,
            iat: 1,
            iss: "0x0",
            lbl: nil,
            nonce: "n"
        )
        let data = try JSONEncoder().encode(payload)
        let shortSigHex = String(repeating: "00", count: 32)
        let token = "osk-v1.\(data.base64urlEncoded).\(shortSigHex)"

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for short signature, got \(result)")
            return
        }
        #expect(reason.contains("signature") || reason.contains("encoding"))
    }

    @Test func malformedPayloadJSON_rejected() {
        let badPayload = Data("not json at all".utf8).base64urlEncoded
        let sigHex = String(repeating: "00", count: 65)
        let token = "osk-v1.\(badPayload).\(sigHex)"

        let validator = APIKeyValidator.forAlice()
        let result = validator.validate(rawKey: token)
        guard case .invalid(let reason) = result else {
            Issue.record("Expected .invalid for malformed JSON, got \(result)")
            return
        }
        #expect(reason.contains("Malformed"))
    }

    // MARK: - Empty Validator

    @Test func emptyValidator_hasKeysFalse() {
        #expect(APIKeyValidator.empty.hasKeys == false)
    }

    @Test func emptyValidator_rejectsValidToken() throws {
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: "0x0"
        )
        let result = APIKeyValidator.empty.validate(rawKey: token)
        guard case .invalid = result else {
            Issue.record("Expected .invalid from empty validator, got \(result)")
            return
        }
    }

    // MARK: - Cross-Protocol Replay

    @Test func crossProtocolReplay_signedAsMessage_rejectedAsAccessKey() throws {
        let validator = APIKeyValidator.forAlice()

        let payload = AccessKeyPayload(
            aud: TestKeys.aliceAddress,
            cnt: 1,
            exp: Int(Date().timeIntervalSince1970) + 3600,
            iat: Int(Date().timeIntervalSince1970),
            iss: TestKeys.aliceAddress,
            lbl: "replay",
            nonce: "replay123"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        // Sign with Message prefix instead of Access prefix
        let wrongSig = try signPayload(payloadData, privateKey: TestKeys.alicePrivateKey)
        let token = "osk-v1.\(payloadData.base64urlEncoded).\(wrongSig.hexEncodedString)"

        let result = validator.validate(rawKey: token)
        switch result {
        case .valid(let issuer):
            #expect(
                issuer.lowercased() != TestKeys.aliceAddress.lowercased(),
                "Cross-protocol replay must not validate as the original signer"
            )
        case .invalid:
            break
        default:
            Issue.record("Expected .invalid or mismatched .valid for cross-protocol replay, got \(result)")
        }
    }

    // MARK: - Validation Order (revocation before expiration)

    @Test func revokedAndExpired_returnsRevoked() throws {
        let nonce = "both_revoked_and_expired"
        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: nonce)
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let validator = APIKeyValidator.forAlice(revocations: snapshot)

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: nonce,
            exp: Int(Date().timeIntervalSince1970) - 3600
        )

        let result = validator.validate(rawKey: token)
        guard case .revoked = result else {
            Issue.record("Expected .revoked (takes priority over expired), got \(result)")
            return
        }
    }
}
