//
//  AgentInvite.swift
//  osaurus
//
//  Signed, single-use invite payload that lets a sender hand out remote access
//  to one of their agents via a deeplink. Pre-approved on the sender side at
//  generation time; the receiver's app POSTs it back to /pair-invite over the
//  relay tunnel to swap it for an osk-v1 access key.
//

import Foundation

// MARK: - Errors

public enum AgentInviteError: Error, LocalizedError {
    case identityMissing
    case agentMissingIdentity
    case relayBaseURLMissing
    case signingFailed
    case signatureMismatch
    case malformedURL
    case malformedPayload

    public var errorDescription: String? {
        switch self {
        case .identityMissing:
            return "No Osaurus identity is configured on this device."
        case .agentMissingIdentity:
            return "This agent has no derived crypto identity yet."
        case .relayBaseURLMissing:
            return "The agent's relay tunnel is not connected."
        case .signingFailed:
            return "Could not sign the invite payload."
        case .signatureMismatch:
            return "Invite signature does not match the agent address."
        case .malformedURL:
            return "The deeplink is malformed."
        case .malformedPayload:
            return "The invite payload could not be decoded."
        }
    }
}

// MARK: - Agent Invite

/// Pre-approved invite sealed with the sender's per-agent private key. The
/// receiver POSTs the full struct back to `<url>/pair-invite`; the server
/// recovers the signer from the signature and verifies it matches `addr`.
///
/// Wire shape (JSON, base64url-encoded inside the deeplink's `pair` query
/// parameter):
///
/// ```json
/// {
///   "v": 1,
///   "addr": "0xABCD...",
///   "name": "Osaurus",
///   "desc": "optional brief",
///   "url":  "https://0xabcd....agent.osaurus.ai",
///   "nonce": "<base64url, 32 bytes>",
///   "exp":   1762000000,
///   "sig":   "<hex, 65 bytes>"
/// }
/// ```
public struct AgentInvite: Codable, Sendable, Equatable {
    /// Schema version. Receivers must reject unknown versions.
    public let v: Int
    /// The agent's checksummed address. Routes the invite + identifies the signer.
    public let addr: String
    /// Display name at issue time. Receivers use this in the approval prompt
    /// so they don't have to look up a hex address to know what they're adding.
    public let name: String
    /// Optional description from the agent at issue time.
    public let desc: String?
    /// Relay tunnel base URL the receiver will POST `/pair-invite` to.
    public let url: String
    /// 32 random bytes, base64url-encoded. Single-use replay token.
    public let nonce: String
    /// Unix-seconds expiry (UTC). Server enforces; receiver clock skew is irrelevant.
    public let exp: Int64
    /// 65-byte recoverable secp256k1 signature (hex), produced via the
    /// `Osaurus Signed Invite` domain prefix over the canonical signing string.
    public let sig: String

    public static let currentVersion: Int = 1
    public static let signingDomain: String = "Osaurus Signed Invite"

    public init(
        v: Int = AgentInvite.currentVersion,
        addr: String,
        name: String,
        desc: String?,
        url: String,
        nonce: String,
        exp: Int64,
        sig: String
    ) {
        self.v = v
        self.addr = addr
        self.name = name
        self.desc = desc
        self.url = url
        self.nonce = nonce
        self.exp = exp
        self.sig = sig
    }

    // MARK: Canonical signing payload

    /// Canonical bytes signed by the issuing agent. Centralised so signer and
    /// verifier cannot drift in shape.
    public static func signingPayload(addr: String, nonce: String, exp: Int64) -> Data {
        Data("osaurus-agent-invite-v1:\(addr):\(nonce):\(exp)".utf8)
    }

    public func signingPayloadBytes() -> Data {
        Self.signingPayload(addr: addr, nonce: nonce, exp: exp)
    }

    // MARK: Deeplink

    /// `osaurus://<addr>?pair=<base64url(json)>`
    public func deeplinkURL() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        let token = json.base64urlEncoded

        var components = URLComponents()
        components.scheme = "osaurus"
        components.host = addr.lowercased()
        components.queryItems = [URLQueryItem(name: "pair", value: token)]
        guard let url = components.url else {
            throw AgentInviteError.malformedURL
        }
        return url
    }

    /// Decode an invite from an `osaurus://` deeplink.
    public static func decode(from url: URL) throws -> AgentInvite {
        guard url.scheme?.lowercased() == "osaurus",
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let token = comps.queryItems?.first(where: { $0.name == "pair" })?.value,
            let data = Data(base64urlEncoded: token)
        else { throw AgentInviteError.malformedURL }

        let decoder = JSONDecoder()
        guard let invite = try? decoder.decode(AgentInvite.self, from: data) else {
            throw AgentInviteError.malformedPayload
        }
        return invite
    }

    // MARK: Validation

    public var isExpired: Bool {
        Int64(Date().timeIntervalSince1970) >= exp
    }

    public var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(exp))
    }

    /// Verify the embedded signature recovers to `addr`. Throws `.signatureMismatch`
    /// on mismatch, `.malformedPayload` if the signature can't be parsed.
    public func verifySignature() throws {
        let hex = sig.hasPrefix("0x") ? String(sig.dropFirst(2)) : sig
        guard let sigBytes = Data(hexEncoded: hex) else {
            throw AgentInviteError.malformedPayload
        }
        let recovered: OsaurusID
        do {
            recovered = try recoverAddress(
                payload: signingPayloadBytes(),
                signature: sigBytes,
                domainPrefix: Self.signingDomain
            )
        } catch {
            throw AgentInviteError.signatureMismatch
        }
        guard recovered.lowercased() == addr.lowercased() else {
            throw AgentInviteError.signatureMismatch
        }
    }

    // MARK: Display

    /// Truncated address for compact UI (`0xABCD…F291`). Mirrors
    /// `RemoteAgent.shortAddress` so both surfaces format the same address
    /// the same way.
    public var shortAddress: String {
        guard addr.count > 12 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }
}

// MARK: - Issuance

public enum AgentInviteIssuer {
    /// Mint a fresh invite for the given agent. Triggers biometric auth to
    /// derive the agent's child key from the master key. The relay base URL
    /// must already be known (i.e. the agent's tunnel is connected).
    @MainActor
    public static func issue(
        for agent: Agent,
        relayBaseURL: String,
        expiresAt: Date
    ) throws -> AgentInvite {
        guard MasterKey.exists() else { throw AgentInviteError.identityMissing }
        guard let address = agent.agentAddress, let index = agent.agentIndex else {
            throw AgentInviteError.agentMissingIdentity
        }
        guard !relayBaseURL.isEmpty else {
            throw AgentInviteError.relayBaseURLMissing
        }

        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = nonceBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        let nonce = Data(nonceBytes).base64urlEncoded
        let exp = Int64(expiresAt.timeIntervalSince1970)

        let context = OsaurusIdentityContext.biometric()
        var masterKey = try MasterKey.getPrivateKey(context: context)
        defer { Self.zero(&masterKey) }

        // Sign with the agent's per-agent child key (NOT the master key) so a
        // compromised invite signature can never impersonate the master.
        let payload = AgentInvite.signingPayload(addr: address, nonce: nonce, exp: exp)
        var childKey = AgentKey.derive(masterKey: masterKey, index: index)
        defer { Self.zero(&childKey) }
        let sig: Data
        do {
            sig = try signInvitePayload(payload, privateKey: childKey)
        } catch {
            throw AgentInviteError.signingFailed
        }

        return AgentInvite(
            addr: address,
            name: agent.name,
            desc: agent.description.isEmpty ? nil : agent.description,
            url: relayBaseURL,
            nonce: nonce,
            exp: exp,
            sig: sig.hexEncodedString
        )
    }

    /// Zero out a `Data` buffer in place. Used for ephemeral key material so
    /// it doesn't linger in memory after the issuer returns.
    private static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
        }
    }
}
