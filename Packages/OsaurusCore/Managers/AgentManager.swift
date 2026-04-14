//
//  AgentManager.swift
//  osaurus
//
//  Manages agent lifecycle - loading, saving, switching, and notifications
//

import Combine
import Foundation
import LocalAuthentication
import SwiftUI

/// Notification posted when the active agent changes or an agent is updated
extension Notification.Name {
    static let activeAgentChanged = Notification.Name("activeAgentChanged")
    static let agentUpdated = Notification.Name("agentUpdated")
}

public struct AgentDeleteResult: Sendable {
    public let deleted: Bool
    public let sandboxCleanupNotice: SandboxCleanupNotice?
}

/// Manages all agents and the currently active agent
@MainActor
public final class AgentManager: ObservableObject {
    public static let shared = AgentManager()

    /// All available agents (built-in + custom)
    @Published public private(set) var agents: [Agent] = []

    /// The currently active agent ID
    @Published public private(set) var activeAgentId: UUID = Agent.defaultId

    /// The currently active agent
    public var activeAgent: Agent {
        agents.first { $0.id == activeAgentId } ?? Agent.default
    }

    private init() {
        refresh()
        migrateAgentAddressesIfNeeded()

        // Load saved active agent
        if let savedId = loadActiveAgentId() {
            // Verify agent still exists
            if agents.contains(where: { $0.id == savedId }) {
                activeAgentId = savedId
            }
        }
    }

    // MARK: - Public API

    /// Reload agents from disk
    public func refresh() {
        agents = AgentStore.loadAll()
    }

    /// Set the active agent
    public func setActiveAgent(_ id: UUID) {
        // Verify agent exists, fallback to default if not
        let targetId = agents.contains(where: { $0.id == id }) ? id : Agent.defaultId

        if activeAgentId != targetId {
            activeAgentId = targetId
            saveActiveAgentId(targetId)
            NotificationCenter.default.post(name: .activeAgentChanged, object: nil)
        }
    }

    /// Create a new agent
    @discardableResult
    public func create(
        name: String,
        description: String = "",
        systemPrompt: String = "",
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil
    ) -> Agent {
        let agent = Agent(
            id: UUID(),
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        add(agent)
        return agent
    }

    /// Save a pre-built agent, refresh the list, and assign a cryptographic address.
    public func add(_ agent: Agent) {
        AgentStore.save(agent)
        refresh()
        try? assignAddress(to: agent)
    }

    /// Update an existing agent
    public func update(_ agent: Agent) {
        guard !agent.isBuiltIn else {
            print("[Osaurus] Cannot update built-in agent")
            return
        }
        var updated = agent
        updated.updatedAt = Date()
        AgentStore.save(updated)
        refresh()
        NotificationCenter.default.post(name: .agentUpdated, object: agent.id)
    }

    /// Derive and assign a cryptographic address for an agent.
    /// No-ops for built-in agents, agents that already have an address, or when no master key exists.
    public func assignAddress(to agent: Agent) throws {
        guard !agent.isBuiltIn, agent.agentAddress == nil else { return }
        guard MasterKey.exists() else { return }

        let context = OsaurusIdentityContext.biometric()
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer {
            masterKeyData.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }

        let usedIndices = Set(agents.compactMap(\.agentIndex))
        var nextIndex: UInt32 = 0
        while usedIndices.contains(nextIndex) { nextIndex += 1 }

        let address = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)

        var updated = agent
        updated.agentIndex = nextIndex
        updated.agentAddress = address
        update(updated)
    }

    /// Delete an agent by ID
    @discardableResult
    public func delete(id: UUID) async -> AgentDeleteResult {
        guard AgentStore.delete(id: id) else {
            return AgentDeleteResult(deleted: false, sandboxCleanupNotice: nil)
        }

        // If we deleted the active agent, switch to default
        if activeAgentId == id {
            setActiveAgent(Agent.defaultId)
        }

        refresh()
        let cleanupNotice = await SandboxAgentProvisioner.shared.unprovision(agentId: id).notice
        return AgentDeleteResult(deleted: true, sandboxCleanupNotice: cleanupNotice)
    }

    /// Get an agent by ID
    public func agent(for id: UUID) -> Agent? {
        agents.first { $0.id == id }
    }

    /// Get an agent by its crypto address (case-insensitive)
    public func agent(byAddress address: String) -> Agent? {
        let lower = address.lowercased()
        return agents.first { $0.agentAddress?.lowercased() == lower }
    }

    /// Resolve a string identifier to an agent UUID.
    /// Tries UUID parsing first, then falls back to crypto address lookup.
    public func resolveAgentId(_ identifier: String) -> UUID? {
        if let uuid = UUID(uuidString: identifier) {
            return agents.contains(where: { $0.id == uuid }) ? uuid : nil
        }
        return agent(byAddress: identifier)?.id
    }

    /// Import an agent from JSON data
    @discardableResult
    public func importAgent(from data: Data) throws -> Agent {
        let agent = try Agent.importFromJSON(data)
        AgentStore.save(agent)
        refresh()
        return agent
    }

    /// Export an agent to JSON data
    public func exportAgent(_ agent: Agent) throws -> Data {
        try agent.exportToJSON()
    }

    // MARK: - Active Agent Persistence

    private static let activeAgentKey = "activeAgentId"
    private static let agentAddressesMigratedKey = "agentAddressesMigrated"

    private func loadActiveAgentId() -> UUID? {
        migrateActiveAgentFileIfNeeded()
        guard let string = UserDefaults.standard.string(forKey: Self.activeAgentKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func saveActiveAgentId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeAgentKey)
    }

    /// One-time migration: assign cryptographic addresses to existing agents that don't have one.
    /// Retries on each launch until a master key is available.
    private func migrateAgentAddressesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.agentAddressesMigratedKey) else { return }
        guard MasterKey.exists() else { return }

        for agent in agents where !agent.isBuiltIn && agent.agentAddress == nil {
            try? assignAddress(to: agent)
        }

        UserDefaults.standard.set(true, forKey: Self.agentAddressesMigratedKey)
    }

    /// One-time migration: read the legacy active.txt file into UserDefaults, then delete it.
    private func migrateActiveAgentFileIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.activeAgentKey) == nil else { return }

        let legacyFiles = [
            OsaurusPaths.agents().appendingPathComponent("active.txt"),
            OsaurusPaths.root().appendingPathComponent("ActivePersonaId.txt"),
        ]
        let fm = FileManager.default
        for file in legacyFiles {
            guard fm.fileExists(atPath: file.path),
                let data = try? Data(contentsOf: file),
                let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                let uuid = UUID(uuidString: str)
            else { continue }
            UserDefaults.standard.set(uuid.uuidString, forKey: Self.activeAgentKey)
            try? fm.removeItem(at: file)
            return
        }
    }
}

// MARK: - Agent Configuration Helpers

extension AgentManager {
    /// Get the effective sandbox execution config for an agent.
    public func effectiveAutonomousExec(for agentId: UUID) -> AutonomousExecConfig? {
        guard let agent = agent(for: agentId) else {
            return nil
        }

        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultAutonomousExec
        }

        return agent.autonomousExec
    }

    /// Update sandbox execution config for an agent.
    public func updateAutonomousExec(_ config: AutonomousExecConfig?, for agentId: UUID) async throws {
        let wasEnabled = effectiveAutonomousExec(for: agentId)?.enabled ?? false
        let willBeEnabled = config?.enabled ?? false

        // Save config first so the UI reflects the new state immediately
        // (enables loading indicator while provisioning runs).
        if agentId == Agent.defaultId {
            var chatConfig = ChatConfigurationStore.load()
            chatConfig.defaultAutonomousExec = config
            ChatConfigurationStore.save(chatConfig)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
        } else {
            guard var agent = agent(for: agentId) else { return }
            agent.autonomousExec = config
            update(agent)
        }

        if willBeEnabled && !wasEnabled {
            try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
        }
    }

    /// Get the effective system prompt for an agent (combining with global if needed)
    public func effectiveSystemPrompt(for agentId: UUID) -> String {
        guard let agent = agent(for: agentId) else {
            return ChatConfigurationStore.load().systemPrompt
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().systemPrompt
        }

        // Custom agents use their own system prompt
        return agent.systemPrompt
    }

    /// Get the effective model for an agent
    /// For custom agents without a model set, falls back to Default agent's model
    public func effectiveModel(for agentId: UUID) -> String? {
        guard let agent = agent(for: agentId) else {
            return ChatConfigurationStore.load().defaultModel
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultModel
        }

        // Custom agent: use agent's model if set, otherwise fall back to Default agent's model
        return agent.defaultModel ?? ChatConfigurationStore.load().defaultModel
    }

    /// Get the effective temperature for an agent
    public func effectiveTemperature(for agentId: UUID) -> Float? {
        guard let agent = agent(for: agentId) else {
            return ChatConfigurationStore.load().temperature
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().temperature
        }

        return agent.temperature
    }

    /// Get the effective max tokens for an agent
    public func effectiveMaxTokens(for agentId: UUID) -> Int? {
        guard let agent = agent(for: agentId) else {
            return ChatConfigurationStore.load().maxTokens
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().maxTokens
        }

        return agent.maxTokens
    }

    /// Whether tools are disabled for an agent.
    /// Default agent defers to global `ChatConfiguration.disableTools`.
    /// Custom agents use their own flag (defaulting to false), OR-ed with the global flag.
    public func effectiveToolsDisabled(for agentId: UUID) -> Bool {
        let globalDisabled = ChatConfigurationStore.load().disableTools
        guard let agent = agent(for: agentId) else { return globalDisabled }
        if agent.id == Agent.defaultId { return globalDisabled }
        return (agent.disableTools ?? false) || globalDisabled
    }

    /// Whether memory is disabled for an agent.
    /// Default agent defers to global `MemoryConfiguration.enabled` (inverted).
    /// Custom agents use their own flag (defaulting to false), OR-ed with global disabled.
    public func effectiveMemoryDisabled(for agentId: UUID) -> Bool {
        let globalDisabled = !MemoryConfigurationStore.load().enabled
        guard let agent = agent(for: agentId) else { return globalDisabled }
        if agent.id == Agent.defaultId { return globalDisabled }
        return (agent.disableMemory ?? false) || globalDisabled
    }

    /// Get the effective tool selection mode for an agent.
    /// Default agent always uses .auto (controlled by global preflightSearchMode).
    public func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode {
        guard let agent = agent(for: agentId) else { return .auto }
        if agent.id == Agent.defaultId { return .auto }
        return agent.toolSelectionMode ?? .auto
    }

    /// Get the manually selected tool names for an agent, or nil when not in manual mode.
    public func effectiveManualToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId { return nil }
        guard agent.toolSelectionMode == .manual else { return nil }
        return agent.manualToolNames
    }

    /// Get the manually selected skill names for an agent, or nil when not in manual mode.
    public func effectiveManualSkillNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId { return nil }
        guard agent.toolSelectionMode == .manual else { return nil }
        return agent.manualSkillNames
    }

    /// Get the theme ID for an agent (nil if agent uses global theme)
    public func themeId(for agentId: UUID) -> UUID? {
        guard let agent = agent(for: agentId) else {
            return nil
        }

        // Default agent uses global theme
        if agent.id == Agent.defaultId {
            return nil
        }

        return agent.themeId
    }

    /// Update the default model for an agent
    /// - Parameters:
    ///   - agentId: The agent to update
    ///   - model: The model ID to set as default (nil to clear/use global)
    public func updateDefaultModel(for agentId: UUID, model: String?) {
        // Handle Default agent by saving to ChatConfiguration
        if agentId == Agent.defaultId {
            var config = ChatConfigurationStore.load()
            config.defaultModel = model
            ChatConfigurationStore.save(config)
            return
        }

        // Handle custom agents
        guard var agent = agent(for: agentId) else { return }
        guard !agent.isBuiltIn else {
            print("[Osaurus] Cannot update built-in agent's model")
            return
        }

        agent.defaultModel = model
        agent.updatedAt = Date()
        AgentStore.save(agent)
        refresh()
    }

}
