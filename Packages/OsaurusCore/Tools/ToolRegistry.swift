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

    private var toolsByName: [String: ChatTool] = [:]
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
        register(WeatherTool())
        register(StockTool())
        register(FileReadTool())
        register(FileWriteTool())
    }

    func register(_ tool: ChatTool) {
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
                    description: t.toolDescription,
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
}
