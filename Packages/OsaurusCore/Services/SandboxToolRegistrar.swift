//
//  SandboxToolRegistrar.swift
//  osaurus
//
//  Bridges the sandbox infrastructure with the ToolRegistry by
//  registering/unregistering sandbox tools in response to agent
//  switches, plugin installs, and container lifecycle events.
//

import Combine
import Foundation

@MainActor
public final class SandboxToolRegistrar {
    public static let shared = SandboxToolRegistrar()

    private var observers: [NSObjectProtocol] = []
    private var statusCancellable: AnyCancellable?

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app startup (after sandbox auto-start attempt).
    /// Sets up all notification observers and performs initial registration.
    public func start() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.handleAgentChanged() } }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginInstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                let agentId = note.userInfo?["agentId"] as? String
                Task { @MainActor in self?.handlePluginInstalled(pluginId: pluginId, agentId: agentId) }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginUninstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in self?.handlePluginUninstalled(pluginId: pluginId) }
            }
        )

        statusCancellable = SandboxManager.State.shared.$status
            .removeDuplicates()
            .sink { [weak self] newStatus in
                Task { @MainActor in self?.handleContainerStatusChanged(newStatus) }
            }

        registerToolsForCurrentAgent()
    }

    // MARK: - Registration

    /// Unregisters all sandbox tools, then re-registers builtin + plugin
    /// tools for the current active agent only when the container is running.
    /// This ensures sandbox tools are never exposed in the LLM context when
    /// the sandbox is unavailable.
    public func registerToolsForCurrentAgent() {
        ToolRegistry.shared.unregisterAllSandboxTools()

        guard SandboxManager.State.shared.status == .running else { return }

        let agent = AgentManager.shared.activeAgent
        let agentId = agent.id.uuidString
        let agentName = linuxName(for: agentId)

        BuiltinSandboxTools.register(
            agentId: agentId,
            agentName: agentName,
            config: agent.autonomousExec
        )

        let plugins = SandboxPluginManager.shared.plugins(for: agentId)
        for installed in plugins where installed.status == .ready {
            ToolRegistry.shared.registerSandboxPluginTools(
                plugin: installed.plugin,
                agentId: agentId,
                agentName: agentName
            )
        }
    }

    // MARK: - Event Handlers

    private func handleAgentChanged() {
        registerToolsForCurrentAgent()
    }

    private func handlePluginInstalled(pluginId: String?, agentId: String?) {
        let currentAgentId = AgentManager.shared.activeAgent.id.uuidString
        guard let pluginId, let agentId,
            agentId == currentAgentId,
            let installed = SandboxPluginManager.shared.plugin(id: pluginId, for: agentId),
            installed.status == .ready
        else { return }

        ToolRegistry.shared.registerSandboxPluginTools(
            plugin: installed.plugin,
            agentId: agentId,
            agentName: linuxName(for: agentId)
        )
    }

    private func handlePluginUninstalled(pluginId: String?) {
        guard let pluginId else { return }
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
    }

    private func handleContainerStatusChanged(_: ContainerStatus) {
        registerToolsForCurrentAgent()
    }

    // MARK: - Helpers

    /// Mirrors `SandboxPluginManager.agentLinuxName(for:)`.
    private func linuxName(for agentId: String) -> String {
        let name =
            agentId
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? "agent" : name
    }

}
