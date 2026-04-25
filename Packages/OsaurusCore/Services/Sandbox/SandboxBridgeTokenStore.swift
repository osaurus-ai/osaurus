//
//  SandboxBridgeTokenStore.swift
//  osaurus
//
//  Mints, resolves, and revokes per-agent shared secrets used by the sandbox
//  host bridge to authenticate guest requests. The token is written to a
//  per-user file inside the guest VM (mode 0600, owned by the agent's Linux
//  user) — kernel file permissions are what bind a token to a single agent
//  identity. Without the right token in `Authorization: Bearer`, the bridge
//  fails closed.
//

import Foundation

public actor SandboxBridgeTokenStore {
    public static let shared = SandboxBridgeTokenStore()

    public struct Identity: Sendable, Equatable {
        public let agentId: UUID
        public let linuxName: String
    }

    /// token (base64url) -> identity
    private var byToken: [String: Identity] = [:]
    /// linuxName -> token (so subsequent registers for the same agent are idempotent)
    private var byLinuxName: [String: String] = [:]

    /// Internal for tests so they can spin up an isolated store without
    /// reaching into the global singleton. Production code uses
    /// `SandboxBridgeTokenStore.shared`.
    init() {}

    /// Generate (or return the existing) bridge token for the given agent's Linux user.
    /// Idempotent per `linuxName`: subsequent calls with the same user return the same token.
    public func register(agentId: UUID, linuxName: String) -> String {
        if let existing = byLinuxName[linuxName] {
            return existing
        }
        let token = Self.generateToken()
        byToken[token] = Identity(agentId: agentId, linuxName: linuxName)
        byLinuxName[linuxName] = token
        return token
    }

    /// Resolve the identity behind a bearer token, or `nil` if unknown.
    public func resolve(token: String) -> Identity? {
        byToken[token]
    }

    /// Revoke a token for a Linux user — used when the agent is unprovisioned.
    @discardableResult
    public func revoke(linuxName: String) -> Bool {
        guard let token = byLinuxName.removeValue(forKey: linuxName) else { return false }
        byToken.removeValue(forKey: token)
        return true
    }

    /// Wipe all tokens — used when the container is fully reset, so a fresh
    /// boot does not accept old in-memory tokens that no longer correspond to
    /// what is on disk inside the guest.
    public func revokeAll() {
        byToken.removeAll()
        byLinuxName.removeAll()
    }

    public func tokenCount() -> Int {
        byToken.count
    }

    // MARK: - Generation

    /// Produce a 256-bit cryptographically random token, base64url-encoded.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to UUID stitching on the (extremely unlikely) failure
            // of the system RNG. We still want to fail closed rather than
            // mint a predictable token, so encode two UUIDs worth of entropy.
            let a = UUID().uuid
            let b = UUID().uuid
            withUnsafeBytes(of: a) { ptr in bytes.replaceSubrange(0 ..< 16, with: ptr) }
            withUnsafeBytes(of: b) { ptr in bytes.replaceSubrange(16 ..< 32, with: ptr) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - Base64URL helper

private extension Data {
    func base64URLEncodedString() -> String {
        var s = base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }
}
