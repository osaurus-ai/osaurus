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

        // Auto-grow per-agent enabled sets when new tools/skills register so users
        // who explicitly seeded their picker don't silently lose access to a freshly
        // installed plugin's capabilities. Skipped for un-seeded (nil) agents which
        // still fall back to the global registry — see `effectiveEnabledToolNames`.
        // Skills ride this same notification because plugin skills register alongside
        // their tools (see `PluginManager._loadAll`).
        NotificationCenter.default.addObserver(
            forName: .toolsListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let liveTools = ToolRegistry.shared.listDynamicTools().map(\.name)
                self.growEnabledToolNames(Set(liveTools))
                let liveSkills = SkillManager.shared.skills.map(\.name)
                self.growEnabledSkillNames(Set(liveSkills))
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
    ///
    /// Provisioning is delegated to the notification-driven path:
    /// `SandboxToolRegistrar.handleAgentUpdated` observes `.agentUpdated`
    /// and calls `registerTools`, which calls
    /// `SandboxAgentProvisioner.ensureProvisioned` (now coalesced per
    /// agent). We deliberately do NOT also call `ensureProvisioned`
    /// directly here — having two callers race through `ensureAgentUser`
    /// caused the duplicate-attempt spam noted in the audit and
    /// occasionally produced a `provisioningFailed` envelope even when
    /// the second attempt would have succeeded.
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
            // Toggling autonomous on is an explicit user action — clear any
            // prior failure cool-down so the registrar's next provisioning
            // attempt isn't suppressed.
            SandboxToolRegistrar.shared.resetStartupFailures()
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
    /// Default agent reads from `ChatConfiguration.defaultToolSelectionMode` (defaulting to .auto).
    public func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode {
        guard let agent = agent(for: agentId) else { return .auto }
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultToolSelectionMode ?? .auto
        }
        return agent.toolSelectionMode ?? .auto
    }

    /// Get the manually selected tool names for an agent, or nil when not in manual mode.
    public func effectiveManualToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            guard config.defaultToolSelectionMode == .manual else { return nil }
            return config.defaultManualToolNames
        }
        guard agent.toolSelectionMode == .manual else { return nil }
        return agent.manualToolNames
    }

    /// Get the manually selected skill names for an agent, or nil when not in manual mode.
    public func effectiveManualSkillNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            let config = ChatConfigurationStore.load()
            guard config.defaultToolSelectionMode == .manual else { return nil }
            return config.defaultManualSkillNames
        }
        guard agent.toolSelectionMode == .manual else { return nil }
        return agent.manualSkillNames
    }

    /// Tool names this agent has enabled (as a unified allow-list) regardless of mode.
    /// In Auto mode this scopes the pre-flight catalog; in Manual mode this is the strict
    /// allowlist. Returns `nil` for legacy / un-seeded agents — callers should treat that
    /// as "no scope, use the global registry" to preserve backwards compatibility.
    public func effectiveEnabledToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultManualToolNames
        }
        return agent.manualToolNames
    }

    /// Skill names this agent has enabled regardless of mode. Mirrors
    /// `effectiveEnabledToolNames` for the skills side.
    public func effectiveEnabledSkillNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            return ChatConfigurationStore.load().defaultManualSkillNames
        }
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

    /// Seed an agent's enabled tool/skill set from the live registries the first time
    /// the user opens the new capability picker. Idempotent: only writes when the field
    /// is `nil`. Without seeding, `nil` would mean "no allowlist" at runtime — i.e. the
    /// agent gets the global registry, which is what legacy auto-mode agents already
    /// expect. After seeding, every per-item toggle is a real disable, even in Auto.
    public func seedEnabledCapabilitiesIfNeeded(
        for agentId: UUID,
        defaultToolNames: [String],
        defaultSkillNames: [String]
    ) {
        guard let agent = agent(for: agentId) else { return }
        if agent.id == Agent.defaultId {
            var config = ChatConfigurationStore.load()
            var changed = false
            if config.defaultManualToolNames == nil {
                config.defaultManualToolNames = defaultToolNames
                changed = true
            }
            if config.defaultManualSkillNames == nil {
                config.defaultManualSkillNames = defaultSkillNames
                changed = true
            }
            if changed {
                ChatConfigurationStore.save(config)
                NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
            }
            return
        }
        var updated = agent
        var changed = false
        if updated.manualToolNames == nil {
            updated.manualToolNames = defaultToolNames
            changed = true
        }
        if updated.manualSkillNames == nil {
            updated.manualSkillNames = defaultSkillNames
            changed = true
        }
        if changed {
            update(updated)
        }
    }

    /// Update the agent's enabled tool allowlist (used by the capability picker).
    public func updateEnabledToolNames(_ names: [String], for agentId: UUID) {
        if agentId == Agent.defaultId {
            var config = ChatConfigurationStore.load()
            config.defaultManualToolNames = names
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.manualToolNames = names
        update(agent)
    }

    /// Update the agent's enabled skill allowlist (used by the capability picker).
    public func updateEnabledSkillNames(_ names: [String], for agentId: UUID) {
        if agentId == Agent.defaultId {
            var config = ChatConfigurationStore.load()
            config.defaultManualSkillNames = names
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.manualSkillNames = names
        update(agent)
    }

    /// Update the agent's tool selection mode (auto vs manual) without touching the
    /// enabled set. Used by the new picker's "Auto-discover" toggle.
    public func updateToolSelectionMode(_ mode: ToolSelectionMode, for agentId: UUID) {
        if agentId == Agent.defaultId {
            var config = ChatConfigurationStore.load()
            config.defaultToolSelectionMode = mode
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.toolSelectionMode = mode
        update(agent)
    }

    /// Additively insert newly-discovered tool names into every agent that has already
    /// been seeded (`manualToolNames != nil`). Triggered by `.toolsListChanged`.
    /// Un-seeded agents are skipped — their semantic is "fall back to global registry"
    /// at the runtime layer, so they pick up new tools automatically without any write.
    public func growEnabledToolNames(_ liveNames: Set<String>) {
        var configChanged = false
        var config = ChatConfigurationStore.load()
        if var current = config.defaultManualToolNames {
            let before = current.count
            for name in liveNames where !current.contains(name) { current.append(name) }
            if current.count != before {
                config.defaultManualToolNames = current
                configChanged = true
            }
        }
        if configChanged {
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
        }

        var anyAgentChanged = false
        for agent in agents where !agent.isBuiltIn {
            guard var current = agent.manualToolNames else { continue }
            let before = current.count
            for name in liveNames where !current.contains(name) { current.append(name) }
            guard current.count != before else { continue }
            var updated = agent
            updated.manualToolNames = current
            updated.updatedAt = Date()
            AgentStore.save(updated)
            anyAgentChanged = true
        }
        if anyAgentChanged {
            refresh()
        }
    }

    /// Additively insert newly-discovered skill names into every seeded agent. Mirror of
    /// `growEnabledToolNames` for skills. Called when a plugin registers skills.
    public func growEnabledSkillNames(_ liveNames: Set<String>) {
        var configChanged = false
        var config = ChatConfigurationStore.load()
        if var current = config.defaultManualSkillNames {
            let before = current.count
            for name in liveNames where !current.contains(name) { current.append(name) }
            if current.count != before {
                config.defaultManualSkillNames = current
                configChanged = true
            }
        }
        if configChanged {
            ChatConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
        }

        var anyAgentChanged = false
        for agent in agents where !agent.isBuiltIn {
            guard var current = agent.manualSkillNames else { continue }
            let before = current.count
            for name in liveNames where !current.contains(name) { current.append(name) }
            guard current.count != before else { continue }
            var updated = agent
            updated.manualSkillNames = current
            updated.updatedAt = Date()
            AgentStore.save(updated)
            anyAgentChanged = true
        }
        if anyAgentChanged {
            refresh()
        }
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
