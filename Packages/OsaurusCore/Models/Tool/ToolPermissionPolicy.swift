//
//  ToolPermissionPolicy.swift
//  osaurus
//
//  Permission model for tools and optional capability requirements.
//

import Foundation

enum ToolPermissionPolicy: String, Codable, Sendable {
    case auto
    case ask
    case deny

    var displayName: String {
        switch self {
        case .auto: return L("Auto")
        case .ask: return L("Ask")
        case .deny: return L("Deny")
        }
    }
}

/// Global "auto-allow all tool calls" chat setting (default off). When on,
/// tools whose effective policy is `.ask` run without showing the interactive
/// approval card. It only replaces the interactive prompt: `.deny` policies,
/// external-surface / headless denials, and non-tool security confirmations
/// (e.g. provider credential moves, spawn first-use prompts) are unaffected.
enum ToolApprovalSettings {
    static let autoAllowAllDefaultsKey = "chatAutoAllowAllTools"

    static var autoAllowAll: Bool {
        UserDefaults.standard.bool(forKey: autoAllowAllDefaultsKey)
    }
}

extension ToolPermissionPolicy {
    /// Strictness rank for strictest-wins composition: `deny` > `ask` > `auto`.
    var strictnessRank: Int {
        switch self {
        case .auto: return 0
        case .ask: return 1
        case .deny: return 2
        }
    }

    /// Strictest-wins combinator. A global user setting can NARROW an
    /// argument-resolved policy (auto → ask, anything → deny) but can never
    /// loosen one — and vice versa.
    static func strictest(
        _ lhs: ToolPermissionPolicy,
        _ rhs: ToolPermissionPolicy
    ) -> ToolPermissionPolicy {
        lhs.strictnessRank >= rhs.strictnessRank ? lhs : rhs
    }
}

/// Optional extension protocol for tools that declare requirements and default policy.
protocol PermissionedTool {
    /// Capability/requirement identifiers, e.g. "permission:web", "permission:folder", "tool:browser"
    var requirements: [String] { get }
    /// Default policy suggested by the tool (host configuration may override)
    var defaultPermissionPolicy: ToolPermissionPolicy { get }
}

/// Argument-aware permission resolution for tools whose approval semantics
/// depend on WHAT is being asked, not just which tool is called (e.g.
/// `agent_channel_publish`, where the referenced destination binding's
/// outbound mode decides between auto / interactive confirm). The registry
/// combines the resolved value with the configured per-tool policy using
/// `ToolPermissionPolicy.strictest`, so a user setting can narrow a binding
/// but a permissive binding can never loosen a user setting.
protocol ContextualPermissionedTool: PermissionedTool {
    /// Resolve the policy for one specific invocation. Must be side-effect
    /// free — it runs before any approval prompt and before execution.
    func resolveContextualPermissionPolicy(argumentsJSON: String) async -> ToolPermissionPolicy

    /// Whether an `.ask` resolution that CANNOT be prompted (an unattended
    /// schedule/watcher dispatch with nobody present to answer a card) may
    /// proceed into the tool body, which must then convert the invocation
    /// into a QUEUED operator approval instead of executing the privileged
    /// action (`agent_channel_publish` records a pending outbox item). This
    /// lets a global `.ask` narrow an autonomous destination to
    /// approval-required on unattended runs instead of stalling or failing
    /// them. Defaults to `false`: unattended `.ask` stays denied for tools
    /// that execute their effect directly. Must be side-effect free.
    func unattendedAskQueuesForApproval(argumentsJSON: String) async -> Bool
}

extension ContextualPermissionedTool {
    func unattendedAskQueuesForApproval(argumentsJSON: String) async -> Bool { false }
}
