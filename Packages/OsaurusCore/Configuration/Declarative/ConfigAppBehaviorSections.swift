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

/// Mirrors the main-chat slice of `SubagentConfiguration`
/// (`agent-delegation.json`): capability enables, spawn pools, permission
/// defaults, and child budgets. Custom agents carry their own per-agent
/// equivalents in `agents[].capabilities`.
public struct DelegationSection: Codable, Equatable, Sendable {
    /// The "Local Orchestrator Handoff" toggle
    /// (`SubagentConfiguration.localTextDelegationEnabled`): the one stored
    /// value behind the Settings → Subagents switch, the spawn editors' status
    /// note (main chat + every custom agent), and this key. ON enforces the
    /// delegation RAM-safety sequence (unload chat model → load helper → run →
    /// unload helper → reload chat model) for every agent; OFF runs a
    /// different-model local helper without that sequence.
    public var localTextEnabled: Bool?
    public var imageEnabled: Bool?
    public var videoEnabled: Bool?
    public var applescriptEnabled: Bool?
    /// One of: confirm_each, auto_run_with_warning (HIGH RISK).
    public var applescriptExecutionMode: String?
    /// Custom agent NAMES the main chat may spawn. Replaces the pool.
    public var spawnableAgents: [String]?
    /// Raw model ids the main chat may hand a task to. Replaces the pool.
    public var spawnableModels: [String]?
    /// One of: none, read_only.
    public var spawnToolAccess: String?
    /// Capability kind id (spawn, image, ...) -> ask | deny | always_allow.
    /// Merge: only listed kinds change. always_allow is HIGH RISK.
    public var permissionDefaults: [String: String]?
    /// 256...32768
    public var budgetMaxTokens: Int?
    /// 1...8
    public var budgetMaxTurns: Int?
    /// 0...32
    public var budgetMaxToolCalls: Int?
    /// 15...1800
    public var budgetMaxSeconds: Int?
    /// 1...32
    public var budgetMaxParallelSpawns: Int?
    /// HIGH RISK when disabled: spawn jobs skip the RAM preflight.
    public var ramSafetyPreflight: Bool?
    public var coexistenceEnabled: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case localTextEnabled = "local_text_enabled"
        case imageEnabled = "image_enabled"
        case videoEnabled = "video_enabled"
        case applescriptEnabled = "applescript_enabled"
        case applescriptExecutionMode = "applescript_execution_mode"
        case spawnableAgents = "spawnable_agents"
        case spawnableModels = "spawnable_models"
        case spawnToolAccess = "spawn_tool_access"
        case permissionDefaults = "permission_defaults"
        case budgetMaxTokens = "budget_max_tokens"
        case budgetMaxTurns = "budget_max_turns"
        case budgetMaxToolCalls = "budget_max_tool_calls"
        case budgetMaxSeconds = "budget_max_seconds"
        case budgetMaxParallelSpawns = "budget_max_parallel_spawns"
        case ramSafetyPreflight = "ram_safety_preflight"
        case coexistenceEnabled = "coexistence_enabled"
    }
}

// MARK: - Enum key mappings

/// Document string <-> store enum for the app-behavior sections. Store
/// enums with camelCase raw values get snake_case document keys.
enum ConfigAppBehaviorEnums {

    // Delegation
    static let spawnToolAccessValues = SpawnToolAccess.allCases.map { $0.rawValue }
    static let permissionPolicies = SubagentPermissionPolicy.allCases.map { $0.rawValue }
    static let permissionKindIds = SubagentCapabilityRegistry.all.map { $0.id }
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
