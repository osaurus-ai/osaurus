//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Foundation
import Combine

@MainActor
final class ToolRegistry: ObservableObject {
    static let shared = ToolRegistry()

    @Published private var toolsByName: [String: OsaurusTool] = [:]
    @Published private var configuration: ToolConfiguration = ToolConfigurationStore.load()

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

        /// Estimated tokens for full tool schema (rough heuristic: ~4 chars per token)
        /// Used when tool is actually loaded after selection
        var estimatedTokens: Int {
            var total = name.count + description.count
            if let params = parameters {
                total += Self.estimateJSONSize(params)
            }
            // Overhead for JSON structure: {"type":"function","function":{"name":"...","description":"...","parameters":...}}
            // = 38 (prefix) + 17 (desc key) + 15 (params key) + 2 (closing) = 72 chars
            total += 72
            return max(1, total / 4)
        }

        /// Estimated tokens for catalog entry (name + description only)
        /// Used in two-phase loading where catalog is shown first
        var catalogEntryTokens: Int {
            // Format: "- **name**: description\n" ≈ 6 chars overhead
            let total = name.count + description.count + 6
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
                    // "key": value, = key.count + 4 (quotes + colon + space) + value + 1 (comma)
                    acc + pair.key.count + 5 + estimateJSONSize(pair.value)
                }
            }
        }
    }

    private init() {
        registerBuiltInTools()
    }

    /// Register built-in tools that are always available
    private func registerBuiltInTools() {
        // Register select_capabilities for two-phase capability loading
        register(SelectCapabilitiesTool())

        // Memory recall tools
        register(SearchWorkingMemoryTool())
        register(SearchConversationsTool())
        register(SearchSummariesTool())
        register(SearchGraphTool())
    }

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

    /// Tool specs excluding work-specific and folder tools.
    /// Use this for chat mode where work/folder tools should not be available.
    func userSpecs(withOverrides overrides: [String: Bool]?) -> [Tool] {
        let excluded = Self.workToolNames.union(Self.folderToolNames)
        return specs(withOverrides: overrides)
            .filter { !excluded.contains($0.function.name) }
    }

    /// Get specs for specific tools by name (ignores enabled state)
    func specs(forTools toolNames: [String]) -> [Tool] {
        return toolNames.compactMap { name in
            toolsByName[name]?.asOpenAITool()
        }
    }

    /// Get spec for select_capabilities tool only
    func selectCapabilitiesSpec() -> [Tool] {
        return specs(forTools: ["select_capabilities"])
    }

    /// Execute a tool by name with raw JSON arguments
    func execute(name: String, argumentsJSON: String) async throws -> String {
        return try await execute(name: name, argumentsJSON: argumentsJSON, overrides: nil)
    }

    /// Execute a tool by name with raw JSON arguments and optional per-session overrides
    /// - Parameter overrides: Per-session tool enablement. nil = use global config only.
    ///   If provided, keys in the map override global settings for those tools.
    func execute(name: String, argumentsJSON: String, overrides: [String: Bool]?) async throws -> String {
        guard let tool = toolsByName[name] else {
            throw NSError(
                domain: "ToolRegistry",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"]
            )
        }
        // Check per-session override first, fall back to global config
        let isEnabled: Bool
        if let overrides = overrides, let override = overrides[name] {
            isEnabled = override
        } else {
            isEnabled = configuration.isEnabled(name: name)
        }
        guard isEnabled else {
            throw NSError(
                domain: "ToolRegistry",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Tool is disabled: \(name)"]
            )
        }
        // Permission gating
        if let permissioned = tool as? PermissionedTool {
            let requirements = permissioned.requirements

            // Check system permissions and prompt the user for any that are missing
            let missingSystemPermissions = SystemPermissionService.shared.missingPermissions(from: requirements)
            for permission in missingSystemPermissions {
                _ = await SystemPermissionService.shared.requestPermissionAndWait(permission)
            }
            let stillMissing = SystemPermissionService.shared.missingPermissions(from: requirements)
            if !stillMissing.isEmpty {
                let missingNames = stillMissing.map { $0.displayName }.joined(separator: ", ")
                throw NSError(
                    domain: "ToolRegistry",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing system permissions for tool: \(name). Required: \(missingNames). Please grant these permissions in the Permissions tab or System Settings."
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
                // Auto-grant missing requirements when policy is .auto
                // This ensures backwards compatibility for existing configurations
                if !configuration.hasGrants(for: name, requirements: nonSystemRequirements) {
                    for req in nonSystemRequirements {
                        configuration.setGrant(true, requirement: req, for: name)
                    }
                    ToolConfigurationStore.save(configuration)
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
        // Run the tool body off MainActor so long-running tools (file I/O,
        // network, shell) don't contend with SwiftUI layout on the main thread.
        return try await Self.runToolBody(tool, argumentsJSON: argumentsJSON)
    }

    /// Trampoline that executes the tool outside of MainActor isolation.
    private nonisolated static func runToolBody(
        _ tool: OsaurusTool,
        argumentsJSON: String
    ) async throws -> String {
        try await tool.execute(argumentsJSON: argumentsJSON)
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

    /// Check if a tool is enabled in the global configuration
    func isGlobalEnabled(_ name: String) -> Bool {
        return configuration.isEnabled(name: name)
    }

    /// Retrieve parameter schema for a tool by name.
    func parametersForTool(name: String) -> JSONValue? {
        return toolsByName[name]?.parameters
    }

    /// Get estimated tokens for a tool by name (returns 0 if not found).
    func estimatedTokens(for name: String) -> Int {
        return listTools().first(where: { $0.name == name })?.estimatedTokens ?? 0
    }

    /// Total estimated tokens for all currently enabled tools (with optional overrides).
    /// Use this to reserve context budget for tool definitions.
    func totalEstimatedTokens(withOverrides overrides: [String: Bool]? = nil) -> Int {
        return listTools(withOverrides: overrides)
            .filter { $0.enabled }
            .reduce(0) { $0 + $1.estimatedTokens }
    }

    // MARK: - Policy / Grants
    func setPolicy(_ policy: ToolPermissionPolicy, for name: String) {
        configuration.setPolicy(policy, for: name)

        // When setting to .auto, automatically grant all non-system requirements
        // This ensures tools can execute without requiring separate manual grants
        if policy == .auto, let tool = toolsByName[name] as? PermissionedTool {
            let requirements = tool.requirements
            for req in requirements where !SystemPermissionService.isSystemPermission(req) {
                configuration.setGrant(true, requirement: req, for: name)
            }
        }

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

    // MARK: - Work-Conflicting Plugin Tools

    /// Plugins that duplicate built-in work folder/git tools and bypass undo + sandboxing.
    static let workConflictingPluginIds: Set<String> = [
        "osaurus.filesystem",
        "osaurus.git",
    ]

    /// Registered tool names from work-conflicting plugins. Disabled in work mode.
    var workConflictingToolNames: Set<String> {
        Set(
            toolsByName.values
                .compactMap { $0 as? ExternalTool }
                .filter { Self.workConflictingPluginIds.contains($0.pluginId) }
                .map { $0.name }
        )
    }

    // MARK: - User-Facing Tool List

    /// Work tool names that should be excluded from user-facing tool lists.
    /// These tools are always included by default in work mode.
    static var workToolNames: Set<String> {
        Set(WorkToolManager.shared.toolNames)
    }

    /// Folder tool names that should be excluded from user-facing tool lists.
    /// These tools are automatically managed based on folder selection.
    static var folderToolNames: Set<String> {
        Set(WorkToolManager.shared.folderToolNames)
    }

    /// List tools excluding work-specific and optionally internal tools.
    /// Use this for user-facing tool lists and counts.
    ///
    /// - Parameters:
    ///   - overrides: Agent-specific tool overrides
    ///   - excludeInternal: If true, also excludes internal tools like `select_capabilities`
    /// - Returns: Filtered list of tool entries
    func listUserTools(
        withOverrides overrides: [String: Bool]?,
        excludeInternal: Bool = false
    ) -> [ToolEntry] {
        var tools = listTools(withOverrides: overrides)
        // Always exclude work tools from user-facing lists
        tools = tools.filter { !Self.workToolNames.contains($0.name) }
        // Always exclude folder tools from user-facing lists (they're auto-managed)
        tools = tools.filter { !Self.folderToolNames.contains($0.name) }
        // Optionally exclude internal tools
        if excludeInternal {
            tools = tools.filter { $0.name != "select_capabilities" }
        }
        return tools
    }
}
