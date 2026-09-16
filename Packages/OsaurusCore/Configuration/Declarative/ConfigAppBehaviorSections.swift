//
//  ConfigAppBehaviorSections.swift
//  osaurus
//
//  Wave 3b — app behavior sections of the declarative document. After the
//  scope reduction only delegation (SubagentConfiguration) remains: the
//  global computer-use, sandbox, privacy-filter, and image-generation
//  sections were removed from the declarative surface deliberately (vanity/
//  specialist controls that bloated the schema for small models — Settings
//  UI only now). Per-agent capability toggles, including computer_use and
//  browser_use, still live under `agents[].capabilities`.
//
//  Same semantics as the rest of the document: merge-by-default, explicit
//  null clears an optional override, secrets never appear.
//

import Foundation

// MARK: - Delegation

/// Mirrors the Orchestrator slice of `SubagentConfiguration`
/// (`agent-delegation.json`): the spawn pool, permission defaults, and
/// worker budgets. Custom agents carry their own per-agent equivalents in
/// `agents[].capabilities`.
public struct DelegationSection: Codable, Equatable, Sendable {
    /// The "Swap local models for subagents" toggle
    /// (`SubagentConfiguration.localTextDelegationEnabled`): the one stored
    /// value behind the Settings → Orchestrator switch, the spawn editors'
    /// status note (Orchestrator + every custom agent), and this key. ON
    /// enforces the delegation RAM-safety sequence (unload chat model → load
    /// helper → run → unload helper → reload chat model) for every agent;
    /// OFF runs a different-model local helper without that sequence.
    public var localTextEnabled: Bool?
    public var videoEnabled: Bool?
    /// One of: confirm_each, auto_run_with_warning (HIGH RISK).
    public var applescriptExecutionMode: String?
    /// Custom agent NAMES the Orchestrator may spawn. Replaces the pool.
    public var spawnableAgents: [String]?
    /// Teammates' shared workspace agents the Orchestrator may spawn, as
    /// `Name@Workspace` or `<workspace_id>:<0x-agent-address>`. Replaces the
    /// pool (and clears removal tombstones for the listed agents).
    public var spawnableWorkspaceAgents: [String]?
    /// Per-workspace auto-join of teammates' shared agents into the
    /// Orchestrator pool, keyed by workspace id (or name). `false` also
    /// prunes that workspace's agents from the pool. Merge: only listed
    /// workspaces change; unlisted ones keep the default (`true`).
    public var workspaceAutoJoin: [String: Bool]?
    /// Capability kind id (spawn, spawn_workspace, image, ...) ->
    /// ask | deny | always_allow. Merge: only listed kinds change.
    public var permissionDefaults: [String: String]?
    /// 256...65536
    public var budgetMaxTokens: Int?
    /// 1...100
    public var budgetMaxTurns: Int?
    /// 15...3600
    public var budgetMaxSeconds: Int?
    /// 1...32 — local-model workers per wave (mirrors Server Concurrent Sessions).
    public var budgetMaxParallelSpawns: Int?
    /// 1...32 — remote-model workers per wave (independent of local capacity).
    public var budgetMaxRemoteParallelSpawns: Int?
    /// HIGH RISK when disabled: spawn jobs skip the RAM preflight.
    public var ramSafetyPreflight: Bool?
    public var coexistenceEnabled: Bool?

    // MARK: Removed keys (decode-only, for migration hints)

    /// REMOVED: Image delegation moved to custom agents
    /// (`agents[].capabilities.image`). Decoded so the applier can explain;
    /// never exported or applied.
    public var imageEnabled: Bool?
    /// REMOVED: AppleScript delegation moved to custom agents
    /// (`agents[].capabilities.applescript`). Decoded for the hint only.
    public var applescriptEnabled: Bool?
    /// REMOVED: bare-model workers no longer exist; delegate to an agent.
    public var spawnableModels: [String]?
    /// REMOVED with bare-model workers.
    public var spawnToolAccess: String?
    /// REMOVED with bare-model workers.
    public var budgetMaxToolCalls: Int?

    public init() {}

    /// Removed keys present in this section, as `key → replacement` hints.
    var removedKeyHints: [String] {
        var hints: [String] = []
        if imageEnabled != nil {
            hints.append(
                "delegation.image_enabled was removed: enable Image on a custom agent "
                    + "(agents[].capabilities.image_enabled) and delegate to it.")
        }
        if applescriptEnabled != nil {
            hints.append(
                "delegation.applescript_enabled was removed: enable AppleScript on a custom "
                    + "agent (agents[].capabilities.applescript_enabled) and delegate to it.")
        }
        if spawnableModels != nil {
            hints.append(
                "spawnable_models was removed: create an agent with that model "
                    + "(agents[].model) and add it to spawnable_agents.")
        }
        if spawnToolAccess != nil {
            hints.append("spawn_tool_access was removed: agents use their own tools.")
        }
        if budgetMaxToolCalls != nil {
            hints.append("budget_max_tool_calls was removed: turns and time bound a worker.")
        }
        return hints
    }

    enum CodingKeys: String, CodingKey {
        case localTextEnabled = "local_text_enabled"
        case videoEnabled = "video_enabled"
        case applescriptExecutionMode = "applescript_execution_mode"
        case spawnableAgents = "spawnable_agents"
        case spawnableWorkspaceAgents = "spawnable_workspace_agents"
        case workspaceAutoJoin = "workspace_auto_join"
        case permissionDefaults = "permission_defaults"
        case budgetMaxTokens = "budget_max_tokens"
        case budgetMaxTurns = "budget_max_turns"
        case budgetMaxSeconds = "budget_max_seconds"
        case budgetMaxParallelSpawns = "budget_max_parallel_spawns"
        case budgetMaxRemoteParallelSpawns = "budget_max_remote_parallel_spawns"
        case ramSafetyPreflight = "ram_safety_preflight"
        case coexistenceEnabled = "coexistence_enabled"
        // Removed keys — decoded, never encoded (see `encode(to:)`).
        case imageEnabled = "image_enabled"
        case applescriptEnabled = "applescript_enabled"
        case spawnableModels = "spawnable_models"
        case spawnToolAccess = "spawn_tool_access"
        case budgetMaxToolCalls = "budget_max_tool_calls"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(localTextEnabled, forKey: .localTextEnabled)
        try c.encodeIfPresent(videoEnabled, forKey: .videoEnabled)
        try c.encodeIfPresent(applescriptExecutionMode, forKey: .applescriptExecutionMode)
        try c.encodeIfPresent(spawnableAgents, forKey: .spawnableAgents)
        try c.encodeIfPresent(spawnableWorkspaceAgents, forKey: .spawnableWorkspaceAgents)
        try c.encodeIfPresent(workspaceAutoJoin, forKey: .workspaceAutoJoin)
        try c.encodeIfPresent(permissionDefaults, forKey: .permissionDefaults)
        try c.encodeIfPresent(budgetMaxTokens, forKey: .budgetMaxTokens)
        try c.encodeIfPresent(budgetMaxTurns, forKey: .budgetMaxTurns)
        try c.encodeIfPresent(budgetMaxSeconds, forKey: .budgetMaxSeconds)
        try c.encodeIfPresent(budgetMaxParallelSpawns, forKey: .budgetMaxParallelSpawns)
        try c.encodeIfPresent(
            budgetMaxRemoteParallelSpawns, forKey: .budgetMaxRemoteParallelSpawns)
        try c.encodeIfPresent(ramSafetyPreflight, forKey: .ramSafetyPreflight)
        try c.encodeIfPresent(coexistenceEnabled, forKey: .coexistenceEnabled)
    }
}

// MARK: - Enum key mappings

/// Document string <-> store enum for the app-behavior sections. Store
/// enums with camelCase raw values get snake_case document keys.
enum ConfigAppBehaviorEnums {

    // Delegation
    static let permissionPolicies = SubagentPermissionPolicy.allCases.map { $0.rawValue }
    /// Permission kinds: every capability id plus the workspace-spawn kind
    /// (shared agents are gated separately from local spawns).
    static let permissionKindIds =
        SubagentCapabilityRegistry.all.map { $0.id }
        + [SubagentPermissionDefaults.workspaceSpawnKindId]
    static let applescriptExecutionModes = ["confirm_each", "auto_run_with_warning"]

    static func applescriptModeKey(for mode: AppleScriptExecutionMode) -> String {
        switch mode {
        case .confirmEach: return "confirm_each"
        case .autoRunWithWarning: return "auto_run_with_warning"
        }
    }

    static func applescriptMode(forKey key: String) -> AppleScriptExecutionMode? {
        switch key.lowercased() {
        case "confirm_each": return .confirmEach
        case "auto_run_with_warning": return .autoRunWithWarning
        default: return nil
        }
    }
}
