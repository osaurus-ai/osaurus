import CryptoKit
import Foundation

//  Membership attestations — the router-minted, host-verified token behind
//  workspace agent access. The router signs (Ed25519) a short-lived JSON payload
//  proving "this wallet is an active member of this workspace"; a host verifies it
//  OFFLINE against the router's published public key and mints an
//  agent-scoped access key in exchange. TTL is 10 minutes and doubles as the
//  revocation mechanism: hosts bind key validity to attestation freshness.

// MARK: - Wire types

/// `POST /workspaces/:id/attestation` → `{ attestation, expires_at }`.
struct OsaurusRouterWorkspaceAttestationResponse: Decodable, Equatable, Sendable {
    let attestation: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case attestation
        case expiresAt = "expires_at"
    }
}

/// `GET /workspaces/attestation-key` (public, cacheable ≤1h) →
/// `{ alg: "Ed25519", public_key: base64url(32 bytes) }`.
struct OsaurusRouterWorkspaceAttestationKeyResponse: Decodable, Equatable, Sendable {
    let alg: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case alg
        case publicKey = "public_key"
    }
}

// MARK: - Token

enum WorkspaceAttestationError: Error, Equatable {
    /// Not two base64url segments joined by `.`.
    case malformedToken
    /// The published key isn't a 32-byte Ed25519 key.
    case malformedPublicKey
    /// Ed25519 signature doesn't verify over the payload bytes.
    case badSignature
    /// `v` is not a version this client understands.
    case unsupportedVersion
    /// `exp` has passed.
    case expired
}

/// A parsed and signature-verified membership attestation.
struct WorkspaceMembershipAttestation: Equatable, Sendable {
    struct Payload: Decodable, Equatable, Sendable {
        let v: Int
        let workspaceId: String
        let accountId: String
        /// The member's wallet address, lowercase.
        let wallet: String
        let role: String
        let iat: Int
        let exp: Int

        enum CodingKeys: String, CodingKey {
            case v, wallet, role, iat, exp
            case workspaceId = "workspace_id"
            /// Pre-rename claim name. Legacy tokens expire within 10 minutes
            /// of the router upgrade, but accept them so a handshake in flight
            /// across the cutover doesn't fail.
            case legacyWorkspaceId = "team_id"
            case accountId = "account_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decode(Int.self, forKey: .v)
            if let id = try c.decodeIfPresent(String.self, forKey: .workspaceId) {
                workspaceId = id
            } else {
                workspaceId = try c.decode(String.self, forKey: .legacyWorkspaceId)
            }
            accountId = try c.decode(String.self, forKey: .accountId)
            wallet = try c.decode(String.self, forKey: .wallet)
            role = try c.decode(String.self, forKey: .role)
            iat = try c.decode(Int.self, forKey: .iat)
            exp = try c.decode(Int.self, forKey: .exp)
        }

        /// Unknown/future roles read as `.viewer` — least privilege.
        var typedRole: OsaurusRouterWorkspaceRole {
            OsaurusRouterWorkspaceRole(rawValue: role) ?? .viewer
        }
    }

    /// The original compact token, for re-presentation (e.g.
    /// `workspace_context.caller_attestation`).
    let token: String
    let payload: Payload

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(payload.exp)) }

    /// Full offline verification per the spec:
    /// 1. split on `.`, base64url-decode both segments,
    /// 2. verify the 64-byte Ed25519 signature over the RAW payload bytes
    ///    (never re-serialize the JSON before verifying),
    /// 3. parse the JSON; require `v == 1` and `exp > now`.
    ///
    /// Checking that `workspace_id` is one the caller cares about stays with the
    /// caller — it needs host-local state.
    static func verify(
        token: String,
        publicKeyBase64URL: String,
        now: Date = Date()
    ) throws -> WorkspaceMembershipAttestation {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 2,
            let payloadData = Data(base64urlEncoded: String(segments[0])),
            let signature = Data(base64urlEncoded: String(segments[1])),
            signature.count == 64
        else {
            throw WorkspaceAttestationError.malformedToken
        }

        guard let keyData = Data(base64urlEncoded: publicKeyBase64URL),
            keyData.count == 32,
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            throw WorkspaceAttestationError.malformedPublicKey
        }

        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw WorkspaceAttestationError.badSignature
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw WorkspaceAttestationError.malformedToken
        }
        guard payload.v == 1 else { throw WorkspaceAttestationError.unsupportedVersion }
        guard TimeInterval(payload.exp) > now.timeIntervalSince1970 else {
            throw WorkspaceAttestationError.expired
        }
        return WorkspaceMembershipAttestation(token: token, payload: payload)
    }

    /// Parse the payload WITHOUT signature verification. The redeeming
    /// teammate uses this to read its own attestation's `exp` for refresh
    /// scheduling — it has no reason to verify a token minted for it by the
    /// router over an authenticated channel. Hosts must use `verify`.
    static func unverifiedPayload(token: String) -> Payload? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 2,
            let payloadData = Data(base64urlEncoded: String(segments[0]))
        else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: payloadData)
    }
}

// MARK: - Redeem challenge

/// Shared constants for the attestation → access-key handshake between a
/// teammate's Osaurus and the sharer's (host) Osaurus.
enum WorkspaceAgentAccess {
    /// The message a redeeming teammate signs (EIP-191, MASTER key — the
    /// signer must recover to the attestation's `wallet`) over the host's
    /// single-use nonce.
    static func redeemMessage(agentAddress: String, nonce: String) -> String {
        "osaurus-workspaces:redeem:\(agentAddress.lowercased()):\(nonce)"
    }

    /// The pre-rename challenge wording. Hosts accept a signature over either
    /// so a teammate on an older build can still pair; new clients sign only
    /// `redeemMessage`.
    static func legacyRedeemMessage(agentAddress: String, nonce: String) -> String {
        "osaurus-teams:redeem:\(agentAddress.lowercased()):\(nonce)"
    }

    /// Refresh attestations at 80% of their TTL while a workspace session is live.
    static let refreshFraction: Double = 0.8

    /// How long a host-issued redeem nonce stays valid.
    static let challengeTTL: TimeInterval = 120
}

// MARK: - Redeem wire shapes (teammate Osaurus ⇄ host Osaurus)

/// The workspace-mode extension of `POST /pair-invite`. Both steps of the
/// handshake use the same envelope: step one carries only the attestation
/// (host answers with a nonce challenge), step two adds the nonce and the
/// wallet signature (host answers with the agent-scoped access key).
struct WorkspacePairRedeemEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let v: Int
        /// Which shared agent on the host is being redeemed.
        let agentAddress: String
        /// The compact router-minted membership attestation.
        let attestation: String
        /// Step two only: the host's single-use challenge nonce.
        let nonce: String?
        /// Step two only: EIP-191 master-key signature over
        /// `osaurus-workspaces:redeem:<agent_address_lowercase>:<nonce>` —
        /// must recover to the attestation's `wallet`.
        let walletSignature: String?
        /// Step two only: ephemeral X25519 key for HPKE-sealing the minted
        /// credential (same contract as the invite flow).
        let encPub: String?

        enum CodingKeys: String, CodingKey {
            case v, attestation, nonce, encPub
            case agentAddress = "agent_address"
            case walletSignature = "wallet_signature"
        }
    }

    let workspaceRedeem: Payload

    enum CodingKeys: String, CodingKey {
        case workspaceRedeem = "team_redeem"
    }
}

/// Step-one response: the single-use nonce the teammate must sign.
struct WorkspacePairChallengeResponse: Codable, Equatable, Sendable {
    struct Challenge: Codable, Equatable, Sendable {
        let nonce: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case nonce
            case expiresIn = "expires_in"
        }
    }

    let workspaceChallenge: Challenge

    enum CodingKeys: String, CodingKey {
        case workspaceChallenge = "team_challenge"
    }
}
