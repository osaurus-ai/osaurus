//
//  ToolConfiguration.swift
//  osaurus
//
//  Per-tool enablement configuration persisted to disk.
//

import Foundation

/// Configuration for chat tools enable/disable state
struct ToolConfiguration: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case policy
        case grants
        case userAutoApproved
        case autoAllowedMCPProviders
    }

    /// Mapping of tool name -> enabled flag. Missing entries default to false (disabled).
    var enabled: [String: Bool]
    /// Mapping of tool name -> permission policy
    var policy: [String: ToolPermissionPolicy]
    /// Mapping of tool name -> requirement grants (requirement string -> granted)
    var grants: [String: [String: Bool]]
    /// Tool names whose `.auto` policy the user chose in person (Tools catalog
    /// menu, "Always Allow" on an approval card). A remote MCP tool that
    /// needs user trust only runs unprompted when it is listed here, so an
    /// `auto` written by a declarative apply cannot stand in for the user.
    var userAutoApproved: Set<String>
    /// MCP provider ids (UUID strings) whose tools the user chose to run
    /// without asking, from the provider's card in settings. Kept here rather
    /// than on the provider record so a declarative apply or a plugin import
    /// cannot set it. A per-tool Ask or Deny still wins.
    var autoAllowedMCPProviders: Set<String>

    init(
        enabled: [String: Bool] = [:],
        policy: [String: ToolPermissionPolicy] = [:],
        grants: [String: [String: Bool]] = [:],
        userAutoApproved: Set<String> = [],
        autoAllowedMCPProviders: Set<String> = []
    ) {
        self.enabled = enabled
        self.policy = policy
        self.grants = grants
        self.userAutoApproved = userAutoApproved
        self.autoAllowedMCPProviders = autoAllowedMCPProviders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? container.decode([String: Bool].self, forKey: .enabled)) ?? [:]
        self.policy = (try? container.decode([String: ToolPermissionPolicy].self, forKey: .policy)) ?? [:]
        self.grants = (try? container.decode([String: [String: Bool]].self, forKey: .grants)) ?? [:]
        self.userAutoApproved = (try? container.decode(Set<String>.self, forKey: .userAutoApproved)) ?? []
        self.autoAllowedMCPProviders =
            (try? container.decode(Set<String>.self, forKey: .autoAllowedMCPProviders)) ?? []
    }

    /// Returns whether a tool is enabled. Defaults to false if not explicitly set.
    func isEnabled(name: String) -> Bool {
        return enabled[name] ?? false
    }

    /// Set enabled state for a tool name.
    mutating func setEnabled(_ value: Bool, for name: String) {
        enabled[name] = value
    }

    // MARK: - Permission policy
    /// Returns configured permission policy for a tool; defaults to .ask
    func policy(for name: String) -> ToolPermissionPolicy {
        return policy[name] ?? .ask
    }

    /// Set permission policy for a tool. `byUser` marks an `.auto` the user
    /// picked in person; any other policy drops the mark.
    mutating func setPolicy(_ value: ToolPermissionPolicy, for name: String, byUser: Bool = false) {
        policy[name] = value
        if value != .auto {
            userAutoApproved.remove(name)
        } else if byUser {
            userAutoApproved.insert(name)
        }
    }

    /// Whether the tool is on `.auto` because the user chose it in person.
    func isUserAutoApproved(_ name: String) -> Bool {
        policy[name] == .auto && userAutoApproved.contains(name)
    }

    /// Clear the configured permission policy override for a tool
    mutating func clearPolicy(for name: String) {
        policy.removeValue(forKey: name)
        userAutoApproved.remove(name)
    }

    // MARK: - Requirement grants
    /// Returns true if all requirements are granted for the tool
    func hasGrants(for name: String, requirements: [String]) -> Bool {
        guard !requirements.isEmpty else { return true }
        let granted = grants[name] ?? [:]
        for req in requirements {
            if granted[req] != true { return false }
        }
        return true
    }

    /// Returns individual grant value for a specific requirement
    func isGranted(name: String, requirement: String) -> Bool {
        return grants[name]?[requirement] ?? false
    }

    /// Set grant value for a requirement of a tool
    mutating func setGrant(_ value: Bool, requirement: String, for name: String) {
        var perTool = grants[name] ?? [:]
        perTool[requirement] = value
        grants[name] = perTool
    }
}
