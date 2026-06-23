//
//  IdentityModels.swift
//  osaurus
//
//  Data types for the Osaurus Identity system.
//

import Foundation

/// Checksummed hex address: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"
public typealias OsaurusID = String

// MARK: - Token

/// JWT-like header identifying the token format.
public struct TokenHeader: Codable, Sendable {
    public let alg: String
    public let typ: String
    public let ver: Int

    public static let current = TokenHeader(
        alg: "es256k+apple-attest",
        typ: "osaurus-id",
        ver: 5
    )
}

/// Payload carried inside every signed request token.
public struct TokenPayload: Codable, Sendable {
    public let iss: String
    public let dev: String
    public let cnt: UInt64
    public let iat: Int
    public let exp: Int
    public let aud: String
    public let act: String

    public let par: String?
    public let idx: UInt32?
}

// MARK: - Identity

/// UserDefaults keys for the identity subsystem. Centralised so the
/// onboarding view, the Identity view, and the wipe helper can't drift on
/// the spelling of a magic string. Add new identity-scoped flags here.
public enum IdentityDefaultsKey {
    /// Legacy flag — used to track whether the user clicked "I've saved it"
    /// on the now-removed onboarding recovery screen. Retained only so the
    /// `OsaurusIdentity.wipe()` cleanup keeps clearing it on reset for
    /// users upgrading from older builds. New code paths never read it.
    public static let masterMnemonicAcknowledged = "masterMnemonicAcknowledged"
}

/// Returned once after initial identity setup.
///
/// The 24-word BIP39 backup is no longer carried here — it is persisted to
/// `MasterMnemonicStore` at setup time and fetched on demand from Settings.
public struct IdentityInfo: Sendable {
    public let osaurusId: OsaurusID
    public let deviceId: String
    public let recovery: RecoveryInfo

    public init(
        osaurusId: OsaurusID,
        deviceId: String,
        recovery: RecoveryInfo
    ) {
        self.osaurusId = osaurusId
        self.deviceId = deviceId
        self.recovery = recovery
    }
}

/// One-time recovery code, shown at creation then discarded from memory.
public struct RecoveryInfo: Sendable {
    public let code: String
}

// MARK: - Access Keys

public enum AccessKeyExpiration: String, Codable, CaseIterable, Sendable {
    case days30 = "30d"
    case days90 = "90d"
    case year1 = "1y"
    case never = "never"

    public var displayName: String {
        switch self {
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .year1: return "1 year"
        case .never: return "Never"
        }
    }

    public func expirationDate(from createdAt: Date) -> Date? {
        switch self {
        case .days30: return Calendar.current.date(byAdding: .day, value: 30, to: createdAt)
        case .days90: return Calendar.current.date(byAdding: .day, value: 90, to: createdAt)
        case .year1: return Calendar.current.date(byAdding: .year, value: 1, to: createdAt)
        case .never: return nil
        }
    }
}

/// The signed payload embedded inside an osk-v1 access key.
/// Keys are sorted alphabetically for canonical JSON encoding.
public struct AccessKeyPayload: Codable, Sendable {
    public let aud: OsaurusID
    public let cnt: UInt64
    public let exp: Int?
    public let iat: Int
    public let iss: OsaurusID
    public let lbl: String?
    public let nonce: String

    public init(
        aud: OsaurusID,
        cnt: UInt64,
        exp: Int?,
        iat: Int,
        iss: OsaurusID,
        lbl: String?,
        nonce: String
    ) {
        self.aud = aud
        self.cnt = cnt
        self.exp = exp
        self.iat = iat
        self.iss = iss
        self.lbl = lbl
        self.nonce = nonce
    }
}

/// Persisted metadata for a generated access key.
/// The signature and full key are never stored — only metadata for display and revocation.
public struct AccessKeyInfo: Codable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let prefix: String
    public let nonce: String
    public let cnt: UInt64
    public let iss: OsaurusID
    public let aud: OsaurusID
    public let createdAt: Date
    public let expiration: AccessKeyExpiration
    public let expiresAt: Date?
    public let revoked: Bool

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    public var isActive: Bool {
        !revoked && !isExpired
    }

    public func withRevoked() -> AccessKeyInfo {
        AccessKeyInfo(
            id: id,
            label: label,
            prefix: prefix,
            nonce: nonce,
            cnt: cnt,
            iss: iss,
            aud: aud,
            createdAt: createdAt,
            expiration: expiration,
            expiresAt: expiresAt,
            revoked: true
        )
    }

    public init(
        id: UUID,
        label: String,
        prefix: String,
        nonce: String,
        cnt: UInt64,
        iss: OsaurusID,
        aud: OsaurusID,
        createdAt: Date,
        expiration: AccessKeyExpiration,
        expiresAt: Date?,
        revoked: Bool = false
    ) {
        self.id = id
        self.label = label
        self.prefix = prefix
        self.nonce = nonce
        self.cnt = cnt
        self.iss = iss
        self.aud = aud
        self.createdAt = createdAt
        self.expiration = expiration
        self.expiresAt = expiresAt
        self.revoked = revoked
    }
}

// MARK: - Agent

/// Describes a registered agent derived from the master key.
public struct AgentInfo: Codable, Identifiable, Sendable {
    public var id: UInt32 { index }
    public let index: UInt32
    public let address: OsaurusID
    public let label: String
    public let createdAt: Date

    public init(index: UInt32, address: OsaurusID, label: String, createdAt: Date = Date()) {
        self.index = index
        self.address = address
        self.label = label
        self.createdAt = createdAt
    }
}

// MARK: - Revocation

/// An immutable snapshot of revocation state, used by the validator at request time.
public struct RevocationSnapshot: Sendable {
    public let revokedKeys: Set<String>
    public let counterThresholds: [OsaurusID: UInt64]

    public init(revokedKeys: Set<String>, counterThresholds: [OsaurusID: UInt64]) {
        self.revokedKeys = revokedKeys
        self.counterThresholds = counterThresholds
    }

    /// Composite key for individual revocation lookups.
    public static func revocationKey(address: OsaurusID, nonce: String) -> String {
        "\(address.lowercased()):\(nonce)"
    }

    public func isRevoked(address: OsaurusID, nonce: String, cnt: UInt64) -> Bool {
        let key = Self.revocationKey(address: address, nonce: nonce)
        if revokedKeys.contains(key) { return true }
        if let threshold = counterThresholds[address.lowercased()], cnt <= threshold { return true }
        return false
    }
}

// MARK: - Validation Result

public enum AccessKeyValidationResult: Sendable {
    /// `audience` is the validated key's `aud` claim (the agent or master
    /// address the key is scoped to). Callers use it to enforce that an
    /// agent-scoped key only reaches its own agent's routes.
    ///
    /// `keyNonce` is the matched key's `nonce` claim — the stable per-key
    /// identifier recoverable from the token itself (the local
    /// `AccessKeyInfo.id` UUID is not, since it's minted randomly). Inbound
    /// request logging stamps it so the host's Remote Connections view can
    /// attribute per-connection usage; correlate with `AccessKeyInfo.nonce`.
    case valid(issuer: OsaurusID, audience: OsaurusID, keyNonce: String)
    case invalid(reason: String)
    case expired
    case revoked
}
