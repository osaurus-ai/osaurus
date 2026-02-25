//
//  AgentManager.swift
//  osaurus
//
//  Manages agent lifecycle - loading, saving, switching, and notifications
//

import Combine
import Foundation
import SwiftUI

/// Notification posted when the active agent changes or an agent is updated
extension Notification.Name {
    static let activeAgentChanged = Notification.Name("activeAgentChanged")
    static let agentUpdated = Notification.Name("agentUpdated")
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
        enabledTools: [String: Bool]? = nil,
        enabledSkills: [String: Bool]? = nil,
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
            enabledTools: enabledTools,
            enabledSkills: enabledSkills,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        AgentStore.save(agent)
        refresh()
        return agent
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

    /// Delete an agent by ID
    /// Returns true if deletion was successful
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard AgentStore.delete(id: id) else {
            return false
        }

        // If we deleted the active agent, switch to default
        if activeAgentId == id {
            setActiveAgent(Agent.defaultId)
        }

        refresh()
        return true
    }

    /// Get an agent by ID
    public func agent(for id: UUID) -> Agent? {
        agents.first { $0.id == id }
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

    private func loadActiveAgentId() -> UUID? {
        migrateActiveAgentFileIfNeeded()
        guard let string = UserDefaults.standard.string(forKey: Self.activeAgentKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func saveActiveAgentId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeAgentKey)
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

    /// Get the effective tool overrides for an agent
    public func effectiveToolOverrides(for agentId: UUID) -> [String: Bool]? {
        guard let agent = agent(for: agentId) else {
            return nil
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return nil
        }

        return agent.enabledTools
    }

    /// Get the effective skill overrides for an agent
    public func effectiveSkillOverrides(for agentId: UUID) -> [String: Bool]? {
        guard let agent = agent(for: agentId) else {
            return nil
        }

        // Default agent uses global settings
        if agent.id == Agent.defaultId {
            return nil
        }

        return agent.enabledSkills
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

    // MARK: - Tool/Skill Override Updates

    /// Update a single tool override for an agent
    /// For Default agent, updates global config. For custom agents, updates agent's enabledTools.
    public func setToolEnabled(_ enabled: Bool, tool: String, for agentId: UUID) {
        // Default agent -> update global config (this posts .toolsListChanged)
        if agentId == Agent.defaultId {
            ToolRegistry.shared.setEnabled(enabled, for: tool)
            return
        }

        // Custom agent -> update agent's enabledTools
        guard var agent = agent(for: agentId) else { return }
        var overrides = agent.enabledTools ?? [:]
        overrides[tool] = enabled
        agent.enabledTools = overrides
        agent.updatedAt = Date()
        AgentStore.save(agent)
        refresh()
        // Post notification to trigger token cache invalidation
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Update a single skill override for an agent
    /// For Default agent, updates global config. For custom agents, updates agent's enabledSkills.
    public func setSkillEnabled(_ enabled: Bool, skill: String, for agentId: UUID) {
        // Default agent -> update global skill config (this posts .skillsListChanged)
        if agentId == Agent.defaultId {
            if let s = SkillManager.shared.skill(named: skill) {
                SkillManager.shared.setEnabled(enabled, for: s.id)
            }
            return
        }

        // Custom agent -> update agent's enabledSkills
        guard var agent = agent(for: agentId) else { return }
        var overrides = agent.enabledSkills ?? [:]
        overrides[skill] = enabled
        agent.enabledSkills = overrides
        agent.updatedAt = Date()
        AgentStore.save(agent)
        refresh()
        // Post notification to trigger token cache invalidation
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }

    /// Enable all tools for an agent (batched for efficiency)
    public func enableAllTools(for agentId: UUID, tools: [String]) {
        setAllTools(enabled: true, for: agentId, tools: tools)
    }

    /// Disable all tools for an agent (batched for efficiency)
    public func disableAllTools(for agentId: UUID, tools: [String]) {
        setAllTools(enabled: false, for: agentId, tools: tools)
    }

    /// Enable all skills for an agent (batched for efficiency)
    public func enableAllSkills(for agentId: UUID, skills: [String]) {
        setAllSkills(enabled: true, for: agentId, skills: skills)
    }

    /// Disable all skills for an agent (batched for efficiency)
    public func disableAllSkills(for agentId: UUID, skills: [String]) {
        setAllSkills(enabled: false, for: agentId, skills: skills)
    }

    // MARK: - Private Batch Helpers

    private func setAllTools(enabled: Bool, for agentId: UUID, tools: [String]) {
        // Default agent -> update global config
        if agentId == Agent.defaultId {
            for tool in tools {
                ToolRegistry.shared.setEnabled(enabled, for: tool)
            }
            return
        }

        // Custom agent -> batch update agent's enabledTools
        guard var agent = agent(for: agentId) else { return }
        var overrides = agent.enabledTools ?? [:]
        for tool in tools {
            overrides[tool] = enabled
        }
        agent.enabledTools = overrides
        agent.updatedAt = Date()
        AgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    private func setAllSkills(enabled: Bool, for agentId: UUID, skills: [String]) {
        // Default agent -> update global skill config
        if agentId == Agent.defaultId {
            for skillName in skills {
                if let s = SkillManager.shared.skill(named: skillName) {
                    SkillManager.shared.setEnabled(enabled, for: s.id)
                }
            }
            return
        }

        // Custom agent -> batch update agent's enabledSkills
        guard var agent = agent(for: agentId) else { return }
        var overrides = agent.enabledSkills ?? [:]
        for skill in skills {
            overrides[skill] = enabled
        }
        agent.enabledSkills = overrides
        agent.updatedAt = Date()
        AgentStore.save(agent)
        refresh()
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }
}
