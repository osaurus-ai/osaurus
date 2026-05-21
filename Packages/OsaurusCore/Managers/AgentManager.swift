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
    /// Posted from `AgentManager.add(_:)` after the new agent is persisted
    /// and an address has been assigned (best effort). `userInfo["agentId"]`
    /// is the new agent's UUID. Subscribed by `PluginManager` so plugins
    /// receive an initial config + tunnel-URL push for the new agent
    /// (otherwise plugins only see the agent on the next force-reload).
    static let agentAdded = Notification.Name("agentAdded")
    /// Posted from `AgentManager.delete(id:)` after the agent record is
    /// removed. `userInfo["agentId"]` is the deleted agent's UUID.
    /// Subscribed by `PluginManager` to push `tunnel_url=""` (so plugins
    /// like Telegram can deregister webhooks) and to clean up per-agent
    /// keychain secrets that would otherwise be orphaned.
    static let agentRemoved = Notification.Name("agentRemoved")
    /// Posted by notification-tap handlers (and any future deep-link
    /// router) to drive `AgentsView` and `AgentDetailView` to a
    /// specific agent + tab + optional focused entity (e.g. saved
    /// view name, run id). userInfo keys: `agentId: UUID` (required),
    /// `tab: String?` (matches a `DetailTab.rawValue`), `viewRef:
    /// String?` (saved-view name to highlight on the Views tab).
    static let agentDetailDeeplink = Notification.Name("agentDetailDeeplink")
    /// Edge-triggered by `AgentDatabase.enforceStorageQuotaUnlocked`
    /// when the per-agent DB file crosses `storageWarnPercent` of
    /// its `storageBytesLimit`. `AgentManager` observes this and
    /// posts a rate-limited user-facing UNNotification + flips a
    /// `@Published` flag the Schema/Data tab headers read for the
    /// badge UI. userInfo: `agentId: UUID`, `usedBytes: Int`,
    /// `limitBytes: Int`, `percent: Int`.
    static let agentStorageWarn = Notification.Name("agentStorageWarn")
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

    /// Agents currently flagged as "approaching their storage
    /// quota" (≥ `storageWarnPercent` of `storageBytesLimit`). Driven
    /// off `.agentStorageWarn` notifications fired by
    /// `AgentDatabase`. Read by the Schema/Data tab headers for a
    /// "approaching quota" badge (spec §11.2). Stays sticky until the
    /// agent's data is wiped or the database resets the latch on a
    /// subsequent mutation when usage drops back below threshold.
    @Published public private(set) var storageWarningAgentIds: Set<UUID> = []

    /// Last wall-clock moment we posted a user-visible storage
    /// warning UNNotification for each agent. The spec asks for
    /// "rate-limit notifications to one per agent per 24h so
    /// repeated writes don't spam." Kept in-memory only — relaunch
    /// resets the throttle, which we accept because relaunching
    /// itself is rare enough that the user wants to see the warning
    /// again in the next session if they're still near quota.
    private var lastStorageWarningAt: [UUID: Date] = [:]
    private static let storageWarningCooldown: TimeInterval = 24 * 60 * 60

    /// `UserDefaults` keys for the persisted snapshot of every
    /// tool/skill name the registry has ever reported via
    /// `.toolsListChanged`. Used by the observer to tell *brand-new*
    /// capabilities apart from ones the user has explicitly disabled
    /// (both look "absent from the agent's allowlist" otherwise).
    private static let knownToolNamesKey = "AgentManager.knownToolNames.v1"
    private static let knownSkillNamesKey = "AgentManager.knownSkillNames.v1"

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
        //
        // We only grow with names that are *new* relative to the persisted registry
        // snapshot. On the first observation after this fix shipped the snapshot is
        // nil, so the diff is empty and we just seed — that protects upgraded users
        // from having their existing disables clobbered.
        NotificationCenter.default.addObserver(
            forName: .toolsListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.growNewlyDiscoveredCapabilities(
                    live: Set(ToolRegistry.shared.listDynamicTools().map(\.name)),
                    key: Self.knownToolNamesKey,
                    grow: self.growEnabledToolNames
                )
                self.growNewlyDiscoveredCapabilities(
                    live: Set(SkillManager.shared.skills.map(\.name)),
                    key: Self.knownSkillNamesKey,
                    grow: self.growEnabledSkillNames
                )
            }
        }

        // Storage soft-warning router. The DB layer is non-isolated;
        // it edge-triggers `.agentStorageWarn` from whatever queue
        // the mutating transaction ran on. We hop to MainActor here
        // so the rate-limit bookkeeping and `@Published` flag mutation
        // run on a stable actor. The userInfo dict is copied into
        // local primitives before the hop so we never send the
        // `Notification` value itself across the isolation boundary.
        NotificationCenter.default.addObserver(
            forName: .agentStorageWarn,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                let agentId = info["agentId"] as? UUID
            else { return }
            let percent = (info["percent"] as? Int) ?? 0
            let usedBytes = (info["usedBytes"] as? Int) ?? 0
            let limitBytes = (info["limitBytes"] as? Int) ?? 0
            Task { @MainActor in
                self?.handleStorageWarning(
                    agentId: agentId,
                    percent: percent,
                    usedBytes: usedBytes,
                    limitBytes: limitBytes
                )
            }
        }
    }

    @MainActor
    private func handleStorageWarning(
        agentId: UUID,
        percent: Int,
        usedBytes: Int,
        limitBytes: Int
    ) {

        if !storageWarningAgentIds.contains(agentId) {
            storageWarningAgentIds.insert(agentId)
        }

        // Rate-limit the user-facing notification to one per agent
        // per `storageWarningCooldown`. The published badge stays
        // sticky regardless so the UI stays informative even when
        // the toast doesn't refire.
        let now = Date()
        if let last = lastStorageWarningAt[agentId],
            now.timeIntervalSince(last) < Self.storageWarningCooldown
        {
            return
        }
        lastStorageWarningAt[agentId] = now

        let name = agent(for: agentId)?.name ?? "Agent"
        let usedMB = Double(usedBytes) / 1_048_576.0
        let limitMB = Double(limitBytes) / 1_048_576.0
        let body = String(
            format: "%@ has used %d%% of its storage quota (%.1f / %.1f MB).",
            name,
            percent,
            usedMB,
            limitMB
        )
        NotificationService.shared.postAgentEvent(
            agentId: agentId,
            agentName: name,
            title: "Storage \(percent)% full",
            body: body,
            viewRef: nil
        )
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
        // Notify subscribers (e.g. PluginManager) so plugins get an
        // initial config / tunnel-URL push for the new agent without
        // needing to wait for the next plugin force-reload.
        NotificationCenter.default.post(
            name: .agentAdded,
            object: nil,
            userInfo: ["agentId": agent.id]
        )
    }

    /// Set or replace the custom avatar image for `agentId`. Writes the bytes
    /// to disk under `agents/avatars/`, updates the agent record, and posts
    /// `.agentUpdated`. Returns true on success.
    @discardableResult
    public func setCustomAvatar(_ data: Data, ext: String, for agentId: UUID) -> Bool {
        guard var agent = AgentStore.load(id: agentId), !agent.isBuiltIn else { return false }
        guard let filename = AgentStore.writeCustomAvatar(data, ext: ext, for: agentId) else {
            return false
        }
        agent.customAvatarFilename = filename
        // Clear mascot id when a custom image is set so the avatar stack
        // resolves unambiguously to the user-provided image.
        agent.avatar = nil
        update(agent)
        return true
    }

    /// Remove any custom avatar for `agentId` and clear the agent record.
    public func clearCustomAvatar(for agentId: UUID) {
        guard var agent = AgentStore.load(id: agentId), !agent.isBuiltIn else { return }
        AgentStore.removeCustomAvatar(for: agentId)
        agent.customAvatarFilename = nil
        update(agent)
    }

    /// Assign sequential `order` values (0...N-1) to custom agents in the
    /// given sequence and refresh once. Built-ins and duplicate IDs are ignored;
    /// any omitted custom agents keep their current relative position after the
    /// requested IDs so every persisted store ends up with one normalized order.
    public func reorder(orderedIds: [UUID]) {
        let customAgents = AgentStore.loadAll().filter { !$0.isBuiltIn }
        var customById: [UUID: Agent] = [:]
        for agent in customAgents where customById[agent.id] == nil {
            customById[agent.id] = agent
        }
        var seen = Set<UUID>()
        var normalizedAgents: [Agent] = []

        for id in orderedIds {
            guard let agent = customById[id], seen.insert(id).inserted else { continue }
            normalizedAgents.append(agent)
        }

        for agent in customAgents where seen.insert(agent.id).inserted {
            normalizedAgents.append(agent)
        }

        for (index, agent) in normalizedAgents.enumerated() {
            guard var agent = AgentStore.load(id: agent.id), !agent.isBuiltIn else { continue }
            guard agent.order != index else { continue }
            agent.order = index
            AgentStore.save(agent)
        }
        refresh()
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
        // Push the storage limit + soft-warn threshold down to any
        // open agent-DB connection (spec §11.2 + §11.3). When the
        // agent's DB hasn't been opened yet the store's cache miss
        // is harmless — both values land on the next open.
        AgentDatabaseStore.shared.setStorageLimit(
            for: agent.id,
            bytes: updated.settings.limits.storageBytesLimit
        )
        AgentDatabaseStore.shared.setStorageWarnPercent(
            for: agent.id,
            percent: updated.settings.limits.storageWarnPercent
        )
        // Drop any pre-generated empty-state greetings for this agent.
        // Persona / system prompt / quick-action edits invalidate the
        // pool's cached output — the next session open should pop a
        // freshly generated greeting that reflects the new settings.
        Task { await GenerativeGreetingPool.shared.invalidate(agentId: agent.id) }
        NotificationCenter.default.post(name: .agentUpdated, object: agent.id)
    }

    /// Derive and assign a cryptographic address for an agent.
    /// No-ops for built-in agents, agents that already have an address, or when no master key exists.
    public func assignAddress(to agent: Agent) throws {
        guard !agent.isBuiltIn, agent.agentAddress == nil else { return }
        guard MasterKey.exists() else { return }

        let context = OsaurusIdentityContext.biometric()
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }

        let nextIndex = nextUnusedAgentIndex()
        let address = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)

        var updated = agent
        updated.agentIndex = nextIndex
        updated.agentAddress = address
        update(updated)
    }

    /// Rotate an agent's cryptographic address: pick a fresh unused HMAC index,
    /// re-derive its address, persist, and revoke every active osk-v1 access
    /// key whose audience matched the previous address (those keys now grant
    /// access to a different identity, which is exactly the situation we're
    /// trying to undo).
    ///
    /// No-op for built-in agents. Throws if there's no master key in Keychain.
    public func rotateAddress(of agent: Agent) throws {
        guard !agent.isBuiltIn else { return }
        guard MasterKey.exists() else { throw OsaurusIdentityError.keychainReadFailed }

        let context = OsaurusIdentityContext.biometric()
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }

        let nextIndex = nextUnusedAgentIndex()
        let newAddress = try AgentKey.deriveAddress(masterKey: masterKeyData, index: nextIndex)
        let previousAddress = agent.agentAddress

        var updated = agent
        updated.agentIndex = nextIndex
        updated.agentAddress = newAddress
        update(updated)

        if let previousAddress {
            revokeActiveKeys(forAudience: previousAddress)
        }
    }

    /// Clear an agent's cryptographic identity and revoke every active osk-v1
    /// access key whose audience pointed at it. The agent itself stays around
    /// (the user may want to keep its prompt / settings) but it loses signing
    /// authority until `assignAddress(to:)` is called again.
    public func revokeAddress(of agent: Agent) {
        guard !agent.isBuiltIn else { return }
        guard agent.agentAddress != nil || agent.agentIndex != nil else { return }

        let previousAddress = agent.agentAddress

        var updated = agent
        updated.agentIndex = nil
        updated.agentAddress = nil
        update(updated)

        if let previousAddress {
            revokeActiveKeys(forAudience: previousAddress)
        }
    }

    /// First derivation index not already used by any agent in the list. We do
    /// not reuse indices because previously-derived addresses may still be
    /// referenced by external clients holding osk-v1 tokens.
    private func nextUnusedAgentIndex() -> UInt32 {
        let used = Set(agents.compactMap(\.agentIndex))
        var index: UInt32 = 0
        while used.contains(index) { index += 1 }
        return index
    }

    /// Revoke every still-active osk-v1 access key whose audience matches
    /// `audience`. Used by both rotate and revoke paths so the revocation
    /// behavior stays in lock-step.
    private func revokeActiveKeys(forAudience audience: OsaurusID) {
        for key in APIKeyManager.shared.listKeys(forAudience: audience) where !key.revoked {
            APIKeyManager.shared.revoke(id: key.id)
        }
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

        // Sweep every plugin's per-agent secrets for this agent. Without
        // this, deleting an agent would leave its `bot_token` / OAuth
        // credentials / `tunnel_url` / etc. in Keychain Access forever.
        // Done before posting `.agentRemoved` so subscribers see the
        // post-cleanup keychain state.
        ToolSecretsKeychain.deleteAllSecrets(forAgent: id)

        // Drop any greetings the pool was holding for this agent. We
        // can't rely on per-agent settings drift here (the agent is
        // gone) — explicit invalidation prevents the orphaned entries
        // from sitting in memory until TTL.
        await GenerativeGreetingPool.shared.invalidate(agentId: id)

        // Notify subscribers (e.g. PluginManager) so plugins can
        // deregister webhooks (push tunnel_url=nil) and tear down any
        // per-agent state of their own.
        NotificationCenter.default.post(
            name: .agentRemoved,
            object: nil,
            userInfo: ["agentId": id]
        )

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
    private static let agentAddressesMigratedKey = IdentityDefaultsKey.agentAddressesMigrated

    private func loadActiveAgentId() -> UUID? {
        migrateActiveAgentFileIfNeeded()
        guard let string = UserDefaults.standard.string(forKey: Self.activeAgentKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func saveActiveAgentId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeAgentKey)
    }

    /// One-time migration marker for pre-identity installs. Address assignment
    /// requires the master key and can prompt for Keychain/biometric access, so
    /// launch must not run it automatically. Explicit UI paths still call
    /// `assignAddress(to:)` when the user chooses an identity action.
    private func migrateAgentAddressesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.agentAddressesMigratedKey) else { return }
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

    /// Whether the Agent DB feature is enabled for an agent (spec §5.5).
    /// The default agent (`Agent.default`) is built-in and not editable, so
    /// its `Agent.settings.dbEnabled` is hard-wired off — the DB is per-agent
    /// data and only makes sense for user-created agents.
    public func effectiveDBEnabled(for agentId: UUID) -> Bool {
        guard let agent = agent(for: agentId) else { return false }
        if agent.id == Agent.defaultId { return false }
        return agent.settings.dbEnabled
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

    // MARK: - Known capability registry snapshot

    /// Diff `live` against the persisted snapshot at `key`. Newly discovered
    /// names are passed to `grow`; the snapshot is then refreshed to `live`.
    /// A missing snapshot (first observation) seeds without growing, which is
    /// what protects already-disabled capabilities on the upgrade path.
    private func growNewlyDiscoveredCapabilities(
        live: Set<String>,
        key: String,
        grow: (Set<String>) -> Void
    ) {
        if let known = loadKnownNames(forKey: key) {
            let newlyDiscovered = live.subtracting(known)
            if !newlyDiscovered.isEmpty { grow(newlyDiscovered) }
        }
        saveKnownNames(live, forKey: key)
    }

    /// Stored as a sorted `[String]` in `UserDefaults.standard` so the
    /// on-disk form is stable and diff-friendly. Returns `nil` when no
    /// snapshot has ever been written.
    private func loadKnownNames(forKey key: String) -> Set<String>? {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return nil }
        return Set(arr)
    }

    private func saveKnownNames(_ names: Set<String>, forKey key: String) {
        UserDefaults.standard.set(names.sorted(), forKey: key)
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
