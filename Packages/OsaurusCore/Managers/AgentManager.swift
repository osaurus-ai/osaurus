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
    @Published public private(set) var agents: [Agent] = [] {
        didSet { syncIdentityRegistry() }
    }

    /// Spawn authority changes can race asynchronous approval, provider
    /// resolution, and admission waits. Keep semantic per-agent generations
    /// rather than relying on final-value equality: an edit followed by a
    /// restore must still invalidate work prepared through the transient
    /// authority. Presentation-only fields are absent from these projections.
    private var observedSpawnAuthorityAgentIDs: Set<UUID> = []
    private var cachedSpawnLauncherAuthorities:
        [UUID: SpawnCustomLauncherAgentAuthority] = [:]
    private var cachedSpawnPermissions:
        [UUID: SubagentPermissionPolicy] = [:]
    private var cachedSpawnTargetAuthorities:
        [UUID: SpawnTargetAuthority] = [:]
    private var spawnLauncherAuthorityRevisions: [UUID: UInt64] = [:]
    private var spawnPermissionAuthorityRevisions: [UUID: UInt64] = [:]
    private var spawnTargetAuthorityRevisions: [UUID: UInt64] = [:]

    /// Mirror the current agents' crypto addresses / key indices into the
    /// thread-safe `AgentIdentityRegistry` so the off-main `APIKeyValidator`
    /// builder can accept agent-scoped tokens (e.g. keys minted by `/pair`).
    private func syncIdentityRegistry() {
        var addresses: Set<String> = []
        var indices: Set<UInt32> = []
        var addressByAgentId: [UUID: String] = [:]
        for agent in agents {
            if let addr = agent.agentAddress {
                addresses.insert(addr)
                addressByAgentId[agent.id] = addr
            }
            if let idx = agent.agentIndex { indices.insert(idx) }
        }
        AgentIdentityRegistry.shared.update(
            addresses: addresses,
            indices: indices,
            addressByAgentId: addressByAgentId
        )
        // The set of accepted agent audiences changed; let the live server
        // rebuild its validator so keys for new agents validate immediately.
        APIKeyValidatorEpoch.shared.bump()
    }

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

    /// `UserDefaults` key for the persisted snapshot of every tool name the
    /// registry has ever reported via `.toolsListChanged`. Used by the
    /// observer to tell *brand-new* tools apart from ones the user has
    /// explicitly disabled (both look "absent from the agent's allowlist"
    /// otherwise).
    private static let knownToolNamesKey = "AgentManager.knownToolNames.v1"

    private init() {
        refresh()

        // Load saved active agent
        if let savedId = loadActiveAgentId() {
            // Verify agent still exists
            if agents.contains(where: { $0.id == savedId }) {
                activeAgentId = savedId
            }
        }

        // Auto-grow per-agent enabled tool sets when new tools register so users
        // who explicitly seeded their picker don't silently lose access to a freshly
        // installed plugin's capabilities. Skipped for un-seeded (nil) agents which
        // still fall back to the global registry — see `effectiveEnabledToolNames`.
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
        let loaded = AgentStore.loadAll()
        let migrated = loaded.map { agent -> Agent in
            guard !agent.isBuiltIn, !agent.settings.legacySpawnableAgentNames.isEmpty else {
                return agent
            }
            var updated = agent
            updated.settings = agent.settings.migratingLegacySpawnableAgents(using: loaded)
            if updated.settings != agent.settings {
                AgentStore.save(updated)
            }
            return updated
        }
        installAgentSnapshot(migrated)
        SubagentConfigurationStore.migrateLegacyAgentNames(using: migrated)
        SubagentConfigurationStore.seedSpawnPoolIfNeeded(with: migrated)
    }

    /// Return one Agent plus the three Spawn-scoped generations from the same
    /// MainActor turn. Callers use this at approval/execution boundaries so a
    /// launcher, permission, or target ABA cannot produce a torn fingerprint.
    func spawnAuthoritySnapshot(for id: UUID) -> SpawnAgentAuthoritySnapshot {
        SpawnAgentAuthoritySnapshot(
            agent: agents.first { $0.id == id },
            revisions: SpawnAgentAuthorityRevisions(
                launcher: spawnLauncherAuthorityRevisions[id] ?? 0,
                permission: spawnPermissionAuthorityRevisions[id] ?? 0,
                target: spawnTargetAuthorityRevisions[id] ?? 0
            )
        )
    }

    /// Install a refreshed agent list and advance only the semantic Spawn axes
    /// that changed. The observed-id set survives deletion, so deleting and
    /// recreating the same UUID is also a revision change instead of an ABA.
    private func installAgentSnapshot(_ updatedAgents: [Agent]) {
        // Match `agent(for:)`'s first-record semantics without assuming a
        // hand-edited store can never contain duplicate UUID records.
        var nextByID: [UUID: Agent] = [:]
        for agent in updatedAgents where nextByID[agent.id] == nil {
            nextByID[agent.id] = agent
        }
        let nextIDs = Set(nextByID.keys)
        let allIDs = observedSpawnAuthorityAgentIDs.union(nextIDs)

        for id in allIDs {
            let nextAgent = nextByID[id]
            let nextLauncher = nextAgent.map(
                SpawnCustomLauncherAgentAuthority.init
            )
            let nextPermission = nextAgent?.settings.subagentPermissions.policy(
                for: SubagentCapabilityRegistry.spawn.id
            )
            let nextTarget = nextAgent.map(SpawnTargetAuthority.init)

            if observedSpawnAuthorityAgentIDs.contains(id) {
                if cachedSpawnLauncherAuthorities[id] != nextLauncher {
                    spawnLauncherAuthorityRevisions[id, default: 0] &+= 1
                }
                if cachedSpawnPermissions[id] != nextPermission {
                    spawnPermissionAuthorityRevisions[id, default: 0] &+= 1
                }
                if cachedSpawnTargetAuthorities[id] != nextTarget {
                    spawnTargetAuthorityRevisions[id, default: 0] &+= 1
                }
            }

            cachedSpawnLauncherAuthorities[id] = nextLauncher
            cachedSpawnPermissions[id] = nextPermission
            cachedSpawnTargetAuthorities[id] = nextTarget
        }

        observedSpawnAuthorityAgentIDs.formUnion(nextIDs)
        agents = updatedAgents
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
        let agent = Self.newCustomAgentRecord(
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens
        )
        add(agent)
        return agent
    }

    /// Shared seed for every newly authored custom agent, including the
    /// regular create flow and onboarding. Keeping sandbox policy here avoids
    /// one entry point silently drifting back to an unconfigured record.
    static func newCustomAgentRecord(
        name: String,
        description: String = "",
        systemPrompt: String = "",
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        now: Date = Date()
    ) -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now,
            autonomousExec: Self.sandboxDefaultAutonomousExec
        )
    }

    /// Build the record used by the Agents UI's duplicate action.
    ///
    /// `autonomousExec` is copied verbatim rather than re-seeded from the
    /// default-on policy: `nil` remains unconfigured/default-on, while an
    /// explicit `enabled: false` remains an opt-out on the duplicate.
    static func duplicateRecord(
        from agent: Agent,
        name: String,
        now: Date = Date()
    ) -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: agent.description,
            systemPrompt: agent.systemPrompt,
            themeId: agent.themeId,
            defaultModel: agent.defaultModel,
            temperature: agent.temperature,
            maxTokens: agent.maxTokens,
            chatQuickActions: agent.chatQuickActions,
            chatGreeting: agent.chatGreeting,
            chatSubtitle: agent.chatSubtitle,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now,
            autonomousExec: agent.autonomousExec,
            claudeCode: agent.claudeCode,
            pluginInstructions: agent.pluginInstructions,
            // Capability configuration is part of what "duplicate" means: a
            // MANUAL agent's copy used to come back AUTO with the whole
            // registry, and every grant (memory, tools, knowledge, web…)
            // reset to the defaults. The fields were added after the copy
            // list was written and never joined it.
            toolSelectionMode: agent.toolSelectionMode,
            manualToolNames: agent.manualToolNames,
            toolsEnabled: agent.toolsEnabled,
            memoryEnabled: agent.memoryEnabled,
            avatar: agent.avatar,
            autoSpeak: agent.autoSpeak,
            ttsVoice: agent.ttsVoice,
            settings: agent.settings
        )
    }

    /// Save a pre-built agent, refresh the list, and assign a cryptographic address.
    public func add(_ agent: Agent) {
        AgentStore.save(agent)
        refresh()
        registerInDefaultSpawnPool(agent)
        // KPI: a user-created agent. Count only — no name or configuration.
        // Built-in agents are seeded by the app, not created by the user.
        if !agent.isBuiltIn {
            FeatureTelemetry.agentCreated()
        }
        assignAddressInBackground(to: agent)
        // Notify subscribers (e.g. PluginManager) so plugins get an
        // initial config / tunnel-URL push for the new agent without
        // needing to wait for the next plugin force-reload.
        NotificationCenter.default.post(
            name: .agentAdded,
            object: nil,
            userInfo: ["agentId": agent.id]
        )
    }

    /// Restore a preserved legacy agent backup and publish it like a newly
    /// available custom agent. `AgentStore` owns conflict-safe decoding /
    /// re-id behavior; the manager refreshes UI state and gives recovered
    /// conflict copies a fresh address when the local master key is available.
    @discardableResult
    public func restoreRecoverableAgentBackup(at url: URL) throws -> Agent {
        let agent = try AgentStore.restoreRecoverableBackup(at: url)
        refresh()
        if !agent.isBuiltIn {
            try? assignAddress(to: agent)
            let restored = self.agent(for: agent.id) ?? agent
            registerInDefaultSpawnPool(restored)
            NotificationCenter.default.post(
                name: .agentAdded,
                object: nil,
                userInfo: ["agentId": agent.id]
            )
            return restored
        }
        return agent
    }

    /// Custom agents are spawnable by the orchestrator by DEFAULT: every
    /// creation path (create/add, config apply, duplicate, bundle import,
    /// backup restore) appends the new agent to the DEFAULT / main-chat spawn
    /// pool. The user can remove it in Settings → Subagents — a removal
    /// persists because this fires only on creation and the one-time seed
    /// (`spawnPoolSeeded`) never re-runs. Eval/test agents written straight
    /// through `AgentStore.save` intentionally stay out.
    func registerInDefaultSpawnPool(_ agent: Agent) {
        guard !agent.isBuiltIn else { return }
        _ = SubagentConfigurationStore.mutate { config in
            if !config.spawnableAgentIDs.contains(agent.id) {
                config.spawnableAgentIDs.append(agent.id)
            }
        }
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
        NotificationCenter.default.post(name: .agentUpdated, object: agent.id)
    }

    /// Derive and assign a cryptographic address for an agent.
    /// No-ops for built-in agents, agents that already have an address, when no
    /// master key exists, or when the master key can't be read non-interactively.
    ///
    /// Agent creation runs from headless / differently-signed processes too (the
    /// eval CLI driving the configuration agent's `agent` create tool, the in-app
    /// HTTP server, CI). The Master Key item lives in the legacy file-based login
    /// Keychain, where reading it from a process whose code signature differs
    /// from the app that created it raises a "wants to use your confidential
    /// information" ACL prompt — and `LAContext.interactionNotAllowed` /
    /// `kSecUseAuthenticationUISkip` do NOT suppress that legacy prompt (it once
    /// hung a headless DefaultAgent run for minutes at 0% CPU). The real headless
    /// protection is the keychain-disable gate: those processes run with
    /// `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, so `MasterKey.exists()` returns
    /// false and we short-circuit before any read. The non-interactive context
    /// below is still correct defense for the data-protection-Keychain path, and
    /// `try?` keeps a read failure best-effort (create the agent without a crypto
    /// address) rather than throwing. The same-signed app reads its own
    /// `kSecAttrAccessibleWhenUnlocked` key without UI, so assignment is unchanged
    /// there.
    /// Off-main variant of `assignAddress(to:)` for the agent-creation path.
    /// `MasterKey.exists()` and the key read are synchronous keychain queries
    /// that block on securityd's mutex — calling them on the main thread has
    /// tripped the watchdog when securityd is contended (e.g. a concurrent
    /// identity setup or iCloud keychain sync). The index is reserved on the
    /// main actor before detaching so two rapid creations can't collide, and
    /// the write-back re-loads the agent and only fills a still-empty address,
    /// so a concurrent `update`/`rotateAddress` can't be clobbered.
    /// Schedule best-effort address assignment without synchronously touching
    /// Keychain on the main actor. Automatic UI/runtime callers must use this
    /// path; `assignAddress(to:)` remains for explicit flows that need a
    /// synchronous result before continuing.
    func assignAddressInBackground(to agent: Agent) {
        guard !agent.isBuiltIn, agent.agentAddress == nil else { return }
        let index = nextUnusedAgentIndex()
        // Park the reservation immediately (address comes later) so another
        // creation in the same window gets the next index.
        if var reserving = self.agent(for: agent.id), reserving.agentIndex == nil {
            reserving.agentIndex = index
            update(reserving)
        }
        Task.detached(priority: .userInitiated) {
            guard MasterKey.exists() else { return }
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            context.interactionNotAllowed = true
            guard var masterKeyData = try? MasterKey.getPrivateKey(context: context) else { return }
            defer { masterKeyData.zeroOut() }
            guard let address = try? AgentKey.deriveAddress(masterKey: masterKeyData, index: index)
            else { return }
            await MainActor.run {
                guard var current = AgentManager.shared.agent(for: agent.id),
                    current.agentAddress == nil
                else { return }
                current.agentIndex = index
                current.agentAddress = address
                AgentManager.shared.update(current)
            }
        }
    }

    public func assignAddress(to agent: Agent) throws {
        guard !agent.isBuiltIn, agent.agentAddress == nil else { return }
        guard MasterKey.exists() else { return }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        context.interactionNotAllowed = true
        guard var masterKeyData = try? MasterKey.getPrivateKey(context: context) else { return }
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

        // Drop the agent from the DEFAULT / main-chat spawn pool. Agent
        // UUIDs are never reused, so a stale entry would keep the
        // orchestrator's `spawn_agent` tool visible (pool "non-empty")
        // while advertising a target that can no longer resolve.
        _ = SubagentConfigurationStore.mutate { config in
            config.spawnableAgentIDs.removeAll { $0 == id }
        }

        refresh()

        // Tear down plugin state FIRST and wait for it to finish. Plugins
        // deregister webhooks inside `on_config_changed(tunnel_url="")`
        // and read their per-agent config (e.g. Telegram's `bot_token`)
        // while doing so — the secrets must still exist at that point.
        // Sweeping the keychain before this call left webhooks registered
        // upstream forever because the plugin found no token to
        // deregister with.
        await PluginManager.shared.tearDownPluginsForRemovedAgent(agentId: id)

        // Sweep every plugin's per-agent secrets for this agent. Without
        // this, deleting an agent would leave its `bot_token` / OAuth
        // credentials / `tunnel_url` / etc. in Keychain Access forever.
        // Done only AFTER plugin teardown completed (see above).
        ToolSecretsKeychain.deleteAllSecrets(forAgent: id)

        // Remove the agent's proactive channel destinations. Agent UUIDs
        // are never reused, so leaving the bindings behind would only
        // create permanent orphans in `agent-channels.json`.
        try? AgentChannelConnectionManager.shared.deleteBindings(agentId: id)

        // Delete the agent's chat sessions and accumulated memory. Agent
        // UUIDs are never reused, so without this the sessions, pinned
        // facts, episodes, and raw transcripts of a deleted agent sat in
        // the databases forever with no UI left that could reach them.
        await ChatSessionsManager.shared.deleteAll(for: id)
        let agentScope = id.uuidString
        await Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen { try? db.open() }
            try? db.deletePinnedFacts(forAgent: agentScope)
            try? db.deleteEpisodes(forAgent: agentScope)
            try? db.deleteConversationMemory(forAgent: agentScope)
        }.value

        // Drop the agent's vector index: the in-memory VecturaKit instance
        // (so a long-lived process doesn't accumulate one per deleted
        // agent) and the on-disk store, which is now all deleted content.
        await MemorySearchService.shared.deleteAgentIndex(agentId: agentScope)

        // Wipe the agent's native browser profile (cookies / sign-ins /
        // history) and drop its session-catalog record. Without this a
        // deleted agent's authenticated WebKit store would sit on disk
        // forever with nothing left that can open — or reset — it.
        await BrowserSessionManager.shared.resetSession(for: id)

        // Notify remaining subscribers. Plugin webhook deregistration
        // already happened synchronously above; PluginManager's own
        // `.agentRemoved` handler only performs an idempotent repeat
        // (deduped plugin-side).
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

    private func loadActiveAgentId() -> UUID? {
        guard let string = UserDefaults.standard.string(forKey: Self.activeAgentKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func saveActiveAgentId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeAgentKey)
    }
}

// MARK: - Agent Configuration Helpers

extension AgentManager {
    /// Whether the sandbox (autonomous exec) toggle should default ON for
    /// newly created custom agents.
    ///
    /// Gated on sandbox availability: macOS 26+ uses the Linux VM and older
    /// supported hosts use the Seatbelt fallback. If neither backend exists,
    /// defaulting on would only inject an unusable placeholder into the
    /// model's schema. Reading the synchronously seeded published availability
    /// keeps this stable from the first frame and lets tests force a value via
    /// `SandboxManager.State.shared.availability`.
    @MainActor
    public static var sandboxEnabledByDefault: Bool {
        SandboxManager.State.shared.availability.isAvailable
    }

    /// The `autonomousExec` to seed onto a newly created custom agent when it
    /// has made no explicit choice and the sandbox defaults ON: enabled where
    /// supported, else `nil` (off). Never applied on edit/import/duplicate,
    /// which must preserve the source agent's value. (The built-in Default
    /// agent is configuration-only and never uses the sandbox — see
    /// `effectiveAutonomousExec`.)
    @MainActor
    public static var sandboxDefaultAutonomousExec: AutonomousExecConfig? {
        sandboxEnabledByDefault ? AutonomousExecConfig(enabled: true) : nil
    }

    /// Get the effective sandbox execution config for an agent.
    ///
    /// The built-in Default ("Osaurus") agent is configuration-only: it never
    /// runs autonomous exec, so it always resolves to `nil` (off) regardless
    /// of any stored value or sandbox availability. Custom agents carry their
    /// own persisted value; an agent with no explicit choice defaults ON
    /// where the sandbox is supported — the chat chip is gone, so agent
    /// settings is the opt-out (which persists an explicit `enabled: false`).
    public func effectiveAutonomousExec(for agentId: UUID) -> AutonomousExecConfig? {
        guard let agent = agent(for: agentId) else {
            return nil
        }
        return Self.resolvedAutonomousExec(
            for: agent,
            availability: SandboxManager.resolveAvailability()
        )
    }

    /// Pure policy seam used by effective resolution and rollout tests.
    static func resolvedAutonomousExec(
        for agent: Agent,
        availability: SandboxAvailability
    ) -> AutonomousExecConfig? {
        // Single resolution point, so hard-off here also stops
        // `SandboxToolRegistrar` from provisioning a VM for the Default agent.
        if agent.id == Agent.defaultId {
            return nil
        }

        if let config = agent.autonomousExec {
            return config
        }

        // Unconfigured agent: sandbox on by default on supported machines.
        guard availability.isAvailable else { return nil }
        return AutonomousExecConfig(enabled: true)
    }

    /// Claude Code backend config for an agent, falling back to the safe
    /// default (agent mode, read-only tools) when the agent predates the
    /// setting or doesn't exist.
    public func effectiveClaudeCodeConfig(for agentId: UUID) -> ClaudeCodeAgentConfig {
        if agentId == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().claudeCode ?? .default
        }
        return agent(for: agentId)?.claudeCode ?? .default
    }

    /// Persist the Claude Code backend config for an agent.
    ///
    /// Mirrors `updateAutonomousExec`'s split between the Default agent (whose
    /// settings live in `DefaultAgentConfigurationStore`) and stored agents.
    public func updateClaudeCodeConfig(_ config: ClaudeCodeAgentConfig, for agentId: UUID) {
        if agentId == Agent.defaultId {
            var defaultConfig = DefaultAgentConfigurationStore.load()
            defaultConfig.claudeCode = config
            DefaultAgentConfigurationStore.save(defaultConfig)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
        } else {
            guard var agent = agent(for: agentId) else { return }
            agent.claudeCode = config
            update(agent)
        }
    }

    /// Update sandbox execution config for an agent.
    ///
    /// Ordinary config edits use the notification-driven registration path.
    /// An explicit OFF→ON transition additionally awaits the registrar's
    /// coalesced first-use task, so UI success means real tools are ready.
    /// Provisioning itself still has one owner (`SandboxToolRegistrar`);
    /// this manager never races a direct `ensureProvisioned` call against it.
    public func updateAutonomousExec(_ config: AutonomousExecConfig?, for agentId: UUID) async throws {
        let wasEnabled = effectiveAutonomousExec(for: agentId)?.enabled ?? false
        let willBeEnabled = config?.enabled ?? false

        // Save config first so the UI reflects the new state immediately
        // (enables loading indicator while provisioning runs).
        if agentId == Agent.defaultId {
            var defaultConfig = DefaultAgentConfigurationStore.load()
            defaultConfig.autonomousExec = config
            DefaultAgentConfigurationStore.save(defaultConfig)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
        } else {
            guard var agent = agent(for: agentId) else { return }
            agent.autonomousExec = config
            update(agent)
        }

        if willBeEnabled && !wasEnabled {
            // Toggling the sandbox on is an explicit user opt-in: clear any
            // prior failure cool-down and boot the container now (cold-
            // provisioning if needed), bypassing the `setupComplete` gate that
            // keeps the default-ON chip from auto-downloading at launch.
            // `provisionOnDemand` resets the startup-failure tracking for us.
            try await SandboxToolRegistrar.shared.provisionOnDemand(for: agentId)
        }

        // Mirror the per-agent egress choice onto the shared sandbox config
        // so the next VM (re)boot honors it. The sandbox VM is shared across
        // agents and network is a boot-time property, so this is
        // last-writer-wins: the agent that (re)provisions the VM sets its
        // egress, and switching to an agent with a different preference takes
        // effect on the next provision, not mid-session.
        if let config {
            var sandboxConfig = SandboxConfigurationStore.load()
            let desired = SandboxManager.reconciledNetworkSettings(
                agentNetworkEnabled: config.sandboxNetworkEnabled,
                allowedDomains: config.sandboxAllowedDomains
            )
            if sandboxConfig.network != desired.network
                || sandboxConfig.allowedDomains != desired.allowedDomains
            {
                sandboxConfig.network = desired.network
                sandboxConfig.allowedDomains = desired.allowedDomains
                SandboxConfigurationStore.save(sandboxConfig)
            }
        }
    }

    /// Get the effective system prompt for an agent (combining with global if needed)
    public func effectiveSystemPrompt(for agentId: UUID) -> String {
        guard let agent = agent(for: agentId) else {
            return DefaultAgentConfigurationStore.load().systemPrompt
        }

        // Default agent reads from its own dedicated configuration store
        // (`default-agent.json`); these fields used to live on
        // `ChatConfiguration` but were split out so the Settings UI
        // can honestly separate "Global Chat" from "Default Agent".
        if agent.id == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().systemPrompt
        }

        // Custom agents use their own system prompt
        return agent.systemPrompt
    }

    /// Get the effective model for an agent
    /// For custom agents without a model set, falls back to global "new agent" default
    public func effectiveModel(for agentId: UUID) -> String? {
        let defaultAgentModel = DefaultAgentConfigurationStore.load().defaultModel
        guard let agent = agent(for: agentId) else {
            return defaultAgentModel ?? ChatConfigurationStore.load().defaultModel
        }

        if agent.id == Agent.defaultId {
            return defaultAgentModel
        }

        // Custom agent: prefer agent's own model. When unset, fall back to
        // the global "default model for new agents" (still on
        // `ChatConfiguration` since it's the seed value for newly created
        // custom agents), and then to the Default agent's own model.
        return agent.defaultModel
            ?? ChatConfigurationStore.load().defaultModel
            ?? defaultAgentModel
    }

    /// Get the effective temperature for an agent
    public func effectiveTemperature(for agentId: UUID) -> Float? {
        guard let agent = agent(for: agentId) else {
            return DefaultAgentConfigurationStore.load().temperature
        }

        if agent.id == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().temperature
        }

        return agent.temperature
    }

    /// Get the effective max tokens for an agent
    public func effectiveMaxTokens(for agentId: UUID) -> Int? {
        guard let agent = agent(for: agentId) else {
            return DefaultAgentConfigurationStore.load().maxTokens
        }

        if agent.id == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().maxTokens
        }

        return agent.maxTokens
    }

    /// Resolve every per-agent capability flag in one place, applying the
    /// default-agent overrides and global memory switch centrally. This is
    /// the single source of truth; the narrower `effective*` accessors and
    /// `AgentConfigSnapshot.capture` all read from here.
    ///
    /// Default agent: tools are always available, memory comes from the global
    /// switch, and the editable per-agent capabilities
    /// (DB, charts, speak, recall, self-scheduling) are hard-off — the
    /// default agent is locked to its fixed baseline.
    public func effectiveCapabilities(for agentId: UUID) -> AgentCapabilities {
        let globalMemoryEnabled = MemoryConfigurationStore.load().enabled

        // Unknown agent or the default agent: baseline capabilities (tools
        // always available, memory from the global switch,
        // editable per-agent capabilities hard-off).
        guard let agent = agent(for: agentId), agent.id != Agent.defaultId else {
            return AgentCapabilities(
                toolsEnabled: true,
                memoryEnabled: globalMemoryEnabled,
                dbEnabled: false,
                renderChartEnabled: false,
                speakEnabled: false,
                searchMemoryEnabled: false,
                // Native web search stays on for the default agent — free
                // providers work with zero config and this replaces the
                // osaurus.search plugin's always-available tools.
                webSearchEnabled: true,
                selfSchedulingEnabled: false,
                computerUseEnabled: false,
                screenContextEnabled: false,
                // Like Computer Use, Browser Use is a custom-agent capability:
                // the Default agent is locked to its fixed baseline and never
                // gets browser access.
                browserUseEnabled: false
            )
        }

        return AgentCapabilities(
            toolsEnabled: agent.toolsEnabled,
            // Per-agent memory AND the global switch must both be on.
            memoryEnabled: agent.memoryEnabled && globalMemoryEnabled,
            dbEnabled: agent.settings.dbEnabled,
            renderChartEnabled: agent.settings.renderChartEnabled,
            speakEnabled: agent.settings.speakEnabled,
            searchMemoryEnabled: agent.settings.searchMemoryEnabled,
            webSearchEnabled: agent.settings.webSearchEnabled,
            selfSchedulingEnabled: agent.settings.selfSchedulingEnabled,
            computerUseEnabled: agent.settings.computerUseEnabled,
            // Screen context is a child of Computer Use: both the per-agent
            // screen-context flag AND Computer Use itself must be on.
            screenContextEnabled: agent.settings.computerUseEnabled
                && agent.settings.screenContextEnabled,
            browserUseEnabled: agent.settings.browserUseEnabled,
            spawnDelegationEnabled: agent.settings.spawnDelegationEnabled,
            imageEnabled: agent.settings.imageEnabled,
            videoEnabled: agent.settings.videoEnabled,
            appleScriptEnabled: agent.settings.appleScriptEnabled,
            spawnableAgentIDs: agent.settings.spawnableAgentIDs,
            spawnableAgentNames: agent.settings.legacySpawnableAgentNames,
            spawnableModelNames: agent.settings.spawnableModelNames,
            spawnableModelNotes: agent.settings.spawnableModelNotes,
            knowledgeEnabled: agent.settings.knowledgeEnabled,
            knowledgeCollectionIds: agent.settings.knowledgeCollectionIds,
            // Curator is a child of the knowledge opt-in.
            knowledgeCuratorEnabled: agent.settings.knowledgeEnabled
                && agent.settings.knowledgeCuratorEnabled
        )
    }

    /// Knowledge collections the agent may search/read: its grant list,
    /// filtered to enabled collections, empty when the opt-in is off.
    /// This is the execution-time scope source for the knowledge tools —
    /// the tools resolve it via `ChatExecutionContext.currentAgentId`, so
    /// the grant list (not the model-visible schema) is the boundary.
    public func effectiveKnowledgeCollections(for agentId: UUID) -> [KnowledgeCollection] {
        let caps = effectiveCapabilities(for: agentId)
        guard caps.knowledgeEnabled, !caps.knowledgeCollectionIds.isEmpty else { return [] }
        return KnowledgeManager.shared.enabledCollections(withIds: caps.knowledgeCollectionIds)
    }

    /// Whether tools are disabled for an agent. Thin negative-polarity
    /// wrapper over `effectiveCapabilities` for callers that still speak
    /// the disable vocabulary.
    public func effectiveToolsDisabled(for agentId: UUID) -> Bool {
        !effectiveCapabilities(for: agentId).toolsEnabled
    }

    /// Whether the Agent DB feature is enabled for an agent (spec §5.5).
    /// Hard-off for the default agent (DB is per-agent user data).
    public func effectiveDBEnabled(for agentId: UUID) -> Bool {
        effectiveCapabilities(for: agentId).dbEnabled
    }

    /// Whether memory is disabled for an agent. Negative-polarity wrapper
    /// over `effectiveCapabilities` (folds in the global memory switch).
    public func effectiveMemoryDisabled(for agentId: UUID) -> Bool {
        !effectiveCapabilities(for: agentId).memoryEnabled
    }

    /// Get the effective tool selection mode for an agent.
    /// Default agent reads from `DefaultAgentConfiguration.toolSelectionMode` (defaulting to .auto).
    public func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode {
        guard let agent = agent(for: agentId) else { return .auto }
        if agent.id == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().toolSelectionMode ?? .auto
        }
        return agent.toolSelectionMode ?? .auto
    }

    /// Get the manually selected tool names for an agent, or nil when not in manual mode.
    public func effectiveManualToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            let config = DefaultAgentConfigurationStore.load()
            guard config.toolSelectionMode == .manual else { return nil }
            return config.manualToolNames
        }
        guard agent.toolSelectionMode == .manual else { return nil }
        return agent.manualToolNames
    }

    /// Tool names this agent has enabled (as a unified allow-list) regardless of mode.
    /// In Auto mode this scopes the pre-flight catalog; in Manual mode this is the strict
    /// allowlist. Returns `nil` for legacy / un-seeded agents — callers should treat that
    /// as "no scope, use the global registry" to preserve backwards compatibility.
    public func effectiveEnabledToolNames(for agentId: UUID) -> [String]? {
        guard let agent = agent(for: agentId) else { return nil }
        if agent.id == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().manualToolNames
        }
        return agent.manualToolNames
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

    /// Seed an agent's enabled tool set from the live registry the first time
    /// the user opens the new capability picker. Idempotent: only writes when the field
    /// is `nil`. Without seeding, `nil` would mean "no allowlist" at runtime — i.e. the
    /// agent gets the global registry, which is what legacy auto-mode agents already
    /// expect. After seeding, every per-item toggle is a real disable, even in Auto.
    public func seedEnabledCapabilitiesIfNeeded(
        for agentId: UUID,
        defaultToolNames: [String]
    ) {
        guard let agent = agent(for: agentId) else { return }
        if agent.id == Agent.defaultId {
            var config = DefaultAgentConfigurationStore.load()
            if config.manualToolNames == nil {
                config.manualToolNames = defaultToolNames
                DefaultAgentConfigurationStore.save(config)
                NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
            }
            return
        }
        if agent.manualToolNames == nil {
            var updated = agent
            updated.manualToolNames = defaultToolNames
            update(updated)
        }
    }

    /// Update the agent's enabled tool allowlist (used by the capability picker).
    public func updateEnabledToolNames(_ names: [String], for agentId: UUID) {
        if agentId == Agent.defaultId {
            var config = DefaultAgentConfigurationStore.load()
            config.manualToolNames = names
            DefaultAgentConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
            return
        }
        guard var agent = agent(for: agentId), !agent.isBuiltIn else { return }
        agent.manualToolNames = names
        update(agent)
    }

    /// Update the agent's tool selection mode (auto vs manual) without touching the
    /// enabled set. Used by the new picker's "Auto-discover" toggle.
    public func updateToolSelectionMode(_ mode: ToolSelectionMode, for agentId: UUID) {
        if agentId == Agent.defaultId {
            var config = DefaultAgentConfigurationStore.load()
            config.toolSelectionMode = mode
            DefaultAgentConfigurationStore.save(config)
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
    /// The seeded tool list after auto-growing with newly registered tools —
    /// or nil when nothing should change. MANUAL mode is the user saying
    /// "only what I ticked": a plugin install, an MCP connect, or a
    /// declarative config apply must never append its tools to that list
    /// (it did, for every agent, since the picker seeding landed). Auto
    /// agents keep growing so a fresh plugin's tools are not silently
    /// disabled by the seeded picker.
    static func grownManualToolNames(
        current: [String]?,
        mode: ToolSelectionMode?,
        live liveNames: Set<String>
    ) -> [String]? {
        guard var current, mode != .manual else { return nil }
        let before = current.count
        for name in liveNames.sorted() where !current.contains(name) { current.append(name) }
        return current.count != before ? current : nil
    }

    public func growEnabledToolNames(_ liveNames: Set<String>) {
        var config = DefaultAgentConfigurationStore.load()
        if let grown = Self.grownManualToolNames(
            current: config.manualToolNames, mode: config.toolSelectionMode, live: liveNames)
        {
            config.manualToolNames = grown
            DefaultAgentConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
        }

        var anyAgentChanged = false
        for agent in agents where !agent.isBuiltIn {
            guard
                let grown = Self.grownManualToolNames(
                    current: agent.manualToolNames, mode: agent.toolSelectionMode, live: liveNames)
            else { continue }
            var updated = agent
            updated.manualToolNames = grown
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
    /// names are passed to `grow`; the snapshot is then advanced per
    /// `diffKnownCapabilities`.
    private func growNewlyDiscoveredCapabilities(
        live: Set<String>,
        key: String,
        grow: (Set<String>) -> Void
    ) {
        let result = Self.diffKnownCapabilities(
            known: loadKnownNames(forKey: key),
            live: live
        )
        if !result.toGrow.isEmpty { grow(result.toGrow) }
        saveKnownNames(result.merged, forKey: key)
    }

    /// Pure transform behind `growNewlyDiscoveredCapabilities` — the
    /// regression seam for the "disabled capabilities come back on restart"
    /// bug. Returns which `live` names are newly discovered (and should be
    /// grown into seeded agents) plus the snapshot to persist.
    ///
    /// - A missing snapshot (`known == nil`, first observation) seeds without
    ///   growing, which protects already-disabled capabilities on the upgrade
    ///   path.
    /// - The merged snapshot is monotonic — we union, never replace. At startup
    ///   plugins register incrementally and each fires `.toolsListChanged` with
    ///   only a *partial* `live` set. Replacing the snapshot with a partial set
    ///   would drop the not-yet-loaded names, so when the rest of the plugins
    ///   finish loading their tools would look "newly discovered" and get
    ///   auto-grown back into agents the user had explicitly disabled them on.
    ///   Keeping every name we've ever seen means a disabled capability never
    ///   looks new again.
    static func diffKnownCapabilities(
        known: Set<String>?,
        live: Set<String>
    ) -> (toGrow: Set<String>, merged: Set<String>) {
        guard let known else {
            return (toGrow: [], merged: live)
        }
        return (toGrow: live.subtracting(known), merged: known.union(live))
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
        // The Default agent's model lives on its own configuration store.
        // The legacy `ChatConfiguration.defaultModel` is now repurposed as
        // the seed model for newly-created custom agents.
        if agentId == Agent.defaultId {
            var config = DefaultAgentConfigurationStore.load()
            config.defaultModel = model
            DefaultAgentConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
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
        // Update in place instead of refresh(): a full AgentStore.loadAll
        // re-enumerates and re-decodes every agent file on the main thread,
        // which has hung on the model-picker click that lands here. The saved
        // agent is the only record that changed.
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            var updatedAgents = agents
            updatedAgents[index] = agent
            installAgentSnapshot(updatedAgents)
        } else {
            refresh()
        }
    }

}
