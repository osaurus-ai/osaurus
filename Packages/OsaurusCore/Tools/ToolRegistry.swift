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

    struct ToolEntry: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let description: String
        var enabled: Bool
        let parameters: JSONValue?
    }

    private init() {
        // Register built-in tools
        register(FileReadTool())
        register(FileWriteTool())
        // Load external plugins
        PluginManager.shared.loadAll()
    }

    func register(_ tool: OsaurusTool) {
        toolsByName[tool.name] = tool
    }

    /// OpenAI-compatible tool specifications for the current registry
    func specs() -> [Tool] {
        return toolsByName.values
            .filter { configuration.isEnabled(name: $0.name) }
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
                throw NSError(
                    domain: "ToolRegistry",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Execution requires approval for tool: \(name)"]
                )
            case .auto:
                let requirements = permissioned.requirements
                if !configuration.hasGrants(for: name, requirements: requirements) {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Missing grants for tool: \(name). Requirements: \(requirements.joined(separator: ", "))"
                        ]
                    )
                }
            }
        } else {
            // Default for built-in tools without requirements: auto-run unless explicitly denied
            let effectivePolicy = configuration.policy[name] ?? .auto
            if effectivePolicy == .deny {
                throw NSError(
                    domain: "ToolRegistry",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            } else if effectivePolicy == .ask {
                throw NSError(
                    domain: "ToolRegistry",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Execution requires approval for tool: \(name)"]
                )
            }
        }
        return try await tool.execute(argumentsJSON: argumentsJSON)
    }

    // MARK: - Listing / Enablement
    /// Returns all registered tools with current enabled state.
    func listTools() -> [ToolEntry] {
        return toolsByName.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { t in
                ToolEntry(
                    name: t.name,
                    description: t.description,
                    enabled: configuration.isEnabled(name: t.name),
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

    func setGrant(_ granted: Bool, requirement: String, for name: String) {
        configuration.setGrant(granted, requirement: requirement, for: name)
        ToolConfigurationStore.save(configuration)
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
