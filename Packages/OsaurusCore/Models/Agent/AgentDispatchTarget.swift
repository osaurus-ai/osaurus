//
//  AgentDispatchTarget.swift
//  osaurus
//
//  Where a headless run should execute: an agent THIS instance hosts, or a
//  teammate's agent shared into a workspace (reached over the relay as a
//  Mode 2 `/agents/{address}/run`). Every trigger that used to carry a bare
//  local `UUID` — spawn tools, schedules, watchers, channel routes — carries
//  one of these instead, so the dispatch funnel can tell the two apart.
//

import Foundation

/// Durable identity of a shared workspace agent.
///
/// `RemoteAgent.id` is a local UUID that `RemoteAgentManager.upsertPairedAgent`
/// may destroy and recreate on a silent re-pair, so configuration never
/// stores it. `(workspaceId, agentAddress)` is what pairing, roster and
/// history all key on.
public struct WorkspaceAgentRef: Codable, Hashable, Sendable {
    /// Router workspace id the agent is shared into.
    public let workspaceId: String
    /// Lowercased checksummed address of the shared agent.
    public let agentAddress: String

    public init(workspaceId: String, agentAddress: String) {
        self.workspaceId = workspaceId
        self.agentAddress = agentAddress.lowercased()
    }

    /// Stable, human-readable key (`<workspaceId>:<address>`), used where a
    /// single string is needed (dedupe sets, tool enum values, audit rows).
    public var key: String { "\(workspaceId):\(agentAddress)" }

    /// Parse a `key` back into a ref. nil for anything that is not exactly
    /// `<workspaceId>:<0x-address>`.
    public init?(key: String) {
        guard let separator = key.lastIndex(of: ":") else { return nil }
        let workspaceId = String(key[..<separator])
        let address = String(key[key.index(after: separator)...])
        guard !workspaceId.isEmpty, Self.looksLikeAddress(address) else { return nil }
        self.init(workspaceId: workspaceId, agentAddress: address)
    }

    /// `0x` + 40 hex characters.
    public static func looksLikeAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42, trimmed.lowercased().hasPrefix("0x") else { return false }
        return trimmed.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case agentAddress = "agent_address"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workspaceId = try container.decode(String.self, forKey: .workspaceId)
        let address = try container.decode(String.self, forKey: .agentAddress)
        self.init(workspaceId: workspaceId, agentAddress: address)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encode(agentAddress, forKey: .agentAddress)
    }
}

/// The agent a trigger runs.
public enum AgentDispatchTarget: Hashable, Sendable {
    /// An agent hosted by this instance (`AgentManager`).
    case local(UUID)
    /// A teammate's shared agent, run on their Mac over the relay.
    case workspace(WorkspaceAgentRef)

    public var localId: UUID? {
        if case .local(let id) = self { return id }
        return nil
    }

    public var workspaceRef: WorkspaceAgentRef? {
        if case .workspace(let ref) = self { return ref }
        return nil
    }

    public var isWorkspace: Bool { workspaceRef != nil }
}

// MARK: - Codable (legacy `UUID` fallback)

extension AgentDispatchTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, workspace
    }

    private enum Kind: String, Codable {
        case local, workspace
    }

    /// Decodes both the tagged object form written by `encode(to:)` and a
    /// bare UUID string — the shape every pre-existing `agentId` field was
    /// persisted in — so stored schedules, watchers and channel routes keep
    /// decoding as `.local`.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let uuid = try? single.decode(UUID.self) {
            self = .local(uuid)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local(try container.decode(UUID.self, forKey: .id))
        case .workspace:
            self = .workspace(try container.decode(WorkspaceAgentRef.self, forKey: .workspace))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let id):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .workspace(let ref):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(ref, forKey: .workspace)
        }
    }
}

// MARK: - Keyed-container helpers for models that carry a legacy `agentId`

extension KeyedDecodingContainer {
    /// Read an `AgentDispatchTarget` from a model that historically persisted a bare
    /// `agentId` UUID (and, older still, `personaId`). Order: the new
    /// `target` key, then `agentId`, then `personaId`. nil when none are set.
    func decodeAgentTarget(
        targetKey: K,
        legacyAgentIdKey: K,
        legacyPersonaIdKey: K? = nil
    ) throws -> AgentDispatchTarget? {
        if let target = try decodeIfPresent(AgentDispatchTarget.self, forKey: targetKey) {
            return target
        }
        if let id = try decodeIfPresent(UUID.self, forKey: legacyAgentIdKey) {
            return .local(id)
        }
        if let personaKey = legacyPersonaIdKey,
            let id = try decodeIfPresent(UUID.self, forKey: personaKey)
        {
            return .local(id)
        }
        return nil
    }
}

extension KeyedEncodingContainer {
    /// Write an `AgentDispatchTarget` so BOTH the new `target` key and the legacy
    /// `agentId` key are populated for local targets. Older builds reading
    /// the same file keep seeing the UUID they expect; workspace targets
    /// leave `agentId` unset (an older build treats the row as "no agent",
    /// which its built-in guard already refuses to run).
    mutating func encodeAgentTarget(
        _ target: AgentDispatchTarget?,
        targetKey: K,
        legacyAgentIdKey: K
    ) throws {
        try encodeIfPresent(target, forKey: targetKey)
        try encodeIfPresent(target?.localId, forKey: legacyAgentIdKey)
    }
}

// MARK: - Resolution

/// Turns the identifiers a caller might hand us (UUID, local crypto address,
/// shared-agent display name or address) into an `AgentDispatchTarget`.
@MainActor
public enum AgentTargetResolver {
    public enum Scope: Sendable {
        /// Only agents this instance hosts. The local HTTP API uses this so a
        /// teammate's shared agent is never reachable — or even visible —
        /// through `/agents` (see `HTTPHandler`).
        case localOnly
        /// Local agents plus shared workspace agents the user can run.
        case localAndWorkspace
    }

    public enum Failure: Error, Equatable, Sendable {
        case notFound
        /// The name matched more than one shared agent (or a local and a
        /// shared agent). The caller must use the address instead.
        case ambiguous([String])
    }

    /// Resolve `identifier` against live state. Matching order: local UUID,
    /// local address, workspace ref key, shared-agent address, then display
    /// name (local first, then shared; exact, case-insensitive).
    public static func resolve(
        _ identifier: String,
        scope: Scope,
        localAgents: [Agent] = AgentManager.shared.agents,
        sharedAgents: [(ref: WorkspaceAgentRef, name: String?)] = liveSharedAgents()
    ) -> Result<AgentDispatchTarget, Failure> {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notFound) }

        if let uuid = UUID(uuidString: trimmed) {
            return localAgents.contains { $0.id == uuid } ? .success(.local(uuid)) : .failure(.notFound)
        }
        if WorkspaceAgentRef.looksLikeAddress(trimmed) {
            let lowered = trimmed.lowercased()
            if let local = localAgents.first(where: { $0.agentAddress?.lowercased() == lowered }) {
                return .success(.local(local.id))
            }
            guard scope == .localAndWorkspace else { return .failure(.notFound) }
            let hits = sharedAgents.filter { $0.ref.agentAddress == lowered }
            switch hits.count {
            case 0: return .failure(.notFound)
            case 1: return .success(.workspace(hits[0].ref))
            default: return .failure(.ambiguous(hits.map(\.ref.key)))
            }
        }
        if scope == .localAndWorkspace, let ref = WorkspaceAgentRef(key: trimmed),
            sharedAgents.contains(where: { $0.ref == ref })
        {
            return .success(.workspace(ref))
        }

        let folded = trimmed.lowercased()
        let localNameHits = localAgents.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == folded }
        let sharedNameHits: [(ref: WorkspaceAgentRef, name: String?)] =
            scope == .localAndWorkspace
            ? sharedAgents.filter { ($0.name ?? "").trimmingCharacters(in: .whitespaces).lowercased() == folded }
            : []
        let total = localNameHits.count + sharedNameHits.count
        switch total {
        case 0:
            return .failure(.notFound)
        case 1:
            if let local = localNameHits.first { return .success(.local(local.id)) }
            return .success(.workspace(sharedNameHits[0].ref))
        default:
            return .failure(
                .ambiguous(localNameHits.map { $0.id.uuidString } + sharedNameHits.map(\.ref.key))
            )
        }
    }

    /// Shared agents the user can run: every roster entry that is not one
    /// of this instance's own agents, once per (workspace, address).
    public static func liveSharedAgents() -> [(ref: WorkspaceAgentRef, name: String?)] {
        let roster = WorkspaceRosterStore.shared
        var out: [(ref: WorkspaceAgentRef, name: String?)] = []
        var seen = Set<WorkspaceAgentRef>()
        for entry in roster.rosters {
            for agent in entry.agents where !roster.isOwnAgent(address: agent.agentAddress) {
                let ref = WorkspaceAgentRef(workspaceId: entry.id, agentAddress: agent.agentAddress)
                guard seen.insert(ref).inserted else { continue }
                let name = agent.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append((ref, (name?.isEmpty == false) ? name : roster.lastKnownName(forAddress: ref.agentAddress)))
            }
        }
        return out
    }

    /// Display name for a ref from live roster state (falls back to the last
    /// name seen for the address, then a shortened address).
    public static func displayName(for ref: WorkspaceAgentRef) -> String {
        let roster = WorkspaceRosterStore.shared
        if let name = roster.agent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        {
            return name
        }
        if let paired = RemoteAgentManager.shared.remoteAgent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId),
            !paired.name.isEmpty
        {
            return paired.name
        }
        if let last = roster.lastKnownName(forAddress: ref.agentAddress) { return last }
        return OsaurusRouterWorkspacePerson.shortWallet(ref.agentAddress)
    }

    /// Workspace display name for a ref, when the roster knows it.
    public static func workspaceName(for ref: WorkspaceAgentRef) -> String? {
        WorkspaceRosterStore.shared.rosters.first { $0.id == ref.workspaceId }?.workspace.name
    }
}
