//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Foundation

@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    private var toolsByName: [String: OsaurusTool] = [:]
    private var configuration: ToolConfiguration = ToolConfigurationStore.load()

    struct ToolPolicyInfo {
        let isPermissioned: Bool
        let defaultPolicy: ToolPermissionPolicy
        let configuredPolicy: ToolPermissionPolicy?
        let effectivePolicy: ToolPermissionPolicy
        let requirements: [String]
        let grantsByRequirement: [String: Bool]
        /// System permissions required by this tool (e.g., automation, accessibility)
        let systemPermissions: [SystemPermission]
        /// Which system permissions are currently granted at the OS level
        let systemPermissionStates: [SystemPermission: Bool]
    }

    struct ToolEntry: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let description: String
        var enabled: Bool
        let parameters: JSONValue?

        /// Estimated tokens this tool definition adds to context (rough heuristic: ~4 chars per token)
        var estimatedTokens: Int {
            var total = name.count + description.count
            if let params = parameters {
                total += Self.estimateJSONSize(params)
            }
            // Add overhead for JSON structure (type, function wrapper, etc.)
            total += 50
            return max(1, total / 4)
        }

        /// Recursively estimate the serialized size of a JSONValue
        private static func estimateJSONSize(_ value: JSONValue) -> Int {
            switch value {
            case .null:
                return 4  // "null"
            case .bool(let b):
                return b ? 4 : 5  // "true" or "false"
            case .number(let n):
                return String(n).count
            case .string(let s):
                return s.count + 2  // quotes
            case .array(let arr):
                return arr.reduce(2) { $0 + estimateJSONSize($1) + 1 }  // brackets + commas
            case .object(let dict):
                return dict.reduce(2) { acc, pair in
                    acc + pair.key.count + 3 + estimateJSONSize(pair.value) + 1  // key + quotes + colon + value + comma
                }
            }
        }
    }

    private init() {}

    func register(_ tool: OsaurusTool) {
        toolsByName[tool.name] = tool
    }

    /// OpenAI-compatible tool specifications for the current registry
    func specs() -> [Tool] {
        return specs(withOverrides: nil)
    }

    /// OpenAI-compatible tool specifications with optional per-session overrides
    /// - Parameter overrides: Per-session tool enablement. nil = use global config only.
    ///   If provided, keys in the map override global settings for those tools.
    func specs(withOverrides overrides: [String: Bool]?) -> [Tool] {
        return toolsByName.values
            .filter { tool in
                // Check per-session override first, fall back to global config
                if let overrides = overrides, let override = overrides[tool.name] {
                    return override
                }
                return configuration.isEnabled(name: tool.name)
            }
            .map { $0.asOpenAITool() }
    }

    /// Execute a tool by name with raw JSON arguments
    func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = toolsByName[name] else {
            throw NSError(
                domain: "ToolRegistry",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"]
            )
        }
        guard configuration.isEnabled(name: name) else {
            throw NSError(
                domain: "ToolRegistry",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Tool is disabled: \(name)"]
            )
        }
        // Permission gating
        if let permissioned = tool as? PermissionedTool {
            let requirements = permissioned.requirements

            // First, check system permissions (automation, accessibility)
            let missingSystemPermissions = SystemPermissionService.shared.missingPermissions(from: requirements)
            if !missingSystemPermissions.isEmpty {
                let missingNames = missingSystemPermissions.map { $0.displayName }.joined(separator: ", ")
                throw NSError(
                    domain: "ToolRegistry",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing system permissions for tool: \(name). Required: \(missingNames). Please grant these permissions in System Settings."
                    ]
                )
            }

            let defaultPolicy = permissioned.defaultPermissionPolicy
            let effectivePolicy = configuration.policy[name] ?? defaultPolicy
            switch effectivePolicy {
            case .deny:
                throw NSError(
                    domain: "ToolRegistry",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            case .ask:
                let approved = await ToolPermissionPromptService.requestApproval(
                    toolName: name,
                    description: tool.description,
                    argumentsJSON: argumentsJSON
                )
                if !approved {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "User denied execution for tool: \(name)"]
                    )
                }
            case .auto:
                // Filter out system permissions from per-tool grant requirements
                let nonSystemRequirements = requirements.filter { !SystemPermissionService.isSystemPermission($0) }
                if !configuration.hasGrants(for: name, requirements: nonSystemRequirements) {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Missing grants for tool: \(name). Requirements: \(nonSystemRequirements.joined(separator: ", "))"
                        ]
                    )
                }
            }
        } else {
            // Default for tools without requirements: auto-run unless explicitly denied
            let effectivePolicy = configuration.policy[name] ?? .auto
            if effectivePolicy == .deny {
                throw NSError(
                    domain: "ToolRegistry",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            } else if effectivePolicy == .ask {
                let approved = await ToolPermissionPromptService.requestApproval(
                    toolName: name,
                    description: tool.description,
                    argumentsJSON: argumentsJSON
                )
                if !approved {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "User denied execution for tool: \(name)"]
                    )
                }
            }
        }
        return try await tool.execute(argumentsJSON: argumentsJSON)
    }

    // MARK: - Listing / Enablement
    /// Returns all registered tools with current enabled state.
    func listTools() -> [ToolEntry] {
        return listTools(withOverrides: nil)
    }

    /// Returns all registered tools with enabled state computed from overrides + global config.
    /// - Parameter overrides: Per-session tool enablement. nil = use global config only.
    func listTools(withOverrides overrides: [String: Bool]?) -> [ToolEntry] {
        return toolsByName.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { t in
                let enabled: Bool
                if let overrides = overrides, let override = overrides[t.name] {
                    enabled = override
                } else {
                    enabled = configuration.isEnabled(name: t.name)
                }
                return ToolEntry(
                    name: t.name,
                    description: t.description,
                    enabled: enabled,
                    parameters: t.parameters
                )
            }
    }

    /// Set enablement for a tool and persist.
    func setEnabled(_ enabled: Bool, for name: String) {
        configuration.setEnabled(enabled, for: name)
        ToolConfigurationStore.save(configuration)
        Task { @MainActor in
            await MCPServerManager.shared.notifyToolsListChanged()
        }
    }

    /// Retrieve parameter schema for a tool by name.
    func parametersForTool(name: String) -> JSONValue? {
        return toolsByName[name]?.parameters
    }

    // MARK: - Policy / Grants
    func setPolicy(_ policy: ToolPermissionPolicy, for name: String) {
        configuration.setPolicy(policy, for: name)
        ToolConfigurationStore.save(configuration)
    }

    func clearPolicy(for name: String) {
        configuration.clearPolicy(for: name)
        ToolConfigurationStore.save(configuration)
    }

    func setGrant(_ granted: Bool, requirement: String, for name: String) {
        configuration.setGrant(granted, requirement: requirement, for: name)
        ToolConfigurationStore.save(configuration)
    }

    /// Returns policy and requirements information for a given tool
    func policyInfo(for name: String) -> ToolPolicyInfo? {
        guard let tool = toolsByName[name] else { return nil }
        let isPermissioned = (tool as? PermissionedTool) != nil
        let defaultPolicy: ToolPermissionPolicy
        let requirements: [String]
        if let p = tool as? PermissionedTool {
            defaultPolicy = p.defaultPermissionPolicy
            requirements = p.requirements
        } else {
            defaultPolicy = .auto
            requirements = []
        }
        let configured = configuration.policy[name]
        let effective = configured ?? defaultPolicy
        var grants: [String: Bool] = [:]
        // Only track grants for non-system requirements
        for r in requirements where !SystemPermissionService.isSystemPermission(r) {
            grants[r] = configuration.isGranted(name: name, requirement: r)
        }

        // Extract system permissions from requirements
        let systemPermissions = requirements.compactMap { SystemPermission(rawValue: $0) }
        var systemPermissionStates: [SystemPermission: Bool] = [:]
        for perm in systemPermissions {
            systemPermissionStates[perm] = SystemPermissionService.shared.isGranted(perm)
        }

        return ToolPolicyInfo(
            isPermissioned: isPermissioned,
            defaultPolicy: defaultPolicy,
            configuredPolicy: configured,
            effectivePolicy: effective,
            requirements: requirements,
            grantsByRequirement: grants,
            systemPermissions: systemPermissions,
            systemPermissionStates: systemPermissionStates
        )
    }

    // MARK: - Unregister
    func unregister(names: [String]) {
        for n in names {
            toolsByName.removeValue(forKey: n)
        }
        Task { @MainActor in
            await MCPServerManager.shared.notifyToolsListChanged()
        }
    }
}
