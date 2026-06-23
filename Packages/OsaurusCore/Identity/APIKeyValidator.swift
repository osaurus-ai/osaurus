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
    /// Lowercased set of every agent address whose scoped keys this validator
    /// accepts. A token's `aud` must equal the master address or be in this
    /// set. The server builds this from ALL of the user's agents so that
    /// agent-scoped keys minted by `/pair` and `/pair-invite` validate.
    private let agentAddresses: Set<String>
    private let masterAddress: String
    private let whitelist: Set<String>
    private let revocations: RevocationSnapshot
    public let hasKeys: Bool

    /// A no-op validator with no keys and no identity. Used before identity setup.
    public static let empty = APIKeyValidator(
        agentAddresses: ["0x0"],
        masterAddress: "0x0",
        effectiveWhitelist: [],
        revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
        hasKeys: false
    )

    /// Designated initializer accepting the full set of accepted agent
    /// audiences.
    public init(
        agentAddresses: Set<OsaurusID>,
        masterAddress: OsaurusID,
        effectiveWhitelist: Set<OsaurusID>,
        revocationSnapshot: RevocationSnapshot,
        hasKeys: Bool
    ) {
        self.agentAddresses = Set(agentAddresses.map { $0.lowercased() })
        self.masterAddress = masterAddress.lowercased()
        self.whitelist = Set(effectiveWhitelist.map { $0.lowercased() })
        self.revocations = revocationSnapshot
        self.hasKeys = hasKeys
    }

    /// Convenience initializer for a single-agent validator (tests, legacy
    /// callers). Wraps the one address into the accepted-audience set.
    public init(
        agentAddress: OsaurusID,
        masterAddress: OsaurusID,
        effectiveWhitelist: Set<OsaurusID>,
        revocationSnapshot: RevocationSnapshot,
        hasKeys: Bool
    ) {
        self.init(
            agentAddresses: [agentAddress],
            masterAddress: masterAddress,
            effectiveWhitelist: effectiveWhitelist,
            revocationSnapshot: revocationSnapshot,
            hasKeys: hasKeys
        )
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
        guard audLower == masterAddress || agentAddresses.contains(audLower) else {
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

        return .valid(issuer: recoveredAddress, audience: payload.aud, keyNonce: payload.nonce)
    }

    /// Whether the given audience is the master address (an unrestricted,
    /// all-agent key) rather than an agent-scoped one. Callers use this to
    /// decide whether to enforce per-agent route scoping.
    public func isMasterScoped(audience: OsaurusID) -> Bool {
        audience.lowercased() == masterAddress
    }
}
