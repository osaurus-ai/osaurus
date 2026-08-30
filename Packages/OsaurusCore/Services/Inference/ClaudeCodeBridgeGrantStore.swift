//
//  ClaudeCodeBridgeGrantStore.swift
//  osaurus
//
//  Short-lived grants that let an out-of-process Claude Code turn prove which
//  agent's chat it is serving.
//

import Foundation
import os

/// One live grant: the agent a bridged tool call may execute as, and when the
/// grant stops being honoured.
struct ClaudeCodeBridgeGrant: Sendable, Equatable {
    let agentId: UUID
    let expiresAt: Date
    /// Mutating config tools are gated separately from reads, mirroring the
    /// two settings toggles. A read-only grant cannot be escalated by the
    /// child; the value is fixed when the grant is minted.
    let allowsConfigWrites: Bool
    /// Server-side copy of the exact MCP allow-list. The CLI proxy filters
    /// discovery and calls for ergonomics, but this is the security boundary:
    /// even a child that learns the grant cannot use it for a wider tool.
    let allowedToolNames: Set<String>

    func allowsTool(_ name: String) -> Bool {
        allowedToolNames.contains(name)
    }
}

/// Mints and verifies the grants that carry chat identity across the process
/// boundary into a Claude Code subprocess.
///
/// ## Why this exists
///
/// `ChatExecutionContext.currentAgentId` is a `@TaskLocal`, so it is visible
/// only inside the process and task tree that bound it. An in-process backend
/// (MLX, Foundation Models) keeps it all the way down to the tool call. Claude
/// Code does not: its calls travel `claude` → `osaurus mcp` → HTTP, and arrive
/// at the server as an ordinary request with no agent bound.
///
/// `/mcp/call` therefore refuses to act as the built-in Default agent — it
/// cannot tell Osaurus's own child from Cursor, Zed, or any other MCP client
/// pointed at the same loopback port, and that guard has already been hardened
/// once against a bypass.
///
/// A grant is the missing evidence. Osaurus mints one per turn, hands it only
/// to the child it just spawned (via a `0600` config file that no other user
/// can read), and revokes it when the turn ends. Presenting a live grant proves
/// the caller *is* that turn — which is a narrower claim than "someone reached
/// loopback", and the only claim that justifies binding the Default agent.
///
/// ## What a grant is not
///
/// It is not a general credential. It expires, it is single-agent, it is
/// revoked at the end of the turn, and it never widens what the agent's own
/// settings already allow — `allowsConfigWrites` is copied from the toggle, so
/// a read-only chat stays read-only no matter what the child asks for.
actor ClaudeCodeBridgeGrantStore {
    static let shared = ClaudeCodeBridgeGrantStore()

    /// Header the bridge presents the grant on.
    static let headerName = "X-Osaurus-Bridge-Grant"
    /// Environment variable the CLI reads it from. Passed through the MCP
    /// config's `env` block rather than the argv so it never lands in `ps`.
    static let environmentKey = "OSAURUS_MCP_BRIDGE_GRANT"

    /// Ceiling on a grant's life. A turn that outlives this loses its tools
    /// rather than leaving a credential lying around; the next turn mints a
    /// fresh one, so the visible effect is bounded.
    static let maxLifetime: TimeInterval = 60 * 60

    private var grants: [String: ClaudeCodeBridgeGrant] = [:]

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "ClaudeCodeBridge")

    /// Mint a grant for one turn. The returned token is the only copy — the
    /// store keeps it keyed but never logs it.
    func mint(
        agentId: UUID,
        allowsConfigWrites: Bool,
        lifetime: TimeInterval = maxLifetime,
        now: Date = Date()
    ) -> String {
        let token = Self.makeToken()
        grants[token] = ClaudeCodeBridgeGrant(
            agentId: agentId,
            expiresAt: now.addingTimeInterval(min(lifetime, Self.maxLifetime)),
            allowsConfigWrites: allowsConfigWrites,
            allowedToolNames: Set(
                ClaudeCodeConfiguration.osaurusToolPatterns(
                    allowConfigWrites: allowsConfigWrites
                )
            )
        )
        Self.log.debug("Minted bridge grant for agent \(agentId.uuidString, privacy: .public)")
        return token
    }

    /// Resolve a presented token, dropping it if it has expired.
    ///
    /// Returns nil for unknown and expired tokens alike so a caller cannot
    /// distinguish "never existed" from "just lapsed".
    func resolve(_ token: String, now: Date = Date()) -> ClaudeCodeBridgeGrant? {
        guard let grant = grants[token] else { return nil }
        guard grant.expiresAt > now else {
            grants[token] = nil
            return nil
        }
        return grant
    }

    /// Revoke at the end of a turn. Called from a `defer` on the streaming path
    /// so a thrown error or a cancelled turn still clears the grant.
    func revoke(_ token: String) {
        guard grants.removeValue(forKey: token) != nil else { return }
        Self.log.debug("Revoked bridge grant")
    }

    /// Drop everything. Used when the server stops — a grant outliving the
    /// server it authenticates against has no meaning.
    func revokeAll() {
        guard !grants.isEmpty else { return }
        let count = grants.count
        grants.removeAll()
        Self.log.debug("Revoked \(count, privacy: .public) bridge grant(s)")
    }

    /// Live grant count, for tests.
    func liveGrantCount(now: Date = Date()) -> Int {
        grants.values.filter { $0.expiresAt > now }.count
    }

    /// 32 bytes of CSPRNG output, URL-safe. Long enough that guessing is not a
    /// concern even though the surface is loopback-only.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandomCopyBytes failing is not something to paper over with a
            // weaker source: a predictable grant is worse than no bridge.
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
