//
//  WorkspaceInspectPayload.swift
//  osaurus
//
//  `osaurus_inspect` rows for the two workspace read scopes:
//
//  - `workspaces`: the workspaces this Osaurus belongs to (id, name, member
//    and shared-agent counts, whether the Orchestrator auto-joins their
//    shared agents into its pool).
//  - `shared_agents`: teammates' agents shared into those workspaces (name,
//    owner, workspace, presence, whether the agent is already in the
//    Orchestrator's pool) plus the exact `target` string to pass to
//    `spawn_agent` or list under `delegation.spawnable_workspace_agents`.
//
//  The Orchestrator answers "who can I delegate to" and "is X online" from
//  these reads; the pool itself is edited through `osaurus_config`.
//

import Foundation

@MainActor
enum WorkspaceInspectPayload {

    static let workspacesScope = "workspaces"
    static let sharedAgentsScope = "shared_agents"

    // MARK: - workspaces

    static func workspaces() -> [[String: Any]] {
        let config = SubagentConfigurationStore.snapshot()
        return WorkspaceRosterStore.shared.rosters.map { roster in
            workspaceRow(roster, config: config)
        }
    }

    /// Workspace by id or exact (case-insensitive) name.
    static func describeWorkspace(_ raw: String) -> [String: Any]? {
        guard let roster = roster(matching: raw) else { return nil }
        var row = workspaceRow(roster, config: SubagentConfigurationStore.snapshot())
        row["shared_agents"] = sharedAgents().filter {
            ($0["workspace_id"] as? String)?.lowercased() == roster.id.lowercased()
        }
        return row
    }

    private static func workspaceRow(
        _ roster: WorkspaceRosterStore.WorkspaceRoster,
        config: SubagentConfiguration
    ) -> [String: Any] {
        let store = WorkspaceRosterStore.shared
        var row: [String: Any] = [
            "id": roster.id,
            "name": roster.workspace.name,
            "role": roster.workspace.role,
            "shared_agent_count": roster.agents.count,
            "teammate_agent_count": roster.agents.filter { !store.isHostedHere(address: $0.agentAddress) }
                .count,
            "orchestrator_auto_join": config.workspaceAutoJoinEnabled(roster.id),
        ]
        if let members = roster.workspace.membersActive { row["member_count"] = members }
        if let active = roster.workspace.active { row["active"] = active }
        return row
    }

    private static func roster(matching raw: String) -> WorkspaceRosterStore.WorkspaceRoster? {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !folded.isEmpty else { return nil }
        let rosters = WorkspaceRosterStore.shared.rosters
        return rosters.first { $0.id.lowercased() == folded }
            ?? rosters.first {
                $0.workspace.name.trimmingCharacters(in: .whitespaces).lowercased() == folded
            }
    }

    // MARK: - shared_agents

    /// Every teammate agent shared into a loaded workspace, one row per
    /// (workspace, address), in roster order.
    static func sharedAgents() -> [[String: Any]] {
        let config = SubagentConfigurationStore.snapshot()
        let pool = Set(config.spawnableWorkspaceAgents)
        return AgentTargetResolver.liveSharedAgents().compactMap { entry in
            sharedAgentRow(entry.ref, inPool: pool.contains(entry.ref))
        }
    }

    enum SharedAgentLookup {
        case found([String: Any])
        case notFound
        /// The identifier matched several targets; `forms` are the exact
        /// spellings that disambiguate (`Name@Workspace` / durable key).
        case ambiguous([String])
        /// The identifier is one of this Osaurus's own agents.
        case local(name: String)
    }

    /// Shared agent by `Name@Workspace`, unique display name, `0x…`
    /// address, or durable `workspaceId:0xaddress` key.
    static func describeSharedAgent(_ raw: String) -> SharedAgentLookup {
        switch AgentTargetResolver.resolve(raw, scope: .localAndWorkspace) {
        case .success(.workspace(let ref)):
            let pool = Set(SubagentConfigurationStore.snapshot().spawnableWorkspaceAgents)
            guard let row = sharedAgentRow(ref, inPool: pool.contains(ref)) else { return .notFound }
            return .found(row)
        case .success(.local(let id)):
            return .local(name: AgentManager.shared.agent(for: id)?.name ?? raw)
        case .failure(.ambiguous(let forms)):
            return .ambiguous(forms)
        case .failure(.notFound):
            return .notFound
        }
    }

    private static func sharedAgentRow(_ ref: WorkspaceAgentRef, inPool: Bool) -> [String: Any]? {
        let store = WorkspaceRosterStore.shared
        guard let agent = store.agent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId) else {
            return nil
        }
        let name = AgentTargetResolver.displayName(for: ref)
        var row: [String: Any] = [
            "name": name,
            // The spelling that works everywhere: `spawn_agent.agent`,
            // `delegation.spawnable_workspace_agents`, the target resolver.
            "target": AgentTargetResolver.qualifiedDisplayName(for: ref),
            "address": ref.agentAddress,
            "key": ref.key,
            "workspace_id": ref.workspaceId,
            "presence": presenceLabel(store.presence(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)),
            "in_orchestrator_pool": inPool,
        ]
        if let workspace = AgentTargetResolver.workspaceName(for: ref) { row["workspace"] = workspace }
        if let owner = agent.owner?.friendlyName, !owner.isEmpty { row["owner"] = owner }
        if let description = agent.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        {
            row["description"] = description
        }
        if let model = RemoteAgentManager.shared
            .remoteAgent(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)?.model?
            .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        {
            row["model"] = model
        }
        return row
    }

    static func presenceLabel(_ presence: WorkspaceRosterStore.Presence) -> String {
        switch presence {
        case .online: return "online"
        case .offline: return "offline"
        case .unknown: return "unknown"
        }
    }

    /// One-line hint appended to both list payloads so the model knows how
    /// to act on what it read.
    static let poolNote =
        "Delegate with spawn_agent (agent: the `target` value). Edit the Orchestrator's pool via "
        + "osaurus_config `delegation.spawnable_workspace_agents` (Name@Workspace or the `key`); "
        + "shared agents run on the teammate's Mac and cannot see your folder."
}
