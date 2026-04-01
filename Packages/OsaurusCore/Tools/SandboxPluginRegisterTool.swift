//
//  SandboxPluginRegisterTool.swift
//  osaurus
//
//  Builtin sandbox tool for hot-registering agent-created plugins.
//  Reads plugin.json from the agent's plugins/ directory, validates it,
//  saves to the library for persistence/sharing, installs dependencies,
//  and makes tools available immediately in the active session.
//

import Foundation

struct SandboxPluginRegisterTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_plugin_register"
    let description =
        "Register a sandbox plugin you created. Reads plugin.json from your plugins/{plugin_id}/ directory, "
        + "installs dependencies, and makes tools available immediately in this session."

    let agentId: String
    let agentName: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "plugin_id": .object([
                    "type": .string("string"),
                    "description": .string("Plugin directory name under plugins/"),
                ])
            ]),
            "required": .array([.string("plugin_id")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let pluginId = args["plugin_id"] as? String,
            !pluginId.isEmpty
        else {
            return jsonError("Missing required parameter: plugin_id")
        }

        guard await SandboxManager.shared.status().isRunning else {
            return jsonError("Sandbox container is not running")
        }

        let (loaded, loadError) = loadPlugin(pluginId: pluginId)
        guard var plugin = loaded else {
            return jsonError(loadError!)
        }

        if let error = validate(plugin) {
            return jsonError(error)
        }

        SandboxPluginDefaults.applyRestrictedDefaults(&plugin)
        if plugin.metadata == nil { plugin.metadata = [:] }
        plugin.metadata?["created_by"] = .string("agent")

        await MainActor.run { SandboxPluginLibrary.shared.save(plugin) }

        do {
            try await SandboxPluginManager.shared.install(plugin: plugin, for: agentId)
        } catch {
            return jsonError("Plugin installation failed: \(error.localizedDescription)")
        }

        let registeredTools = await hotRegisterTools(plugin: plugin)

        queueToast(pluginId: plugin.id, pluginName: plugin.name, toolCount: registeredTools.count)

        let toolList = registeredTools.map { ["name": $0.name, "description": $0.description] }
        return jsonEncode([
            "status": "ready",
            "plugin_id": plugin.id,
            "plugin_name": plugin.name,
            "tools": toolList,
        ])
    }

    // MARK: - Private

    private func loadPlugin(pluginId: String) -> (SandboxPlugin?, String?) {
        let pluginFile = OsaurusPaths.containerWorkspace()
            .appendingPathComponent("agents/\(agentName)/plugins/\(pluginId)/plugin.json")

        guard FileManager.default.fileExists(atPath: pluginFile.path) else {
            return (nil, "plugin.json not found at plugins/\(pluginId)/plugin.json")
        }

        do {
            let data = try Data(contentsOf: pluginFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(SandboxPlugin.self, from: data), nil)
        } catch {
            return (nil, "Invalid plugin.json: \(error.localizedDescription)")
        }
    }

    private func validate(_ plugin: SandboxPlugin) -> String? {
        let pathErrors = plugin.validateFilePaths()
        if !pathErrors.isEmpty {
            return "Invalid file paths: \(pathErrors.joined(separator: "; "))"
        }

        if let setup = plugin.setup {
            let violations = SandboxNetworkPolicy.validateSetupCommand(setup)
            if !violations.isEmpty {
                return "Setup command rejected: \(violations.joined(separator: "; "))"
            }
        }

        return nil
    }

    private struct RegisteredTool {
        let name: String
        let description: String
    }

    private func hotRegisterTools(plugin: SandboxPlugin) async -> [RegisteredTool] {
        let tools = await MainActor.run { () -> [RegisteredTool] in
            ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
            return (plugin.tools ?? []).map {
                RegisteredTool(name: "\(plugin.id)_\($0.id)", description: $0.description)
            }
        }

        let specs = await MainActor.run {
            ToolRegistry.shared.specs(forTools: tools.map(\.name))
        }
        for spec in specs {
            await CapabilityLoadBuffer.shared.add(spec)
        }

        return tools
    }

    private func queueToast(pluginId: String, pluginName: String, toolCount: Int) {
        let agentId = self.agentId
        Task { @MainActor in
            let actionId = "removeAgentPlugin:\(pluginId):\(agentId)"
            ToastManager.shared.registerActionHandler(for: actionId) { _ in
                Task { @MainActor in
                    try? await SandboxPluginManager.shared.uninstall(pluginId: pluginId, from: agentId)
                    SandboxPluginLibrary.shared.delete(id: pluginId)
                }
            }
            ToastManager.shared.action(
                "Agent created plugin: \(pluginName)",
                message: "\(toolCount) tool\(toolCount == 1 ? "" : "s") registered",
                actionTitle: "Remove",
                actionId: actionId,
                timeout: 0
            )
        }
    }

    private func jsonError(_ message: String) -> String {
        jsonEncode(["error": message])
    }

    private func jsonEncode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"Failed to encode result\"}" }
        return json
    }
}
