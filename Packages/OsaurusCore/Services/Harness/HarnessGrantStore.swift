//
//  HarnessGrantStore.swift
//  osaurus
//
//  Agent-scoped tokens that let an out-of-process harness call back into
//  Osaurus as the agent whose chat it serves.
//

import Foundation
import os

/// One live token: which agent it speaks for, and what it may reach.
struct HarnessGrant: Sendable, Equatable {
    let agentId: UUID
    /// Mutating config tools (`osaurus_config`) are behind their own opt-in.
    /// Fixed at mint time; the child cannot widen it.
    let allowsConfigWrites: Bool
    /// Exact tool allow-list, or nil to defer to the agent's own tool policy
    /// at call time.
    let allowedToolNames: Set<String>?
    /// Nil = until revoked (harness tokens die with their process).
    let expiresAt: Date?

    /// Static scope checks. The agent's live tool policy is checked
    /// separately by `HarnessGrantStore.agentPolicyAllows`.
    func permitsTool(_ name: String) -> Bool {
        if HarnessGrantStore.deniedToolNames.contains(name)
            || HarnessGrantStore.builtInLoopToolNames.contains(name)
        {
            return false
        }
        if name == HarnessGrantStore.configWriteToolName, !allowsConfigWrites { return false }
        if let allowedToolNames { return allowedToolNames.contains(name) }
        return true
    }
}

/// Mints and verifies harness tokens.
///
/// `ChatExecutionContext.currentAgentId` is a `@TaskLocal`, so it does not
/// cross the process boundary into a harness. A token is the missing evidence:
/// Osaurus mints one per harness process, hands it only to that child (through
/// its environment, never argv), and revokes it when the process exits.
/// Presenting a live token proves the caller *is* that chat's harness — which
/// is what justifies binding the agent's identity on `/mcp/call`.
///
/// It is not a general credential: it is single-agent, confined to the
/// inference and MCP routes, never reaches agent-spawning or scheduling tools,
/// and never widens the agent's own tool policy.
///
/// Lock-based rather than an actor because the HTTP auth gate runs
/// synchronously on the event loop.
final class HarnessGrantStore: @unchecked Sendable {
    static let shared = HarnessGrantStore()

    /// Header `osaurus mcp` presents the token on. The CLI's copy of this
    /// literal lives in `MCPCommand`.
    static let headerName = "X-Osaurus-Bridge-Grant"
    /// Environment variable `osaurus mcp` reads the token from.
    static let environmentKey = "OSAURUS_MCP_BRIDGE_GRANT"

    static let configWriteToolName = "osaurus_config"

    /// Never reachable with a harness token. `spawn_agent` would let a harness
    /// start more agent workers (forbidden by AGENTS.md); the agent-loop tools
    /// only mean something inside Osaurus's own loop; the folder picker would
    /// restart the harness inside its own turn.
    static let deniedToolNames: Set<String> = [
        SubagentCapabilityRegistry.spawnAgentToolName,
        "todo", "complete", "clarify", "speak",
        PromptWorkingFolderTool.toolName,
    ]

    /// Tools that run their own Osaurus sub-loop on the agent's built-in
    /// model. A harness agent has no such model, so these are refused with
    /// `HarnessError.unsupportedPath` instead of running on defaults.
    static let builtInLoopToolNames: Set<String> = [
        ComputerUseTool.toolName, BrowserUseTool.toolName,
        AppleScriptTool.toolName, MacQueryTool.toolName,
    ]

    /// Normalized paths (the router strips `/v1` and `/api`) a token may call.
    /// Everything else — `/admin/*`, `/agents/*`, pairing, credits — is refused.
    static let allowedRoutes: Set<String> = [
        "/health", "/mcp/health", "/mcp/tools", "/mcp/call",
        "/models", "/tags", "/show",
        "/chat/completions", "/completions", "/messages", "/responses",
    ]

    private let lock = NSLock()
    private var grants: [String: HarnessGrant] = [:]

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "HarnessGrant")

    /// Mint a token. The returned string is the only copy; it is never logged.
    func mint(
        agentId: UUID,
        allowsConfigWrites: Bool,
        allowedToolNames: Set<String>? = nil,
        lifetime: TimeInterval? = nil,
        now: Date = Date()
    ) -> String {
        let token = Self.makeToken()
        let grant = HarnessGrant(
            agentId: agentId,
            allowsConfigWrites: allowsConfigWrites,
            allowedToolNames: allowedToolNames,
            expiresAt: lifetime.map { now.addingTimeInterval($0) }
        )
        lock.lock()
        grants[token] = grant
        lock.unlock()
        Self.log.debug("Minted harness grant for agent \(agentId.uuidString, privacy: .public)")
        return token
    }

    /// Resolve a presented token. Unknown and expired tokens both return nil.
    func resolve(_ token: String, now: Date = Date()) -> HarnessGrant? {
        lock.lock()
        defer { lock.unlock() }
        guard let grant = grants[token] else { return nil }
        if let expiresAt = grant.expiresAt, expiresAt <= now {
            grants[token] = nil
            return nil
        }
        return grant
    }

    func revoke(_ token: String) {
        lock.lock()
        let removed = grants.removeValue(forKey: token) != nil
        lock.unlock()
        if removed { Self.log.debug("Revoked harness grant") }
    }

    /// App quit: nothing outlives the app that minted it.
    func revokeAll() {
        lock.lock()
        grants.removeAll()
        lock.unlock()
    }

    func liveGrantCount(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return grants.values.filter { $0.expiresAt.map { $0 > now } ?? true }.count
    }

    /// The token a request presents, from either the bridge header or an
    /// `Authorization: Bearer` that happens to be a harness token.
    func presentedToken(bridgeHeader: String?, authorization: String?) -> String? {
        if let bridgeHeader, !bridgeHeader.isEmpty { return bridgeHeader }
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst(7))
        return resolve(token) == nil ? nil : token
    }

    /// The agent's live tool policy, for grants without an explicit list.
    @MainActor
    static func agentPolicyAllows(_ grant: HarnessGrant, toolName: String) -> Bool {
        guard grant.permitsTool(toolName) else { return false }
        guard grant.allowedToolNames == nil else { return true }
        let manager = AgentManager.shared
        guard manager.effectiveCapabilities(for: grant.agentId).toolsEnabled else { return false }
        if let enabled = manager.effectiveEnabledToolNames(for: grant.agentId) {
            return enabled.contains(toolName)
        }
        return true
    }

    /// 32 bytes of CSPRNG output, URL-safe.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        }
        return "osh_"
            + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
