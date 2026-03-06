//
//  SandboxPluginManager.swift
//  osaurus
//
//  Orchestrates the full sandbox plugin lifecycle: parse, install dependencies,
//  create project folders, run setup, register tools, retry, and uninstall.
//

import Foundation

extension Notification.Name {
    static let sandboxPluginsChanged = Notification.Name("sandboxPluginsChanged")
}

public enum SandboxPluginError: Error, LocalizedError {
    case invalidJSON(String)
    case setupFailed(String)
    case vmNotAvailable
    case pluginNotFound(String)
    case alreadyInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg): return "Invalid sandbox plugin JSON: \(msg)"
        case .setupFailed(let msg): return "Plugin setup failed: \(msg)"
        case .vmNotAvailable: return "Agent VM is not available"
        case .pluginNotFound(let name): return "Plugin not found: \(name)"
        case .alreadyInstalled(let name): return "Plugin already installed: \(name)"
        }
    }
}

public actor SandboxPluginManager {
    public static let shared = SandboxPluginManager()

    private init() {}

    // MARK: - Startup Restore

    /// Re-register sandbox tools for all agents on app launch.
    /// Does NOT re-run setup or boot VMs -- only restores ToolRegistry entries
    /// so the LLM can see them. VMs boot lazily on first tool execution.
    public func restoreAll() async {
        let agents = await MainActor.run { AgentManager.shared.agents }
        for agent in agents {
            let store = SandboxPluginStore.load(for: agent.id)
            for installed in store.plugins where installed.status == .ready {
                await registerTools(plugin: installed.plugin, agentId: agent.id)
                await registerMCPTools(installed: installed, agentId: agent.id)
            }
        }
        if agents.contains(where: { !SandboxPluginStore.load(for: $0.id).plugins.isEmpty }) {
            await MainActor.run {
                NotificationCenter.default.post(name: .toolsListChanged, object: nil)
            }
        }
    }

    // MARK: - Install

    /// Install a sandbox plugin for an agent from raw JSON data.
    public func install(jsonData: Data, for agentId: UUID) async throws {
        let plugin = try JSONDecoder().decode(SandboxPlugin.self, from: jsonData)
        try await install(plugin: plugin, for: agentId)
    }

    /// Install a sandbox plugin for an agent.
    public func install(plugin: SandboxPlugin, for agentId: UUID) async throws {
        guard !plugin.name.isEmpty else {
            throw SandboxPluginError.invalidJSON("Plugin name is required")
        }
        let nameChars = plugin.name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        guard !nameChars.isEmpty else {
            throw SandboxPluginError.invalidJSON("Plugin name must contain at least one alphanumeric character")
        }

        await ensureVMConfig(for: agentId)

        var store = SandboxPluginStore.load(for: agentId)

        if store.plugins.contains(where: { $0.plugin.normalizedName == plugin.normalizedName }) {
            throw SandboxPluginError.alreadyInstalled(plugin.name)
        }

        var installed = InstalledSandboxPlugin(plugin: plugin, status: .installing)
        store.plugins.append(installed)
        store.save(for: agentId)

        do {
            try await performInstall(plugin: plugin, for: agentId)
            installed.status = .ready
            installed.errorMessage = nil
        } catch {
            installed.status = .failed
            installed.errorMessage = error.localizedDescription
        }

        if let idx = store.plugins.firstIndex(where: { $0.plugin.normalizedName == plugin.normalizedName }) {
            store.plugins[idx] = installed
        }
        store.save(for: agentId)

        if installed.status == .ready {
            await registerTools(plugin: plugin, agentId: agentId)

            // Discover and persist MCP tools so they survive app restart
            if plugin.mcp != nil {
                let discovered = try? await MCPBridge.shared.ensureRunning(agentId: agentId, plugin: plugin)
                let mcpTools = discovered?.map {
                    DiscoveredMCPTool(name: $0.name, description: $0.description, inputSchemaJSON: $0.inputSchemaJSON)
                }
                installed.discoveredMCPTools = mcpTools

                var updatedStore = SandboxPluginStore.load(for: agentId)
                if let idx = updatedStore.plugins.firstIndex(where: { $0.plugin.normalizedName == plugin.normalizedName }) {
                    updatedStore.plugins[idx] = installed
                    updatedStore.save(for: agentId)
                }

                await registerMCPTools(installed: installed, agentId: agentId)
            }

            await EventBus.shared.emit(eventType: "plugin.installed", payload: """
                {"name":"\(plugin.name)","agent_id":"\(agentId.uuidString)"}
                """)
        } else if let msg = installed.errorMessage {
            await EventBus.shared.emit(eventType: "plugin.error", payload: """
                {"name":"\(plugin.name)","error":"\(msg)"}
                """)
        }

        postSandboxPluginsChanged()
    }

    // MARK: - Retry

    /// Retry installation: wipe the project folder and re-run setup.
    public func retry(name: String, for agentId: UUID) async throws {
        var store = SandboxPluginStore.load(for: agentId)
        guard let idx = store.plugins.firstIndex(where: { $0.plugin.normalizedName == name.lowercased().replacingOccurrences(of: " ", with: "-") }) else {
            throw SandboxPluginError.pluginNotFound(name)
        }

        let plugin = store.plugins[idx].plugin

        await unregisterTools(plugin: plugin, agentId: agentId)

        store.plugins[idx].status = .installing
        store.plugins[idx].errorMessage = nil
        store.save(for: agentId)

        do {
            let conn = try await ensureVM(for: agentId)
            let pluginDir = "/workspace/plugins/\(plugin.normalizedName)"
            _ = try await conn.exec(command: "rm -rf \(pluginDir)")

            try await performInstall(plugin: plugin, for: agentId)
            store.plugins[idx].status = .ready
            store.plugins[idx].errorMessage = nil
        } catch {
            store.plugins[idx].status = .failed
            store.plugins[idx].errorMessage = error.localizedDescription
        }

        store.save(for: agentId)

        if store.plugins[idx].status == .ready {
            await registerTools(plugin: plugin, agentId: agentId)
        }

        postSandboxPluginsChanged()
    }

    // MARK: - Uninstall

    /// Remove a sandbox plugin from an agent.
    public func uninstall(name: String, for agentId: UUID) async throws {
        var store = SandboxPluginStore.load(for: agentId)
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "-")
        guard let idx = store.plugins.firstIndex(where: { $0.plugin.normalizedName == normalized }) else {
            throw SandboxPluginError.pluginNotFound(name)
        }

        let installed = store.plugins[idx]
        await unregisterTools(plugin: installed.plugin, agentId: agentId)
        await unregisterMCPTools(installed: installed, agentId: agentId)
        await MCPBridge.shared.stop(agentId: agentId, pluginName: installed.plugin.normalizedName)
        await EventBus.shared.unsubscribeAll(pluginId: installed.plugin.normalizedName)

        if let conn = await MainActor.run(body: { VMManager.shared.vsockConnection(for: agentId) }) {
            _ = try? await conn.exec(command: "rm -rf /workspace/plugins/\(installed.plugin.normalizedName)")
        }

        store.plugins.remove(at: idx)
        store.save(for: agentId)

        postSandboxPluginsChanged()
    }

    // MARK: - Query

    /// List all sandbox plugins for an agent.
    public func listPlugins(for agentId: UUID) -> [SandboxPlugin] {
        SandboxPluginStore.load(for: agentId).plugins.map { $0.plugin }
    }

    /// List installed sandbox plugins with status.
    public func listInstalled(for agentId: UUID) -> [InstalledSandboxPlugin] {
        SandboxPluginStore.load(for: agentId).plugins
    }

    // MARK: - Internal Install Pipeline

    private static let safeDepNamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9][a-zA-Z0-9._+\\-]*$")

    private func performInstall(plugin: SandboxPlugin, for agentId: UUID) async throws {
        let conn = try await ensureVM(for: agentId)
        let pluginDir = "/workspace/plugins/\(plugin.normalizedName)"

        // 1. Install global dependencies
        if let deps = plugin.dependencies, !deps.isEmpty {
            for dep in deps {
                let range = NSRange(dep.startIndex..., in: dep)
                guard Self.safeDepNamePattern.firstMatch(in: dep, range: range) != nil else {
                    throw SandboxPluginError.setupFailed("Invalid dependency name: \(dep)")
                }
            }
            let depsList = deps.joined(separator: " ")
            let result = try await conn.exec(command: "apk add --no-cache \(depsList)", timeout: 120)
            if result.exitCode != 0 {
                throw SandboxPluginError.setupFailed("apk add failed: \(result.stderr)")
            }
        }

        // 2. Create project folder
        let mkdirResult = try await conn.exec(command: "mkdir -p \(pluginDir)")
        if mkdirResult.exitCode != 0 {
            throw SandboxPluginError.setupFailed("Failed to create plugin directory")
        }

        // 3. Seed files
        if let files = plugin.files {
            for (path, content) in files {
                let fullPath = "\(pluginDir)/\(path)"
                let dir = (fullPath as NSString).deletingLastPathComponent
                _ = try await conn.exec(command: "mkdir -p \(dir)")
                try await conn.writeFile(path: fullPath, content: content)
            }
        }

        // 4. Run setup
        if let setup = plugin.setup, !setup.isEmpty {
            let result = try await conn.exec(command: setup, cwd: pluginDir, timeout: 300)
            if result.exitCode != 0 {
                throw SandboxPluginError.setupFailed("Setup command failed (exit \(result.exitCode)): \(result.stderr)")
            }
        }
    }

    // MARK: - Tool Registration

    private func registerTools(plugin: SandboxPlugin, agentId: UUID) async {
        guard let tools = plugin.tools else { return }
        let pluginName = plugin.normalizedName
        let secrets = plugin.secrets ?? []

        await MainActor.run {
            var toolNames: [String] = []
            for toolSpec in tools {
                let sandboxTool = SandboxTool(
                    pluginName: pluginName,
                    spec: toolSpec,
                    agentId: agentId,
                    secrets: secrets
                )
                ToolRegistry.shared.register(sandboxTool)
                toolNames.append(sandboxTool.name)
            }

            updateAgentEnabledTools(agentId: agentId, toolNames: toolNames, enabled: true)
        }
    }

    private func unregisterTools(plugin: SandboxPlugin, agentId: UUID) async {
        guard let tools = plugin.tools else { return }
        let pluginName = plugin.normalizedName

        await MainActor.run {
            var toolNames: [String] = []
            for toolSpec in tools {
                let name = SandboxTool.registeredName(pluginName: pluginName, toolId: toolSpec.id)
                ToolRegistry.shared.unregister(name: name)
                toolNames.append(name)
            }

            updateAgentEnabledTools(agentId: agentId, toolNames: toolNames, enabled: false)
        }
    }

    private func registerMCPTools(installed: InstalledSandboxPlugin, agentId: UUID) async {
        guard let mcpTools = installed.discoveredMCPTools, !mcpTools.isEmpty else { return }
        let plugin = installed.plugin
        let pluginName = plugin.normalizedName

        await MainActor.run {
            var toolNames: [String] = []
            for discovered in mcpTools {
                let tool = MCPSandboxTool(
                    pluginName: pluginName,
                    plugin: plugin,
                    discovered: discovered,
                    agentId: agentId
                )
                ToolRegistry.shared.register(tool)
                toolNames.append(tool.name)
            }
            updateAgentEnabledTools(agentId: agentId, toolNames: toolNames, enabled: true)
        }
    }

    private func unregisterMCPTools(installed: InstalledSandboxPlugin, agentId: UUID) async {
        guard let mcpTools = installed.discoveredMCPTools, !mcpTools.isEmpty else { return }
        let pluginName = installed.plugin.normalizedName

        await MainActor.run {
            var toolNames: [String] = []
            for discovered in mcpTools {
                let name = MCPSandboxTool.registeredName(pluginName: pluginName, mcpToolName: discovered.name)
                ToolRegistry.shared.unregister(name: name)
                toolNames.append(name)
            }
            updateAgentEnabledTools(agentId: agentId, toolNames: toolNames, enabled: false)
        }
    }

    /// Update the agent's enabledTools map to include/exclude sandbox tool names.
    @MainActor
    private func updateAgentEnabledTools(agentId: UUID, toolNames: [String], enabled: Bool) {
        guard var agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else { return }
        var tools = agent.enabledTools ?? [:]
        for name in toolNames {
            if enabled {
                tools[name] = true
            } else {
                tools.removeValue(forKey: name)
            }
        }
        agent.enabledTools = tools.isEmpty ? nil : tools
        AgentManager.shared.update(agent)
    }

    // MARK: - VM Lifecycle

    /// Auto-assign a default VMConfig if the agent doesn't have one yet.
    private func ensureVMConfig(for agentId: UUID) async {
        await MainActor.run {
            guard var agent = AgentManager.shared.agent(for: agentId),
                  !agent.isBuiltIn,
                  agent.vmConfig == nil else { return }
            agent.vmConfig = VMConfig()
            AgentManager.shared.update(agent)
        }
    }

    private func ensureVM(for agentId: UUID) async throws -> VsockConnection {
        try await VMManager.shared.ensureRunning(agentId: agentId)
        guard let conn = await MainActor.run(body: { VMManager.shared.vsockConnection(for: agentId) }) else {
            throw SandboxPluginError.vmNotAvailable
        }
        return conn
    }

    // MARK: - Notifications

    private func postSandboxPluginsChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sandboxPluginsChanged, object: nil)
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }
    }
}
