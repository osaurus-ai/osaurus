//
//  IdentityTestHelpers.swift
//  OsaurusCoreTests
//
//  Shared helpers for identity / access-key tests.
//  Provides deterministic test keys and token builders
//  so tests never touch Keychain or biometric auth.
//

import Foundation
@testable import OsaurusCore

// MARK: - Deterministic Test Keys

/// A pair of (privateKey, osaurusAddress) for use in tests.
/// Private keys are hardcoded hex values known to be valid secp256k1 scalars.
enum TestKeys {
    /// "Alice" — primary test identity.
    static let alicePrivateKey = Data(hexEncoded: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")!
    static var aliceAddress: OsaurusID { try! deriveOsaurusId(from: alicePrivateKey) }

    /// "Bob" — secondary test identity (for cross-identity tests).
    static let bobPrivateKey = Data(hexEncoded: "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")!
    static var bobAddress: OsaurusID { try! deriveOsaurusId(from: bobPrivateKey) }

    /// "Carol" — third identity (for whitelist exclusion tests).
    static let carolPrivateKey = Data(hexEncoded: "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a")!
    static var carolAddress: OsaurusID { try! deriveOsaurusId(from: carolPrivateKey) }
}

// MARK: - Token Builder

/// Build a well-formed osk-v2 token string from components.
/// This bypasses APIKeyManager so tests don't need Keychain.
enum TokenBuilder {
    static func build(
        privateKey: Data,
        iss: OsaurusID,
        aud: OsaurusID,
        nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        cnt: UInt64 = 1,
        iat: Int = Int(Date().timeIntervalSince1970),
        exp: Int? = Int(Date().timeIntervalSince1970) + 3600,
        lbl: String? = "test",
        signingPrefix: String = "Osaurus Signed Access"
    ) throws -> String {
        let payload = AccessKeyPayload(
            aud: aud,
            cnt: cnt,
            exp: exp,
            iat: iat,
            iss: iss,
            lbl: lbl,
            nonce: nonce
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        let signature: Data
        switch signingPrefix {
        case "Osaurus Signed Access":
            signature = try signAccessPayload(payloadData, privateKey: privateKey)
        case "Osaurus Signed Message":
            signature = try signPayload(payloadData, privateKey: privateKey)
        default:
            fatalError("Unknown prefix in test helper")
        }

        return "osk-v2.\(payloadData.base64urlEncoded).\(signature.hexEncodedString)"
    }
}

// MARK: - Test Server Configuration

extension ServerConfiguration {
    /// A `.default` config with `requireAPIKey` disabled, for tests that aren't exercising auth.
    static var testDefault: ServerConfiguration {
        var cfg = ServerConfiguration.default
        cfg.requireAPIKey = false
        return cfg
    }
}

// MARK: - Validator Builder

extension APIKeyValidator {
    /// Build a validator scoped to Alice as both master and agent, with Alice whitelisted.
    static func forAlice(
        agentAddress: OsaurusID? = nil,
        extraWhitelist: Set<OsaurusID> = [],
        revocations: RevocationSnapshot = RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
        hasKeys: Bool = true
    ) -> APIKeyValidator {
        let master = TestKeys.aliceAddress
        let agent = agentAddress ?? master
        var wl: Set<OsaurusID> = [master.lowercased(), agent.lowercased()]
        wl.formUnion(extraWhitelist.map { $0.lowercased() })
        return APIKeyValidator(
            agentAddress: agent,
            masterAddress: master,
            effectiveWhitelist: wl,
            revocationSnapshot: revocations,
            hasKeys: hasKeys
        )
    }
}
