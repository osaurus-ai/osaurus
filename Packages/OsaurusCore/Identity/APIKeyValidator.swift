//
//  APIKeyValidator.swift
//  osaurus
//
//  Immutable, lock-free osk-v1 access key validator.
//  Built once at server start; validates tokens via ecrecover,
//  whitelist, and revocation checks.
//

import Foundation

public struct APIKeyValidator: Sendable {
    private let agentAddress: String
    private let masterAddress: String
    private let whitelist: Set<String>
    private let revocations: RevocationSnapshot
    public let hasKeys: Bool

    /// A no-op validator with no keys and no identity. Used before account setup.
    public static let empty = APIKeyValidator(
        agentAddress: "0x0",
        masterAddress: "0x0",
        effectiveWhitelist: [],
        revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
        hasKeys: false
    )

    public init(
        agentAddress: OsaurusID,
        masterAddress: OsaurusID,
        effectiveWhitelist: Set<OsaurusID>,
        revocationSnapshot: RevocationSnapshot,
        hasKeys: Bool
    ) {
        self.agentAddress = agentAddress.lowercased()
        self.masterAddress = masterAddress.lowercased()
        self.whitelist = Set(effectiveWhitelist.map { $0.lowercased() })
        self.revocations = revocationSnapshot
        self.hasKeys = hasKeys
    }

    public func validate(rawKey: String) -> AccessKeyValidationResult {
        let parts = rawKey.split(separator: ".", maxSplits: 2)
        guard parts.count == 3,
            parts[0] == "osk-v1"
        else {
            return .invalid(reason: "Unrecognized token format")
        }

        guard let payloadData = Data(base64urlEncoded: String(parts[1])) else {
            return .invalid(reason: "Invalid payload encoding")
        }

        guard let signatureData = Data(hexEncoded: String(parts[2])),
            signatureData.count == 65
        else {
            return .invalid(reason: "Invalid signature encoding")
        }

        let payload: AccessKeyPayload
        do {
            payload = try JSONDecoder().decode(AccessKeyPayload.self, from: payloadData)
        } catch {
            return .invalid(reason: "Malformed payload")
        }

        let recoveredAddress: OsaurusID
        do {
            recoveredAddress = try recoverAddress(
                payload: payloadData,
                signature: signatureData,
                domainPrefix: "Osaurus Signed Access"
            )
        } catch {
            return .invalid(reason: "Signature recovery failed")
        }

        guard recoveredAddress.lowercased() == payload.iss.lowercased() else {
            return .invalid(reason: "Issuer mismatch")
        }

        let audLower = payload.aud.lowercased()
        guard audLower == agentAddress || audLower == masterAddress else {
            return .invalid(reason: "Audience mismatch")
        }

        guard whitelist.contains(payload.iss.lowercased()) else {
            return .invalid(reason: "Issuer not whitelisted")
        }

        if revocations.isRevoked(address: payload.iss, nonce: payload.nonce, cnt: payload.cnt) {
            return .revoked
        }

        if let exp = payload.exp {
            let now = Int(Date().timeIntervalSince1970)
            if now >= exp {
                return .expired
            }
        }

        return .valid(issuer: recoveredAddress)
    }
}
