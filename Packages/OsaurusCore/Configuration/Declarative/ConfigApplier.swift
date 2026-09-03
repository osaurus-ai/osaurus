//
//  ConfigApplier.swift
//  osaurus
//
//  Executes a validated document against the live managers/stores —
//  the same code paths Settings and the old per-domain tools used.
//  Apply is idempotent: it recomputes current state per section and
//  only touches what differs, so re-applying a document is a no-op.
//
//  Secrets: the document never carries any. Creating a cloud provider
//  opens the native credential sheet (user pastes / signs in; the
//  manager writes straight to Keychain). Keyed MCP/search providers
//  are registered and reported as `needs_user_action` pointing at the
//  right Settings pane.
//

import Foundation
@preconcurrency import MLXLMCommon

/// Process-wide serialization for `ConfigApplier.apply`. Applies can arrive
/// concurrently from three surfaces (the `osaurus_config` tool, the CLI via
/// `/admin/config/apply`, and direct HTTP callers); an apply mutates many
/// managers/stores across multiple actor hops, so two interleaved applies
/// could tear state (e.g. one pruning an agent the other just created).
/// FIFO: waiters resume in arrival order.
private actor ConfigApplySerialQueue {
    static let shared = ConfigApplySerialQueue()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum ConfigApplier {

    /// Apply the document. The caller (tool / CLI endpoint) has already
    /// validated it via `ConfigPlanner.plan` and obtained user approval.
    /// Applies are serialized process-wide: a second apply waits for the
    /// first to finish rather than interleaving with it.
    static func apply(document: OsaurusConfigDocument, prune: Bool) async -> [ConfigApplyResult] {
        await ConfigApplySerialQueue.shared.acquire()
        let results = await applyLocked(document: document, prune: prune)
        await ConfigApplySerialQueue.shared.release()
        return results
    }

    private static func applyLocked(
        document: OsaurusConfigDocument,
        prune: Bool
    ) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []

        // Captured BEFORE any section mutates state: the live chat
        // conversation's effective spawn pool, so the post-apply hook can
        // detect growth (an agent created by this document, a delegation
        // edit) and stage the spawn tools for the SAME turn.
        let spawnBaseline = await MainActor.run { liveChatSpawnPool() }

        if let section = document.memory {
            results.append(await applyMemory(section))
        }
        if let section = document.defaultAgent {
            results.append(await applyDefaultAgent(section, pendingModelIds: document.models ?? []))
        }
        if let entries = document.agents {
            results.append(
                contentsOf: await applyAgents(
                    entries, prune: prune, pendingModelIds: document.models ?? []))
        }
        if let section = document.tools {
            results.append(contentsOf: await applyTools(section))
        }
        if let entries = document.commands {
            results.append(contentsOf: await applyCommands(entries, prune: prune))
        }
        if let entries = document.knowledgeCollections {
            results.append(contentsOf: await applyKnowledgeCollections(entries, prune: prune))
        }
        // After agents: channel inbound dispatch may target an agent this
        // same document just created.
        if let section = document.channels {
            results.append(contentsOf: await applyChannels(section))
        }
        if let entries = document.mcpServers {
            results.append(contentsOf: await applyMCPServers(entries, prune: prune))
        }
        if let plugins = document.plugins {
            results.append(contentsOf: await applyPlugins(plugins, prune: prune))
        }
        if let models = document.models {
            results.append(contentsOf: await applyModels(models, prune: prune))
        }
        if let entries = document.providers {
            results.append(contentsOf: await applyProviders(entries, prune: prune))
        }
        // After providers: privacy_filter.provider_overrides resolves names
        // against providers this same document may have just created.
        if let section = document.delegation {
            results.append(await applyDelegation(section))
        }
        if let section = document.searchProviders {
            results.append(contentsOf: await applySearchProviders(section, prune: prune))
        }
        if let entries = document.schedules {
            results.append(contentsOf: await applySchedules(entries, prune: prune))
        }
        if let entries = document.watchers {
            results.append(contentsOf: await applyWatchers(entries, prune: prune))
        }
        // Last: activation may reference an agent created above.
        if let name = document.activeAgent {
            results.append(await applyActiveAgent(name))
        }

        await stageSpawnToolsIfPoolGrew(baseline: spawnBaseline)

        return results
    }

    // MARK: - Same-turn spawn activation

    /// The launching chat conversation's effective `spawn_agent` target pool
    /// (self excluded), or `nil` when this apply does not run inside a live
    /// interactive chat turn (CLI, HTTP, delegation, schedules).
    @MainActor
    private static func liveChatSpawnPool() -> [UUID]? {
        guard let session = ChatExecutionContext.currentChatSessionBox?.session,
            session.source == .chat
        else { return nil }
        // A nil session agent binds to the Default agent (main chat).
        return effectiveSpawnableAgentIDs(for: session.agentId ?? Agent.defaultId)
    }

    @MainActor
    private static func effectiveSpawnableAgentIDs(for agentId: UUID) -> [UUID] {
        let caps = AgentManager.shared.effectiveCapabilities(for: agentId)
        return SubagentToolVisibility.effectiveSpawnableAgents(
            isDefault: agentId == Agent.defaultId,
            config: SubagentConfigurationStore.snapshot(),
            perAgentEnabled: caps.spawnDelegationEnabled,
            perAgentTargets: caps.spawnableAgentIDs
        ).filter { $0 != agentId }
    }

    /// An apply that grows the launching conversation's spawn pool (an agent
    /// this document just created, a `delegation` edit) must make the spawn
    /// tools callable in the SAME turn — the turn's tool schema was frozen at
    /// compose, when the pool may have been empty, and `ToolExecutionScope`
    /// rejects any tool absent from it. `osaurus_config` is an activation
    /// trigger, so specs staged here are drained by the loop's
    /// `CapabilityLoadBuffer` growth path and offered to the next iteration.
    /// Execution independently validates targets against the live pool.
    ///
    /// Already-visible spawn tools keep their original (frozen) schema —
    /// `ToolExecutionScope.activate` only appends genuinely new names — so a
    /// stale target enum lasts at most the rest of the turn; the next compose
    /// re-constrains it.
    private static func stageSpawnToolsIfPoolGrew(baseline: [UUID]?) async {
        guard let baseline else { return }
        let staged: [Tool] = await MainActor.run {
            guard let session = ChatExecutionContext.currentChatSessionBox?.session,
                session.source == .chat
            else { return [] }
            let launchingAgentId = session.agentId ?? Agent.defaultId
            let allowedAgentIDs = effectiveSpawnableAgentIDs(for: launchingAgentId)
            guard !allowedAgentIDs.isEmpty,
                !Set(allowedAgentIDs).subtracting(baseline).isEmpty
            else { return [] }

            let allowedAgentNames = allowedAgentIDs.compactMap {
                AgentManager.shared.agent(for: $0)?.name
            }
            let baseSpecs = ToolRegistry.shared.specs(
                forTools: [
                    SubagentCapabilityRegistry.spawnAgentToolName,
                    SubagentCapabilityRegistry.spawnBatchToolName,
                ]
            )
            let byName = Dictionary(
                uniqueKeysWithValues: baseSpecs.map { ($0.function.name, $0) }
            )

            var specs: [Tool] = []
            if let spawnAgent = byName[SubagentCapabilityRegistry.spawnAgentToolName] {
                specs.append(
                    SpawnAgentTool.constrainedSpec(
                        spawnAgent,
                        allowedAgentIDs: allowedAgentIDs,
                        allowedAgentNames: allowedAgentNames
                    )
                )
            }
            if let spawnBatch = byName[SubagentCapabilityRegistry.spawnBatchToolName] {
                let isDefault = launchingAgentId == Agent.defaultId
                let config = SubagentConfigurationStore.snapshot()
                let caps = AgentManager.shared.effectiveCapabilities(for: launchingAgentId)
                let allowedModelIds = SubagentToolVisibility.effectiveSpawnableModels(
                    isDefault: isDefault,
                    config: config,
                    perAgentEnabled: caps.spawnDelegationEnabled,
                    perAgentModelTargets: caps.spawnableModelNames
                )
                let maxParallel = SubagentToolVisibility.effectiveBudgets(
                    isDefault: isDefault,
                    config: config,
                    settings: AgentManager.shared.agent(for: launchingAgentId)?.settings,
                    sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                        for: ServerRuntimeSettingsStore.snapshot()
                    )
                ).normalized.maxParallelSpawns
                specs.append(
                    SpawnBatchTool.constrainedSpec(
                        spawnBatch,
                        allowedAgentIDs: allowedAgentIDs,
                        allowedAgentNames: allowedAgentNames,
                        allowedModelIds: allowedModelIds,
                        maxParallel: maxParallel
                    )
                )
            }
            return specs
        }
        for spec in staged {
            _ = await CapabilityLoadBuffer.current.add(spec)
        }
    }

    // MARK: - Settings scopes

    @MainActor
    private static func applyMemory(_ desired: MemorySection) -> ConfigApplyResult {
        var config = MemoryConfigurationStore.load()
        if let v = desired.enabled { config.enabled = v }
        if let v = desired.budgetTokens { config.memoryBudgetTokens = v }
        if let v = desired.retentionDays { config.episodeRetentionDays = v }
        MemoryConfigurationStore.save(config)
        return ConfigApplyResult(section: "memory", target: "memory", status: .done)
    }

    @MainActor
    private static func applyDefaultAgent(
        _ desired: DefaultAgentSection, pendingModelIds: [String]
    ) -> ConfigApplyResult {
        var config = DefaultAgentConfigurationStore.load()
        var nameChanged = false
        if desired.name.isSpecified {
            let trimmed = desired.name.valueOrNil?.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = (trimmed?.isEmpty ?? true) ? nil : trimmed
            nameChanged = newName != config.displayName
            config.displayName = newName
        }
        if desired.model.isSpecified {
            let trimmed = desired.model.valueOrNil?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed, !value.isEmpty {
                // Store the canonical runtime id (auto-prefixing bare cloud
                // ids) so the model actually routes — a raw store here is how
                // agents silently lose their model. A value equal to what is
                // already stored is a no-op even when stale, so exported
                // snapshots always re-apply.
                let unchanged = config.defaultModel?.caseInsensitiveCompare(value) == .orderedSame
                switch ConfigModelReference.resolve(
                    value,
                    catalog: ConfigModelReference.liveCatalog(),
                    pendingLocalIds: pendingModelIds
                ) {
                case .resolved(let canonical):
                    config.defaultModel = canonical
                case .invalid(let message):
                    if !unchanged {
                        return ConfigApplyResult(
                            section: "default_agent", target: "default_agent",
                            status: .failed, message: "model: \(message)")
                    }
                }
            } else {
                config.defaultModel = nil
            }
        }
        if desired.temperature.isSpecified {
            config.temperature = desired.temperature.valueOrNil.map(Float.init)
        }
        if desired.maxTokens.isSpecified { config.maxTokens = desired.maxTokens.valueOrNil }
        // The persona's home is `DefaultAgentConfiguration.systemPrompt`; the
        // store's save posts `.appConfigurationChanged` so live chats re-read it.
        if let prompt = desired.systemPrompt {
            config.systemPrompt = prompt
        }
        DefaultAgentConfigurationStore.save(config)
        // A name change must rebuild the published agent snapshot so the
        // picker pill and chat headers re-render with the new name.
        if nameChanged {
            AgentManager.shared.refresh()
        }
        return ConfigApplyResult(section: "default_agent", target: "default_agent", status: .done)
    }

    @MainActor
    private static func applyActiveAgent(_ name: String) -> ConfigApplyResult {
        if name.lowercased() == "default" {
            AgentManager.shared.setActiveAgent(Agent.defaultId)
            return ConfigApplyResult(section: "active_agent", target: "default", status: .done)
        }
        guard
            let agent = AgentManager.shared.agents.first(where: {
                $0.name.lowercased() == name.lowercased()
            })
        else {
            return ConfigApplyResult(
                section: "active_agent", target: name, status: .failed,
                message: "No agent named `\(name)` found.")
        }
        AgentManager.shared.setActiveAgent(agent.id)
        return ConfigApplyResult(section: "active_agent", target: agent.name, status: .done)
    }

    // MARK: - Agents

    private static func applyAgents(
        _ entries: [AgentEntry], prune: Bool, pendingModelIds: [String]
    ) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        var matchedIds = Set<UUID>()

        for entry in entries {
            let result: ConfigApplyResult = await MainActor.run {
                var entry = entry
                let existing = AgentManager.shared.agents.first {
                    !$0.isBuiltIn && $0.name.lowercased() == entry.name.lowercased()
                }
                // Mark the match BEFORE model resolution so a failed entry
                // never exposes its existing agent to prune deletion.
                if let agent = existing { matchedIds.insert(agent.id) }
                let rawModel = entry.model.valueOrNil?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let raw = rawModel, !raw.isEmpty {
                    switch ConfigModelReference.resolve(
                        raw,
                        catalog: ConfigModelReference.liveCatalog(),
                        pendingLocalIds: pendingModelIds
                    ) {
                    case .resolved(let canonical):
                        entry.model = .value(canonical)
                    case .invalid(let message):
                        // Unchanged-but-stale values are a no-op so exported
                        // snapshots always re-apply; only new/changed
                        // references must ground.
                        if existing?.defaultModel?.caseInsensitiveCompare(raw) == .orderedSame {
                            entry.model = .absent
                        } else {
                            return ConfigApplyResult(
                                section: "agents", target: entry.name,
                                status: .failed, message: "model: \(message)")
                        }
                    }
                }
                if var agent = existing {
                    patch(&agent, from: entry)
                    AgentManager.shared.update(agent)
                    applyRelay(entry.capabilities?.relayEnabled, to: agent.id)
                    return ConfigApplyResult(section: "agents", target: agent.name, status: .done)
                } else {
                    var agent = AgentManager.shared.create(
                        name: entry.name,
                        description: entry.description ?? "",
                        systemPrompt: entry.systemPrompt ?? "",
                        defaultModel: entry.model.valueOrNil,
                        temperature: entry.temperature.valueOrNil.map(Float.init),
                        maxTokens: entry.maxTokens.valueOrNil
                    )
                    matchedIds.insert(agent.id)
                    if entry.capabilities != nil {
                        patch(&agent, from: entry)
                        AgentManager.shared.update(agent)
                    }
                    applyRelay(entry.capabilities?.relayEnabled, to: agent.id)
                    // New agents join the Default spawn pool on create
                    // (`AgentManager.add`), so the orchestrator can run one
                    // immediately — and same-turn: the post-apply hook stages
                    // the spawn specs for this very conversation.
                    return ConfigApplyResult(
                        section: "agents", target: agent.name, status: .done,
                        message: "Created. `\(agent.name)` is spawnable now — "
                            + "call `spawn_agent` to run a task with it.")
                }
            }
            results.append(result)
        }

        if prune {
            let toDelete: [(UUID, String)] = await MainActor.run {
                AgentManager.shared.agents
                    .filter { !$0.isBuiltIn && !matchedIds.contains($0.id) }
                    .map { ($0.id, $0.name) }
            }
            for (id, name) in toDelete {
                _ = await AgentManager.shared.delete(id: id)
                results.append(ConfigApplyResult(section: "agents", target: name, status: .done))
            }
        }
        return results
    }

    @MainActor
    private static func patch(_ agent: inout Agent, from entry: AgentEntry) {
        if let v = entry.description { agent.description = v }
        if let v = entry.systemPrompt { agent.systemPrompt = v }
        if entry.model.isSpecified { agent.defaultModel = entry.model.valueOrNil }
        if entry.temperature.isSpecified {
            agent.temperature = entry.temperature.valueOrNil.map(Float.init)
        }
        if entry.maxTokens.isSpecified { agent.maxTokens = entry.maxTokens.valueOrNil }
        guard let caps = entry.capabilities else { return }
        if let v = caps.toolsEnabled { agent.toolsEnabled = v }
        if let v = caps.memoryEnabled { agent.memoryEnabled = v }
        if let v = caps.searchMemoryEnabled { agent.settings.searchMemoryEnabled = v }
        if let v = caps.webSearchEnabled { agent.settings.webSearchEnabled = v }
        if let v = caps.knowledgeEnabled { agent.settings.knowledgeEnabled = v }
        if let ids = caps.knowledgeCollectionIds {
            agent.settings.knowledgeCollectionIds = ids.compactMap(UUID.init(uuidString:))
        }
        if let v = caps.dbEnabled { agent.settings.dbEnabled = v }
        if let v = caps.selfSchedulingEnabled { agent.settings.selfSchedulingEnabled = v }
        if let v = caps.computerUseEnabled { agent.settings.computerUseEnabled = v }
        if let v = caps.browserUseEnabled { agent.settings.browserUseEnabled = v }
        if let v = caps.speakEnabled { agent.settings.speakEnabled = v }
        if let v = caps.renderChartEnabled { agent.settings.renderChartEnabled = v }
    }

    /// Relay enablement lives outside the Agent record. Route through the
    /// tunnel manager — the same path as the Agents pane toggle — so turning
    /// it on also connects (and off also disconnects) the live tunnel.
    @MainActor
    private static func applyRelay(_ desired: Bool?, to agentId: UUID) {
        guard let desired else { return }
        guard RelayConfigurationStore.load().isEnabled(for: agentId) != desired else { return }
        RelayTunnelManager.shared.setTunnelEnabled(desired, for: agentId)
    }

    // MARK: - Tools

    @MainActor
    private static func applyTools(_ desired: ToolsSection) -> [ConfigApplyResult] {
        let registry = ToolRegistry.shared
        var changed = 0
        var skipped: [String] = []
        for (tool, enabled) in desired.enabled ?? [:] {
            guard registry.isRegistered(tool) else {
                skipped.append(tool)
                continue
            }
            if registry.isGlobalEnabled(tool) != enabled {
                registry.setEnabled(enabled, for: tool)
                changed += 1
            }
        }
        for (tool, raw) in desired.policies ?? [:] {
            guard let policy = ToolPermissionPolicy(rawValue: raw.lowercased()) else { continue }
            guard registry.isRegistered(tool) else {
                skipped.append(tool)
                continue
            }
            if (registry.configuredPolicy(for: tool) ?? .ask) != policy {
                registry.setPolicy(policy, for: tool)
                changed += 1
            }
        }
        var message = "\(changed) tool setting(s) changed."
        if !skipped.isEmpty {
            message += " Skipped unregistered: \(skipped.sorted().joined(separator: ", "))."
        }
        if changed > 0 {
            // `setEnabled`/`setPolicy` persist but do not broadcast; an open
            // Tools pane refreshes on this signal.
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }
        return [ConfigApplyResult(section: "tools", target: "tools", status: .done, message: message)]
    }

    // MARK: - App behavior (Wave 3b)

    @MainActor
    private static func applyDelegation(_ desired: DelegationSection) -> ConfigApplyResult {
        // Resolve spawn-pool names first; an unresolvable name fails the
        // section before any partial pool replacement.
        var resolvedAgentIDs: [UUID]?
        if let names = desired.spawnableAgents {
            var ids: [UUID] = []
            for name in names {
                guard
                    let agent = AgentManager.shared.agents.first(where: {
                        $0.name.lowercased()
                            == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    })
                else {
                    return ConfigApplyResult(
                        section: "delegation", target: "delegation", status: .failed,
                        message: "spawnable_agents: no agent named `\(name)`.")
                }
                ids.append(agent.id)
            }
            resolvedAgentIDs = ids
        }
        _ = SubagentConfigurationStore.mutate { config in
            if let v = desired.localTextEnabled { config.localTextDelegationEnabled = v }
            if let v = desired.imageEnabled { config.imageDelegationEnabled = v }
            if let v = desired.videoEnabled { config.videoDelegationEnabled = v }
            if let v = desired.applescriptEnabled { config.appleScriptDelegationEnabled = v }
            if let raw = desired.applescriptExecutionMode,
                let mode = ConfigAppBehaviorEnums.applescriptMode(forKey: raw)
            {
                config.defaultAppleScriptExecutionMode = mode
            }
            if let ids = resolvedAgentIDs { config.spawnableAgentIDs = ids }
            if let models = desired.spawnableModels { config.spawnableModelNames = models }
            if let raw = desired.spawnToolAccess,
                let access = SpawnToolAccess(rawValue: raw.lowercased())
            {
                config.spawnToolAccess = access
            }
            for (kind, raw) in desired.permissionDefaults ?? [:] {
                guard let policy = SubagentPermissionPolicy(rawValue: raw.lowercased()) else {
                    continue
                }
                config.permissionDefaults.setPolicy(policy, for: kind.lowercased())
            }
            if let v = desired.budgetMaxTokens { config.budgets.maxDelegateTokens = v }
            if let v = desired.budgetMaxTurns { config.budgets.maxDelegateTurns = v }
            if let v = desired.budgetMaxToolCalls { config.budgets.maxToolCalls = v }
            if let v = desired.budgetMaxSeconds { config.budgets.maxElapsedSeconds = v }
            if let v = desired.budgetMaxParallelSpawns { config.budgets.maxParallelSpawns = v }
            if let v = desired.ramSafetyPreflight { config.ramSafetyPreflightEnabled = v }
            if let v = desired.coexistenceEnabled { config.subagentCoexistenceEnabled = v }
        }
        return ConfigApplyResult(section: "delegation", target: "delegation", status: .done)
    }

    // MARK: - Commands (Wave 3c)

    @MainActor
    private static func applyCommands(
        _ entries: [CommandEntry], prune: Bool
    ) -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let registry = SlashCommandRegistry.shared
        var matched = Set<UUID>()

        for entry in entries {
            let existing = ConfigExporter.manageableCommands().first {
                $0.name.lowercased() == entry.name.lowercased()
            }
            if var command = existing {
                matched.insert(command.id)
                if let v = entry.description { command.description = v }
                if let v = entry.icon { command.icon = v }
                if let v = entry.template { command.template = v }
                registry.update(command)
                results.append(
                    ConfigApplyResult(section: "commands", target: entry.name, status: .done))
            } else {
                // Validation guarantees `template` for new commands.
                let command = registry.create(
                    name: entry.name,
                    description: entry.description ?? "",
                    icon: entry.icon ?? "text.bubble",
                    template: entry.template ?? ""
                )
                matched.insert(command.id)
                results.append(
                    ConfigApplyResult(section: "commands", target: entry.name, status: .done))
            }
        }

        if prune {
            for command in ConfigExporter.manageableCommands()
            where !matched.contains(command.id) {
                registry.delete(id: command.id)
                results.append(
                    ConfigApplyResult(section: "commands", target: command.name, status: .done))
            }
        }
        return results
    }

    // MARK: - Knowledge collections (Wave 3c)

    @MainActor
    private static func applyKnowledgeCollections(
        _ entries: [KnowledgeCollectionEntry], prune: Bool
    ) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let manager = KnowledgeManager.shared
        await manager.ensureLoaded()
        var matched = Set<UUID>()

        for entry in entries {
            let existing = manager.collections.first {
                $0.name.lowercased() == entry.name.lowercased()
            }
            if var collection = existing {
                matched.insert(collection.id)
                if let v = entry.summary { collection.summary = v }
                if let v = entry.enabled { collection.isEnabled = v }
                if let v = entry.includeGlobs { collection.includeGlobs = v }
                if let v = entry.excludeGlobs { collection.excludeGlobs = v }
                // `update` persists and schedules a re-index of the folder.
                manager.update(collection)
                results.append(
                    ConfigApplyResult(
                        section: "knowledge_collections", target: entry.name, status: .done))
            } else {
                guard let folderPath = entry.folderPath else {
                    results.append(
                        ConfigApplyResult(
                            section: "knowledge_collections", target: entry.name, status: .failed,
                            message: "`folder_path` is required to create a collection."))
                    continue
                }
                var collection = await manager.create(
                    name: entry.name,
                    summary: entry.summary ?? "",
                    folderPath: folderPath,
                    includeGlobs: entry.includeGlobs ?? [],
                    excludeGlobs: entry.excludeGlobs ?? []
                )
                if entry.enabled == false {
                    collection.isEnabled = false
                    manager.update(collection)
                }
                matched.insert(collection.id)
                results.append(
                    ConfigApplyResult(
                        section: "knowledge_collections", target: entry.name, status: .done,
                        message: "Registered; indexing runs in the background."))
            }
        }

        if prune {
            for collection in manager.collections where !matched.contains(collection.id) {
                manager.delete(id: collection.id)
                results.append(
                    ConfigApplyResult(
                        section: "knowledge_collections", target: collection.name, status: .done,
                        message: "Deregistered. Documents in the folder were not touched."))
            }
        }
        return results
    }

    // MARK: - Channels (Wave 3c)

    @MainActor
    private static func applyChannels(_ desired: ChannelsSection) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []

        if let enabled = desired.writeEnabled {
            do {
                try ChannelWriteKillSwitch.shared.setWriteEnabled(enabled)
                results.append(
                    ConfigApplyResult(section: "channels", target: "channels", status: .done))
            } catch {
                results.append(
                    ConfigApplyResult(
                        section: "channels", target: "channels", status: .failed,
                        message: "Could not persist the write kill switch: "
                            + error.localizedDescription))
            }
        }

        var touchedPlatforms: [ConfigChannelPlatform] = []
        for platform in ConfigChannelPlatform.allCases {
            guard let section = platform.section(in: desired) else { continue }

            // Secret references resolve first so a bad reference fails the
            // platform before any partial store write. Values never appear
            // in results — only the ref display names do.
            var botToken: (value: String, display: String)?
            if let raw = section.botTokenRef {
                let (secret, display) = await resolveSecretRef(raw)
                guard let secret else {
                    results.append(
                        ConfigApplyResult(
                            section: "channels", target: platform.rawValue, status: .failed,
                            message: "bot_token_ref: could not resolve \(display) — nothing "
                                + "was changed."))
                    continue
                }
                botToken = (secret, display)
            }
            var appToken: (value: String, display: String)?
            if let raw = section.appTokenRef {
                let (secret, display) = await resolveSecretRef(raw)
                guard let secret else {
                    results.append(
                        ConfigApplyResult(
                            section: "channels", target: platform.rawValue, status: .failed,
                            message: "app_token_ref: could not resolve \(display) — nothing "
                                + "was changed."))
                    continue
                }
                appToken = (secret, display)
            }

            // The inbound agent name resolves first so an unknown name fails
            // the platform before any partial store write.
            var inboundAgentId: ConfigField<UUID> = .absent
            switch section.inboundAgent {
            case .absent:
                break
            case .null:
                inboundAgentId = .null
            case .value(let name):
                guard let id = customAgentId(named: name) else {
                    results.append(
                        ConfigApplyResult(
                            section: "channels", target: platform.rawValue, status: .failed,
                            message: "inbound_agent: no custom agent named `\(name)`."))
                    continue
                }
                inboundAgentId = .value(id)
            }

            var mutation = ConfigChannelMutation()
            mutation.writeEnabled = section.writeEnabled
            mutation.defaultReadLimit = section.defaultReadLimit
            mutation.spaceAllowlist = section.spaceAllowlist
            mutation.readAllowlist = section.readAllowlist
            mutation.writeAllowlist = section.writeAllowlist
            mutation.senderAllowlist = section.senderAllowlist
            mutation.inboundEnabled = section.inboundEnabled
            mutation.inboundAgentId = inboundAgentId
            mutation.requireMention = section.requireMention
            mutation.continueThreads = section.continueThreads
            mutation.autoReplyEnabled = section.autoReplyEnabled

            do {
                try platform.apply(mutation)
                touchedPlatforms.append(platform)
                var messages: [String] = []
                var tokenFailed = false
                if let botToken {
                    if platform.saveBotToken(botToken.value) {
                        messages.append("Stored the bot token from \(botToken.display).")
                    } else {
                        tokenFailed = true
                        messages.append(
                            "Could not store the bot token from \(botToken.display) — "
                                + "Keychain unavailable; set it in Settings.")
                    }
                }
                if let appToken {
                    if platform.saveAppToken(appToken.value) {
                        messages.append("Stored the app token from \(appToken.display).")
                    } else {
                        tokenFailed = true
                        messages.append(
                            "Could not store the app token from \(appToken.display) — "
                                + "Keychain unavailable; set it in Settings.")
                    }
                }
                results.append(
                    ConfigApplyResult(
                        section: "channels", target: platform.rawValue,
                        status: tokenFailed ? .needsUserAction : .done,
                        message: messages.isEmpty ? nil : messages.joined(separator: " ")))
            } catch {
                results.append(
                    ConfigApplyResult(
                        section: "channels", target: platform.rawValue, status: .failed,
                        message: "Could not save the configuration: \(error.localizedDescription)"))
            }
        }

        // Restart the touched receive transports (same as the Settings
        // panes) so policy changes take effect without a relaunch.
        for platform in touchedPlatforms {
            await platform.refreshRuntime()
        }
        return results
    }

    // MARK: - MCP servers

    @MainActor
    private static func applyMCPServers(
        _ entries: [MCPServerEntry], prune: Bool
    ) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let manager = MCPProviderManager.shared
        var matched = Set<UUID>()

        for entry in entries {
            // Resolve every secret reference up front. `resolveSecretRef`
            // suspends (a detached Keychain read that can take seconds), and
            // the existing-provider branch below copies the live provider,
            // mutates the copy, and writes the whole struct back — a
            // suspension inside that window would silently revert any edit
            // Settings saved meanwhile. With the awaits hoisted here, the
            // read-mutate-write below is synchronous on the main actor again.
            var resolvedToken: (secret: String?, display: String)?
            if let raw = entry.tokenRef {
                resolvedToken = await resolveSecretRef(raw)
            }
            var resolvedEnvRefs: [(key: String, secret: String?, display: String)] = []
            if let refs = entry.secretEnvRefs {
                for (envKey, raw) in refs.sorted(by: { $0.key < $1.key }) {
                    let (secret, display) = await resolveSecretRef(raw)
                    resolvedEnvRefs.append((envKey, secret, display))
                }
            }

            let existing = ConfigExporter.manageableMCPProviders().first {
                $0.name.lowercased() == entry.name.lowercased()
            }
            if var provider = existing {
                matched.insert(provider.id)
                var authChangedToKeyed = false
                var secretMessages: [String] = []
                var secretFailure = false
                switch provider.transport {
                case .http:
                    if let url = entry.url { provider.url = url }
                    if let raw = entry.auth, let auth = ConfigMCPAuth.auth(forKey: raw) {
                        authChangedToKeyed = auth != .none && provider.authType == .none
                        provider.authType = auth
                    }
                    // A token reference stores the bearer token directly —
                    // no Settings visit needed when it resolves and lands.
                    if case let (secret, display)? = resolvedToken {
                        if let secret {
                            provider.authType = .bearerToken
                            if MCPProviderKeychain.saveToken(secret, for: provider.id) {
                                authChangedToKeyed = false
                                secretMessages.append("Stored the bearer token from \(display).")
                            } else {
                                secretFailure = true
                                secretMessages.append(
                                    "Could not store the token from \(display) — Keychain "
                                        + "unavailable.")
                            }
                        } else {
                            secretFailure = true
                            secretMessages.append(
                                "Could not resolve \(display) — no token was stored.")
                        }
                    }
                case .stdio:
                    if let command = entry.command { provider.command = command }
                    if let args = entry.args { provider.args = args }
                    // Merge-map: plain env only. Keys marked secret keep
                    // their Keychain values; the document never carries one.
                    if let env = entry.env {
                        provider.env.merge(env) { _, new in new }
                    }
                    if let wd = entry.workingDirectory {
                        provider.workingDirectory = wd.isEmpty ? nil : wd
                    }
                    if let raw = entry.executionHost,
                        let host = MCPProviderExecutionHost(rawValue: raw.lowercased())
                    {
                        provider.executionHost = host
                    }
                    if !resolvedEnvRefs.isEmpty {
                        for (envKey, secret, display) in resolvedEnvRefs {
                            guard let secret else {
                                secretFailure = true
                                secretMessages.append(
                                    "Could not resolve \(display) for env \(envKey) — nothing "
                                        + "was stored.")
                                continue
                            }
                            if MCPProviderKeychain.saveEnvSecret(secret, key: envKey, for: provider.id) {
                                if !provider.secretEnvKeys.contains(envKey) {
                                    provider.secretEnvKeys.append(envKey)
                                }
                                // The secret slot supersedes any plain copy.
                                provider.env.removeValue(forKey: envKey)
                                secretMessages.append("Stored secret env \(envKey) from \(display).")
                            } else {
                                secretFailure = true
                                secretMessages.append(
                                    "Could not store env \(envKey) — Keychain unavailable.")
                            }
                        }
                    }
                }
                // Secrets never travel through the document — `token: nil`
                // preserves any stored credential (refs above already saved
                // theirs directly).
                manager.updateProvider(provider, token: nil)
                if let enabled = entry.enabled, provider.enabled != enabled {
                    manager.setEnabled(enabled, for: provider.id)
                }
                if secretFailure {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .needsUserAction,
                            message: secretMessages.joined(separator: " ")))
                } else if authChangedToKeyed {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .needsUserAction,
                            message: "Finish sign-in / token entry in Settings → Tools → Remote."))
                } else {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .done,
                            message: secretMessages.isEmpty
                                ? nil : secretMessages.joined(separator: " ")))
                }
            } else if entry.transport?.lowercased() == "stdio" {
                guard let command = entry.command,
                    !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .failed,
                            message: "`command` is required to add a stdio server."))
                    continue
                }
                // Secret env refs resolve BEFORE the server is registered so
                // a bad reference never leaves a half-configured server.
                var resolvedSecretEnv: [(key: String, value: String, display: String)] = []
                var unresolved: [String] = []
                for (envKey, secret, display) in resolvedEnvRefs {
                    if let secret {
                        resolvedSecretEnv.append((envKey, secret, display))
                    } else {
                        unresolved.append("\(display) (env \(envKey))")
                    }
                }
                guard unresolved.isEmpty else {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .failed,
                            message: "secret_env_refs: could not resolve "
                                + unresolved.joined(separator: ", ")
                                + " — the server was not added."))
                    continue
                }
                var provider = MCPProvider(
                    name: entry.name,
                    url: "",
                    enabled: entry.enabled ?? true,
                    authType: .none,
                    transport: .stdio
                )
                provider.command = command
                provider.args = entry.args ?? []
                provider.env = entry.env ?? [:]
                provider.workingDirectory =
                    (entry.workingDirectory?.isEmpty ?? true) ? nil : entry.workingDirectory
                provider.executionHost =
                    entry.executionHost.flatMap {
                        MCPProviderExecutionHost(rawValue: $0.lowercased())
                    } ?? .sandbox
                provider.secretEnvKeys = resolvedSecretEnv.map { $0.key }
                for item in resolvedSecretEnv {
                    provider.env.removeValue(forKey: item.key)
                }
                manager.addProvider(provider, token: nil)
                matched.insert(provider.id)
                var storeFailures: [String] = []
                for item in resolvedSecretEnv
                where !MCPProviderKeychain.saveEnvSecret(item.value, key: item.key, for: provider.id) {
                    storeFailures.append(item.key)
                }
                if storeFailures.isEmpty {
                    results.append(
                        ConfigApplyResult(section: "mcp_servers", target: entry.name, status: .done))
                } else {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .needsUserAction,
                            message: "Registered, but could not store secret env "
                                + storeFailures.joined(separator: ", ")
                                + " — Keychain unavailable; set them in Settings → Tools → Remote."))
                }
            } else {
                guard let url = entry.url else {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .failed,
                            message: "`url` is required to add a new server."))
                    continue
                }
                var auth = entry.auth.flatMap(ConfigMCPAuth.auth(forKey:)) ?? MCPProviderAuthType.none
                var token: String? = nil
                var tokenDisplay: String? = nil
                if case let (secret, display)? = resolvedToken {
                    guard let secret else {
                        results.append(
                            ConfigApplyResult(
                                section: "mcp_servers", target: entry.name, status: .failed,
                                message: "token_ref: could not resolve \(display) — the server "
                                    + "was not added."))
                        continue
                    }
                    auth = .bearerToken
                    token = secret
                    tokenDisplay = display
                }
                let provider = MCPProvider(
                    name: entry.name,
                    url: url,
                    enabled: entry.enabled ?? true,
                    authType: auth,
                    transport: .http
                )
                manager.addProvider(provider, token: token)
                matched.insert(provider.id)
                if let tokenDisplay {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .done,
                            message: "Registered with the bearer token from \(tokenDisplay)."))
                } else if auth != .none {
                    results.append(
                        ConfigApplyResult(
                            section: "mcp_servers", target: entry.name, status: .needsUserAction,
                            message: "Registered. Finish "
                                + (auth == .oauth ? "sign-in" : "token entry")
                                + " in Settings → Tools → Remote."))
                } else {
                    results.append(
                        ConfigApplyResult(section: "mcp_servers", target: entry.name, status: .done))
                }
            }
        }

        if prune {
            for provider in ConfigExporter.manageableMCPProviders()
            where !matched.contains(provider.id) {
                manager.removeProvider(id: provider.id)
                results.append(
                    ConfigApplyResult(section: "mcp_servers", target: provider.name, status: .done))
            }
        }
        return results
    }

    // MARK: - Plugins

    private static func applyPlugins(_ desired: [String], prune: Bool) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let installed = await MainActor.run { Set(PluginManager.shared.plugins.map { $0.plugin.id }) }

        for pluginId in desired where !installed.contains(pluginId) {
            do {
                try await PluginRepositoryService.shared.install(pluginId: pluginId)
            } catch {
                results.append(
                    ConfigApplyResult(
                        section: "plugins", target: pluginId, status: .failed,
                        message: "Install failed: \(error.localizedDescription)"))
                continue
            }
            // Required secrets never travel through the document — surface
            // the missing ones so the user finishes in the Secrets sheet.
            let missingSecretLabels: [String] = await MainActor.run {
                guard
                    let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == pluginId }),
                    let secrets = loaded.plugin.manifest.secrets
                else { return [] }
                return secrets
                    .filter { spec in
                        spec.required
                            && !ToolSecretsKeychain.hasSecret(
                                id: spec.id, for: pluginId, agentId: Agent.defaultId)
                    }
                    .map { $0.label }
            }
            if missingSecretLabels.isEmpty {
                results.append(ConfigApplyResult(section: "plugins", target: pluginId, status: .done))
            } else {
                results.append(
                    ConfigApplyResult(
                        section: "plugins", target: pluginId, status: .needsUserAction,
                        message: "Installed. Needs secrets in Settings → Plugins → Secrets: "
                            + missingSecretLabels.joined(separator: ", ")))
            }
        }

        if prune {
            let wanted = Set(desired)
            for pluginId in installed.subtracting(wanted).sorted() {
                do {
                    try await PluginRepositoryService.shared.uninstall(pluginId: pluginId)
                    results.append(
                        ConfigApplyResult(section: "plugins", target: pluginId, status: .done))
                } catch {
                    results.append(
                        ConfigApplyResult(
                            section: "plugins", target: pluginId, status: .failed,
                            message: "Uninstall failed: \(error.localizedDescription)"))
                }
            }
        }
        return results
    }

    // MARK: - Models

    private static func applyModels(_ desired: [String], prune: Bool) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let installed = await MainActor.run {
            Set(ModelManager.shared.availableModels.filter { $0.isDownloaded }.map { $0.id })
        }

        // Defense-in-depth: validation rejects duplicate ids, but never start
        // the same download twice even if a caller bypasses planning.
        var requested = Set<String>()
        for repoId in desired where !installed.contains(repoId) {
            guard requested.insert(repoId.lowercased()).inserted else { continue }
            guard let model = await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: repoId)
            else {
                results.append(
                    ConfigApplyResult(
                        section: "models", target: repoId, status: .failed,
                        message: "`\(repoId)` is not MLX-compatible (expected an mlx-community/* "
                            + "or other MLX build)."))
                continue
            }
            await MainActor.run { ModelManager.shared.downloadModel(model) }
            results.append(
                ConfigApplyResult(
                    section: "models", target: model.id, status: .started,
                    message: "Download started — poll osaurus_inspect({action: 'status'})."))
        }

        if prune {
            let wanted = Set(desired)
            for modelId in installed.subtracting(wanted).sorted() {
                let model = await MainActor.run {
                    ModelManager.shared.availableModels.first { $0.id == modelId }
                }
                guard let model else { continue }
                await ModelManager.shared.deleteModel(model)
                results.append(ConfigApplyResult(section: "models", target: modelId, status: .done))
            }
        }
        return results
    }

    // MARK: - Cloud providers

    private static func applyProviders(
        _ entries: [ProviderEntry], prune: Bool
    ) async -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        var matched = Set<UUID>()

        for entry in entries {
            let existing: RemoteProvider? = await MainActor.run {
                ConfigProviderPresets.manageableProviders().first {
                    $0.name.lowercased() == entry.name.lowercased()
                }
            }
            if var provider = existing {
                matched.insert(provider.id)
                let changed =
                    (entry.enabled != nil && entry.enabled != provider.enabled)
                    || (entry.autoConnect != nil && entry.autoConnect != provider.autoConnect)
                    || (entry.timeoutSeconds != nil && entry.timeoutSeconds != provider.timeout)
                    || (entry.disableTimeout != nil
                        && entry.disableTimeout != provider.disableTimeout)
                    || (entry.manualModelIds != nil
                        && entry.manualModelIds != provider.manualModelIds)
                if changed {
                    if let v = entry.enabled { provider.enabled = v }
                    if let v = entry.autoConnect { provider.autoConnect = v }
                    // Endpoint fields (host/protocol/port/base_path) are
                    // create-only — the planner refuses a mismatch before
                    // apply ever runs. Connection settings are mutable.
                    if let v = entry.timeoutSeconds { provider.timeout = v }
                    if let v = entry.disableTimeout { provider.disableTimeout = v }
                    if let v = entry.manualModelIds { provider.manualModelIds = v }
                    let updated = provider
                    await MainActor.run {
                        RemoteProviderManager.shared.updateProvider(
                            updated, apiKey: nil, oauthTokens: nil)
                    }
                }
                // The old short-circuit reported `done` here even when the
                // provider had NO stored secret — the case behind "the sheet
                // never opened": an earlier Settings visit or cancelled apply
                // left the entry registered but keyless, so "set up xAI"
                // silently succeeded without ever asking for the key. Verify
                // the declared auth actually has its credential and open the
                // same secure sheet a new provider gets when it doesn't.
                let frozen = provider
                // A secret reference stores/rotates the key without the
                // sheet. Mirrors the interactive path: entering a key flips
                // the provider to API-key auth.
                if let raw = entry.apiKeyRef {
                    let (secret, display) = await resolveSecretRef(raw)
                    guard let secret else {
                        results.append(
                            ConfigApplyResult(
                                section: "providers", target: entry.name, status: .failed,
                                message: "api_key_ref: could not resolve \(display) — "
                                    + "nothing was stored."))
                        continue
                    }
                    // Re-read the provider after the suspension: `frozen` is a
                    // pre-await copy, and writing it back would revert any
                    // Settings edit that landed while the Keychain read ran.
                    // Only the auth flip is ours to write.
                    let providerId = frozen.id
                    await MainActor.run {
                        guard
                            var current = RemoteProviderManager.shared.configuration.providers
                                .first(where: { $0.id == providerId })
                        else { return }
                        current.authType = .apiKey
                        RemoteProviderManager.shared.updateProvider(
                            current, apiKey: secret, oauthTokens: nil)
                    }
                    results.append(
                        ConfigApplyResult(
                            section: "providers", target: entry.name, status: .done,
                            message: "Stored the API key from \(display)."))
                    continue
                }
                // `set_api_key: true` is an explicit request to open the
                // sheet regardless of what's stored — the user wants to set
                // or rotate the key even when OAuth/an old key still works.
                if entry.setApiKey == true {
                    results.append(await requestCredentials(forExisting: frozen, entryName: entry.name))
                    continue
                }
                let availability = await RemoteProviderKeychain.runOffCooperativeExecutor {
                    Self.credentialAvailability(for: frozen)
                }
                switch availability {
                case .present:
                    results.append(
                        ConfigApplyResult(section: "providers", target: entry.name, status: .done))
                case .absent, .corrupt:
                    results.append(await requestCredentials(forExisting: frozen, entryName: entry.name))
                case .unavailable:
                    results.append(
                        ConfigApplyResult(
                            section: "providers", target: entry.name, status: .needsUserAction,
                            message: "Could not verify stored credentials (Keychain unavailable "
                                + "right now) — check Settings → Providers."))
                }
            } else {
                let result = await addProvider(entry)
                if case .done = result.status, let id = result.createdProviderId {
                    matched.insert(id)
                }
                results.append(result.result)
            }
        }

        if prune {
            // Prune only the manageable slice: an ephemeral provider absent
            // from the document must survive a prune apply.
            let toRemove: [(UUID, String)] = await MainActor.run {
                ConfigProviderPresets.manageableProviders()
                    .filter { !matched.contains($0.id) }
                    .map { ($0.id, $0.name) }
            }
            for (id, name) in toRemove {
                await MainActor.run { RemoteProviderManager.shared.removeProvider(id: id) }
                results.append(ConfigApplyResult(section: "providers", target: name, status: .done))
            }
        }
        return results
    }

    private struct ProviderAddOutcome {
        var result: ConfigApplyResult
        var createdProviderId: UUID?
        var status: ConfigApplyResult.Status { result.status }
    }

    /// Resolve a `*_ref` document value into (secret, safe display name).
    /// `nil` secret means malformed / missing / empty — callers report by
    /// display only; the value itself never reaches a result or a log.
    static func resolveSecretRef(_ raw: String) async -> (secret: String?, display: String) {
        switch ConfigSecretRef.parse(raw) {
        case .failure:
            return (nil, raw)
        case .success(let ref):
            // Keychain refs reach securityd through a synchronous
            // SecItemCopyMatching; resolved on the main actor, that IPC
            // round-trip has stalled the app for seconds when securityd was
            // slow. Hop off the cooperative executor for the read. Env refs
            // are a dictionary lookup and stay inline.
            if case .keychain = ref.source {
                let secret = await Task.detached(priority: .userInitiated) {
                    ref.resolve()
                }.value
                return (secret, ref.display)
            }
            return (ref.resolve(), ref.display)
        }
    }

    /// Whether the provider's declared auth has its secret in the Keychain.
    /// `.none` providers (e.g. a keyless local endpoint) need nothing, so
    /// they always count as present. Synchronous so the planner can call it
    /// too; the applier hops off the cooperative executor around it.
    static func credentialAvailability(for provider: RemoteProvider) -> SecretAvailability {
        switch provider.authType {
        case .none:
            return .present
        case .apiKey:
            return RemoteProviderKeychain.apiKeyAvailability(for: provider.id)
        case .openAICodexOAuth, .xaiOAuth:
            return RemoteProviderKeychain.oauthTokensAvailability(for: provider.id)
        }
    }

    /// Existing provider whose secret is missing: open the credential sheet
    /// in rotate mode (same preset card and fields Settings' "rotate key"
    /// shows) and persist the outcome through the manager. Secrets never
    /// touch the document or the result payload.
    private static func requestCredentials(
        forExisting provider: RemoteProvider, entryName: String
    ) async -> ConfigApplyResult {
        let request = ProviderCredentialRequest(
            provider: provider, providerName: provider.name,
            mode: .rotate(existingId: provider.id))
        let outcome = await ProviderCredentialPromptService.requestCredentials(request)
        if Task.isCancelled {
            return ConfigApplyResult(
                section: "providers", target: entryName, status: .cancelled,
                message: "Cancelled before credential entry completed.")
        }
        switch outcome {
        case .cancelled:
            // Accurate in both modes: a first-key sheet leaves the provider
            // keyless; a rotate sheet leaves the OLD key in place. Either
            // way nothing was stored — never describe this as a rotation.
            return ConfigApplyResult(
                section: "providers", target: entryName, status: .cancelled,
                message: "Credential entry was dismissed before a key was entered — nothing "
                    + "was stored: the provider's credentials are unchanged and no key was "
                    + "set or rotated.")
        case .apiKey(let key, _):
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ConfigApplyResult(
                    section: "providers", target: entryName, status: .needsUserAction,
                    message: "No key was entered — finish credential entry in Settings → Providers.")
            }
            // The credential the user entered decides the auth mode. Without
            // this, entering an API key on an OAuth-connected provider stored
            // a key that requests never used (authType stayed OAuth) — the
            // switch looked successful but changed nothing. Mirrors the
            // Settings edit sheet, where picking "API Key" flips authType.
            var updated = provider
            updated.authType = .apiKey
            let toSave = updated
            await MainActor.run {
                RemoteProviderManager.shared.updateProvider(toSave, apiKey: trimmed, oauthTokens: nil)
            }
            let switched = provider.authType != .apiKey
            return ConfigApplyResult(
                section: "providers", target: entryName, status: .done,
                message: switched
                    ? "Stored the API key and switched the provider to API-key auth."
                    : "Stored the credentials.")
        case .oauthTokens(let tokens):
            var updated = provider
            if updated.authType != .openAICodexOAuth, updated.authType != .xaiOAuth {
                updated.authType =
                    updated.providerType == .openAICodex ? .openAICodexOAuth : .xaiOAuth
            }
            let toSave = updated
            await MainActor.run {
                RemoteProviderManager.shared.updateProvider(toSave, apiKey: nil, oauthTokens: tokens)
            }
            return ConfigApplyResult(
                section: "providers", target: entryName, status: .done,
                message: "Signed in via OAuth.")
        }
    }

    /// Interactive provider creation: opens the native credential sheet so
    /// the user pastes / signs in. Mirrors the old `osaurus_provider` add
    /// path — no secret ever appears in the document or the result.
    private static func addProvider(_ entry: ProviderEntry) async -> ProviderAddOutcome {
        guard let resolution = ConfigProviderPresets.resolve(entry.provider) else {
            return ProviderAddOutcome(
                result: ConfigApplyResult(
                    section: "providers", target: entry.name, status: .failed,
                    message: "`provider` must be one of: \(ConfigProviderPresets.canonicalIdsList)."))
        }

        // A secret reference creates the provider without the sheet: the key
        // is read from env/keychain and stored exactly like an entered one.
        // Validation refuses api_key_ref for the OAuth/pairing resolutions.
        if let raw = entry.apiKeyRef, case .preset = resolution {
            let (secret, display) = await resolveSecretRef(raw)
            guard let secret else {
                return ProviderAddOutcome(
                    result: ConfigApplyResult(
                        section: "providers", target: entry.name, status: .failed,
                        message: "api_key_ref: could not resolve \(display) — the provider "
                            + "was not created."))
            }
            let id = await MainActor.run {
                buildAndAddProvider(
                    entry: entry,
                    resolution: resolution,
                    storageAuthType: .apiKey,
                    extraFields: nil,
                    apiKey: secret,
                    oauthTokens: nil)
            }
            return ProviderAddOutcome(
                result: ConfigApplyResult(
                    section: "providers", target: entry.name, status: .done,
                    message: "Created with the API key from \(display)."),
                createdProviderId: id)
        }

        let request: ProviderCredentialRequest
        switch resolution {
        case .preset(let preset):
            request = ProviderCredentialRequest(preset: preset, providerName: entry.name, mode: .addNew)
        case .codexOAuth:
            request = ProviderCredentialRequest(
                providerType: .openAICodex, providerName: entry.name, mode: .addNew)
        case .osaurusAgent:
            request = ProviderCredentialRequest(
                providerType: .osaurus, providerName: entry.name, mode: .addNew)
        }

        let outcome = await ProviderCredentialPromptService.requestCredentials(request)
        if Task.isCancelled {
            return ProviderAddOutcome(
                result: ConfigApplyResult(
                    section: "providers", target: entry.name, status: .cancelled,
                    message: "Cancelled before credential entry completed."))
        }

        switch outcome {
        case .cancelled:
            return ProviderAddOutcome(
                result: ConfigApplyResult(
                    section: "providers", target: entry.name, status: .cancelled,
                    message: "User cancelled credential entry."))
        case .apiKey(let key, let headers):
            let storageAuthType = request.instructions.storageAuthType
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedKey: String? =
                (storageAuthType == .none || trimmedKey.isEmpty) ? nil : trimmedKey
            let id = await MainActor.run {
                buildAndAddProvider(
                    entry: entry,
                    resolution: resolution,
                    storageAuthType: storageAuthType,
                    extraFields: headers,
                    apiKey: resolvedKey,
                    oauthTokens: nil)
            }
            return ProviderAddOutcome(
                result: ConfigApplyResult(section: "providers", target: entry.name, status: .done),
                createdProviderId: id)
        case .oauthTokens(let tokens):
            let id = await MainActor.run {
                buildAndAddProvider(
                    entry: entry,
                    resolution: resolution,
                    storageAuthType: request.instructions.storageAuthType,
                    extraFields: nil,
                    apiKey: nil,
                    oauthTokens: tokens)
            }
            return ProviderAddOutcome(
                result: ConfigApplyResult(
                    section: "providers", target: entry.name, status: .done, message: "Signed in via OAuth."),
                createdProviderId: id)
        }
    }

    /// Extra-field keys that map to explicit `RemoteProvider` columns rather
    /// than free-form `customHeaders`. Internal so the test suite can pin
    /// that Azure's endpoint never leaks into the headers map.
    static let reservedExtraKeys: Set<String> = ["host", "deployment"]

    /// Comma/newline-separated Azure deployment names → `manualModelIds`,
    /// deduped case-insensitively keeping the first spelling — identical to
    /// `RemoteProviderEditSheet.parseManualModelIds` so chat-driven Azure
    /// providers persist the same way as Settings-configured ones.
    static func parseManualModelIds(_ text: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for part in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            values.append(value)
        }
        return values
    }

    @MainActor
    private static func buildAndAddProvider(
        entry: ProviderEntry,
        resolution: ProviderToolResolution,
        storageAuthType: RemoteProviderAuthType,
        extraFields: [String: String]?,
        apiKey: String?,
        oauthTokens: RemoteProviderOAuthTokens?
    ) -> UUID {
        if case .codexOAuth = resolution {
            var provider = OpenAICodexOAuthService.makeProvider()
            provider.name = entry.name
            if let v = entry.enabled { provider.enabled = v }
            if let v = entry.autoConnect { provider.autoConnect = v }
            RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
            return provider.id
        }

        let defaults: (host: String, providerProtocol: RemoteProviderProtocol, port: Int?, basePath: String)
        switch resolution {
        case .preset(let preset):
            let cfg = preset.configuration
            defaults = (cfg.host, cfg.providerProtocol, cfg.port, cfg.basePath)
        case .codexOAuth:
            defaults = ("chatgpt.com", .https, nil, "/backend-api")
        case .osaurusAgent:
            defaults = ("localhost", .http, 8080, "/v1")
        }
        let providerType = resolution.providerType
        let extras = extraFields ?? [:]

        // Endpoint precedence on create: what the user saw, edited, and
        // tested in the credential sheet wins; then the document's endpoint
        // fields (how a `custom` provider declares its host); then the
        // preset defaults. Existing providers never take endpoint changes.
        let sheetHost = extras["host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let documentHost = entry.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host =
            !sheetHost.isEmpty ? sheetHost : (!documentHost.isEmpty ? documentHost : defaults.host)
        let providerProtocol =
            entry.providerProtocol.flatMap { RemoteProviderProtocol(rawValue: $0.lowercased()) }
            ?? defaults.providerProtocol
        let port = entry.port.isSpecified ? entry.port.valueOrNil : defaults.port
        let basePath = entry.basePath ?? defaults.basePath

        var headers: [String: String] = [:]
        if providerType == .openaiLegacy {
            for (k, v) in extras where !reservedExtraKeys.contains(k) {
                headers[k] = v
            }
        }
        // Azure routes requests through deployment names rather than model
        // names, so the Settings UI persists the deployment list in
        // `manualModelIds`. Mirror that here; an explicit document list wins.
        var manualModelIds: [String] = entry.manualModelIds ?? []
        if manualModelIds.isEmpty, providerType == .azureOpenAI {
            manualModelIds = parseManualModelIds(extras["deployment"] ?? "")
        }

        var provider = RemoteProvider(
            name: entry.name,
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: storageAuthType,
            providerType: providerType,
            enabled: entry.enabled ?? true,
            autoConnect: entry.autoConnect ?? true,
            timeout: entry.timeoutSeconds ?? 60,
            manualModelIds: manualModelIds
        )
        if let v = entry.disableTimeout { provider.disableTimeout = v }
        RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
        return provider.id
    }

    // MARK: - Search providers

    @MainActor
    private static func applySearchProviders(
        _ desired: SearchProvidersSection, prune: Bool
    ) -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let manager = SearchProviderManager.shared

        for entry in desired.providers ?? [] {
            guard let def = manager.definition(id: entry.id) else {
                results.append(
                    ConfigApplyResult(
                        section: "search_providers", target: entry.id, status: .failed,
                        message: "Unknown provider id."))
                continue
            }
            let alreadyConfigured = manager.configuration.provider(id: entry.id) != nil
            if !alreadyConfigured {
                manager.addProvider(definitionId: entry.id, enabled: entry.enabled ?? true)
                let needsKey = !def.isKeyless && !manager.configuredProviderIds.contains(def.id)
                results.append(
                    ConfigApplyResult(
                        section: "search_providers", target: entry.id,
                        status: needsKey ? .needsUserAction : .done,
                        message: needsKey
                            ? "Added. Paste the API key in Settings → Search." : nil))
            } else {
                if let enabled = entry.enabled {
                    manager.setEnabled(enabled, for: entry.id)
                }
                results.append(
                    ConfigApplyResult(section: "search_providers", target: entry.id, status: .done))
            }
        }

        if prune, let listed = desired.providers {
            let wanted = Set(listed.map { $0.id })
            let configured = manager.rankedProviders.map { $0.definition.id }
            for id in configured where !wanted.contains(id) {
                manager.removeProvider(definitionId: id)
                results.append(
                    ConfigApplyResult(section: "search_providers", target: id, status: .done))
            }
        }

        if let ranking = desired.ranking {
            manager.setDefaultRanking(ranking)
            results.append(
                ConfigApplyResult(section: "search_providers", target: "ranking", status: .done))
        }
        return results
    }

    // MARK: - Schedules

    @MainActor
    private static func customAgentId(named name: String) -> UUID? {
        AgentManager.shared.agents.first {
            !$0.isBuiltIn && $0.name.lowercased() == name.lowercased()
        }?.id
    }

    @MainActor
    private static func applySchedules(
        _ entries: [ScheduleEntry], prune: Bool
    ) -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let manager = ScheduleManager.shared
        var matched = Set<UUID>()

        for entry in entries {
            let existing = manager.schedules.first {
                $0.name.lowercased() == entry.name.lowercased()
            }

            var frequency: ScheduleFrequency?
            if let raw = entry.frequency {
                switch ConfigScheduleFrequency.parse(
                    frequency: raw, value: entry.frequencyValue, timeOfDay: entry.frequencyTimeOfDay)
                {
                case .success(let f): frequency = f
                case .failure(let error):
                    results.append(
                        ConfigApplyResult(
                            section: "schedules", target: entry.name, status: .failed,
                            message: error.message))
                    continue
                }
            }

            var agentId: UUID?
            if let agentName = entry.agent {
                guard let id = customAgentId(named: agentName) else {
                    results.append(
                        ConfigApplyResult(
                            section: "schedules", target: entry.name, status: .failed,
                            message: "No custom agent named `\(agentName)`."))
                    continue
                }
                agentId = id
            }

            if var schedule = existing {
                matched.insert(schedule.id)
                if let agentId { schedule.agentId = agentId }
                if let v = entry.instructions { schedule.instructions = v }
                if let frequency { schedule.frequency = frequency }
                if let v = entry.enabled { schedule.isEnabled = v }
                manager.update(schedule)
                results.append(
                    ConfigApplyResult(section: "schedules", target: entry.name, status: .done))
            } else {
                guard let agentId, let instructions = entry.instructions, let frequency else {
                    results.append(
                        ConfigApplyResult(
                            section: "schedules", target: entry.name, status: .failed,
                            message: "Creating a schedule needs `agent`, `instructions`, and `frequency`."))
                    continue
                }
                // Chat/document-created schedules attach no security-scoped
                // folder context; the Schedules tab is the place for that.
                let schedule = manager.create(
                    name: entry.name,
                    instructions: instructions,
                    agentId: agentId,
                    parameters: [:],
                    folderPath: nil,
                    folderBookmark: nil,
                    frequency: frequency,
                    isEnabled: entry.enabled ?? true
                )
                matched.insert(schedule.id)
                results.append(
                    ConfigApplyResult(section: "schedules", target: entry.name, status: .done))
            }
        }

        if prune {
            for schedule in manager.schedules where !matched.contains(schedule.id) {
                _ = manager.delete(id: schedule.id)
                results.append(
                    ConfigApplyResult(section: "schedules", target: schedule.name, status: .done))
            }
        }
        return results
    }

    // MARK: - Watchers

    @MainActor
    private static func applyWatchers(_ entries: [WatcherEntry], prune: Bool) -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        let manager = WatcherManager.shared
        var matched = Set<UUID>()

        for entry in entries {
            let existing = manager.watchers.first { $0.name.lowercased() == entry.name.lowercased() }

            var agentId: UUID?
            if let agentName = entry.agent {
                guard let id = customAgentId(named: agentName) else {
                    results.append(
                        ConfigApplyResult(
                            section: "watchers", target: entry.name, status: .failed,
                            message: "No custom agent named `\(agentName)`."))
                    continue
                }
                agentId = id
            }

            var path: String?
            if let raw = entry.path {
                let expanded = (raw as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    results.append(
                        ConfigApplyResult(
                            section: "watchers", target: entry.name, status: .failed,
                            message: "`\(expanded)` is not an existing directory."))
                    continue
                }
                path = expanded
            }

            let responsiveness = entry.responsiveness.flatMap {
                Responsiveness(rawValue: $0.lowercased())
            }

            if var watcher = existing {
                matched.insert(watcher.id)
                if let agentId { watcher.agentId = agentId }
                if let v = entry.instructions { watcher.instructions = v }
                if let path {
                    // A document-supplied path replaces any picker-granted
                    // bookmark; the old bookmark points at the old folder and
                    // must not win over the new path in resolveWatchPath.
                    watcher.watchPath = path
                    watcher.watchBookmark = nil
                }
                if let v = entry.recursive { watcher.recursive = v }
                if let responsiveness { watcher.responsiveness = responsiveness }
                if let v = entry.enabled { watcher.isEnabled = v }
                manager.update(watcher)
                results.append(
                    ConfigApplyResult(section: "watchers", target: entry.name, status: .done))
            } else {
                guard let agentId, let instructions = entry.instructions, let path else {
                    results.append(
                        ConfigApplyResult(
                            section: "watchers", target: entry.name, status: .failed,
                            message: "Creating a watcher needs `agent`, `instructions`, and `path`."))
                    continue
                }
                let watcher = manager.create(
                    name: entry.name,
                    instructions: instructions,
                    agentId: agentId,
                    watchPath: path,
                    watchBookmark: nil,
                    isEnabled: entry.enabled ?? true,
                    recursive: entry.recursive ?? false,
                    responsiveness: responsiveness ?? .balanced
                )
                matched.insert(watcher.id)
                results.append(
                    ConfigApplyResult(
                        section: "watchers", target: entry.name, status: .done,
                        message: "Uses a plain folder path — if macOS blocks access, re-pick the "
                            + "folder in the Watchers tab."))
            }
        }

        if prune {
            for watcher in manager.watchers where !matched.contains(watcher.id) {
                _ = manager.delete(id: watcher.id)
                results.append(
                    ConfigApplyResult(section: "watchers", target: watcher.name, status: .done))
            }
        }
        return results
    }
}
