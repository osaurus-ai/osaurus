//
//  ConfigExporter.swift
//  osaurus
//
//  Snapshots current Osaurus state into an `OsaurusConfigDocument`.
//  Secrets never appear: the schema has no secret-bearing fields, and the
//  exporter only reads the plain configuration stores (never Keychain).
//
//  Deliberately unmanaged (left out of the document):
//   - server runtime, chat behavior, and app shell settings (removed in
//     scope reduction 2 — Settings UI only; server tuning is in flux)
//   - plugin-imported MCP entries (owned by the plugin lifecycle)
//   - provider endpoint CHANGES on existing providers (changing an endpoint
//     under a stored credential is the classic bait-and-switch; endpoints
//     export for visibility and are create-only)
//   - skills (content installation, not configuration) and custom search
//     definitions (nested endpoint templates with interleaved secrets)
//   - channel credentials, custom HTTP channel connections, per-room
//     dispatch routes, platform extras (polling, attachments, receipts)
//   - per-agent autonomy ceilings, telemetry, identity/pairing, storage
//     encryption, privacy-filter custom rules (Settings UI only, by design)
//

import Foundation
@preconcurrency import MLXLMCommon

@MainActor
enum ConfigExporter {

    static func export(sections: Set<ConfigSectionID>? = nil) -> OsaurusConfigDocument {
        var doc = OsaurusConfigDocument()
        doc.version = 1
        doc.memory = exportMemory()
        doc.defaultAgent = exportDefaultAgent()
        doc.activeAgent = exportActiveAgent()
        doc.agents = exportAgents()
        doc.tools = exportTools()
        doc.delegation = exportDelegation()
        doc.commands = exportCommands()
        doc.knowledgeCollections = exportKnowledgeCollections()
        doc.channels = exportChannels()
        doc.mcpServers = exportMCPServers()
        doc.models = exportModels()
        doc.plugins = exportPlugins()
        doc.providers = exportProviders()
        doc.searchProviders = exportSearchProviders()
        doc.schedules = exportSchedules()
        doc.watchers = exportWatchers()
        if let sections {
            return doc.filtered(to: sections)
        }
        return doc
    }

    // MARK: - Settings scopes

    private static func exportMemory() -> MemorySection {
        let config = MemoryConfigurationStore.load()
        var section = MemorySection()
        section.enabled = config.enabled
        section.budgetTokens = config.memoryBudgetTokens
        section.retentionDays = config.episodeRetentionDays
        return section
    }

    private static func exportDefaultAgent() -> DefaultAgentSection {
        let config = DefaultAgentConfigurationStore.load()
        var section = DefaultAgentSection()
        section.name = config.resolvedDisplayName.map { .value($0) } ?? .null
        section.model = config.defaultModel.map { .value($0) } ?? .null
        section.temperature = config.temperature.map { .value(Double($0)) } ?? .null
        section.maxTokens = config.maxTokens.map { .value($0) } ?? .null
        section.systemPrompt = config.systemPrompt
        section.disableTools = config.disableTools
        return section
    }

    private static func exportActiveAgent() -> String {
        let manager = AgentManager.shared
        if manager.activeAgentId == Agent.defaultId { return "default" }
        return manager.agents.first { $0.id == manager.activeAgentId }?.name ?? "default"
    }

    // MARK: - Agents

    private static func exportAgents() -> [AgentEntry] {
        let relay = RelayConfigurationStore.load()
        return AgentManager.shared.agents
            .filter { !$0.isBuiltIn }
            .map { agent in
                var entry = AgentEntry(name: agent.name)
                entry.description = agent.description
                entry.systemPrompt = agent.systemPrompt
                entry.model = agent.defaultModel.map { .value($0) } ?? .null
                entry.temperature = agent.temperature.map { .value(Double($0)) } ?? .null
                entry.maxTokens = agent.maxTokens.map { .value($0) } ?? .null
                var caps = AgentCapabilitiesEntry()
                caps.toolsEnabled = agent.toolsEnabled
                caps.memoryEnabled = agent.memoryEnabled
                caps.searchMemoryEnabled = agent.settings.searchMemoryEnabled
                caps.webSearchEnabled = agent.settings.webSearchEnabled
                caps.knowledgeEnabled = agent.settings.knowledgeEnabled
                caps.knowledgeCollectionIds =
                    agent.settings.knowledgeCollectionIds.isEmpty
                    ? nil
                    : agent.settings.knowledgeCollectionIds.map { $0.uuidString }
                caps.dbEnabled = agent.settings.dbEnabled
                caps.selfSchedulingEnabled = agent.settings.selfSchedulingEnabled
                caps.computerUseEnabled = agent.settings.computerUseEnabled
                caps.browserUseEnabled = agent.settings.browserUseEnabled
                caps.speakEnabled = agent.settings.speakEnabled
                caps.renderChartEnabled = agent.settings.renderChartEnabled
                caps.relayEnabled = relay.isEnabled(for: agent.id)
                entry.capabilities = caps
                return entry
            }
    }

    // MARK: - App behavior (Wave 3b)

    private static func exportDelegation() -> DelegationSection {
        let config = SubagentConfigurationStore.snapshot()
        let agents = AgentManager.shared.agents
        var section = DelegationSection()
        section.localTextEnabled = config.localTextDelegationEnabled
        section.imageEnabled = config.imageDelegationEnabled
        section.videoEnabled = config.videoDelegationEnabled
        section.applescriptEnabled = config.appleScriptDelegationEnabled
        section.applescriptExecutionMode =
            ConfigAppBehaviorEnums.applescriptModeKey(for: config.defaultAppleScriptExecutionMode)
        // The pool stores agent UUIDs; the document uses names. Ids without a
        // live agent are dropped (matching the store's own pruning intent).
        section.spawnableAgents = config.spawnableAgentIDs.compactMap { id in
            agents.first { $0.id == id }?.name
        }
        section.spawnableModels = config.spawnableModelNames
        section.spawnToolAccess = config.spawnToolAccess.rawValue
        var defaults: [String: String] = [:]
        for kindId in ConfigAppBehaviorEnums.permissionKindIds {
            defaults[kindId] = config.permissionDefaults.policy(for: kindId).rawValue
        }
        section.permissionDefaults = defaults
        let budgets = config.budgets.normalized
        section.budgetMaxTokens = budgets.maxDelegateTokens
        section.budgetMaxTurns = budgets.maxDelegateTurns
        section.budgetMaxToolCalls = budgets.maxToolCalls
        section.budgetMaxSeconds = budgets.maxElapsedSeconds
        section.budgetMaxParallelSpawns = budgets.maxParallelSpawns
        section.ramSafetyPreflight = config.ramSafetyPreflightEnabled
        section.coexistenceEnabled = config.subagentCoexistenceEnabled
        return section
    }

    // MARK: - Tools

    private static func exportTools() -> ToolsSection? {
        let (enabled, policies) = ToolRegistry.shared.explicitToolSettings()
        var section = ToolsSection()
        if !enabled.isEmpty { section.enabled = enabled }
        if !policies.isEmpty { section.policies = policies.mapValues { $0.rawValue } }
        if section.enabled == nil && section.policies == nil { return nil }
        return section
    }

    // MARK: - Commands / Knowledge / Channels (Wave 3c)

    /// User template commands only — built-in action commands live in code,
    /// skill-derived entries follow their skill, and plugin-imported
    /// commands belong to the plugin lifecycle.
    static func manageableCommands() -> [SlashCommand] {
        SlashCommandStore.loadAll()
            .filter { $0.kind == .template && $0.pluginId == nil && !$0.isBuiltIn }
    }

    private static func exportCommands() -> [CommandEntry] {
        manageableCommands().map { cmd in
            var entry = CommandEntry(name: cmd.name)
            entry.description = cmd.description
            entry.icon = cmd.icon
            entry.template = cmd.template ?? ""
            return entry
        }
    }

    private static func exportKnowledgeCollections() -> [KnowledgeCollectionEntry] {
        KnowledgeCollectionStore.loadAll().map { collection in
            var entry = KnowledgeCollectionEntry(name: collection.name)
            entry.summary = collection.summary
            entry.folderPath = collection.folderPath
            entry.enabled = collection.isEnabled
            entry.includeGlobs = collection.includeGlobs
            entry.excludeGlobs = collection.excludeGlobs
            return entry
        }
    }

    private static func exportChannels() -> ChannelsSection {
        var section = ChannelsSection()
        section.writeEnabled = ChannelWriteKillSwitch.shared.snapshot().writeEnabled
        let agents = AgentManager.shared.agents
        for platform in ConfigChannelPlatform.allCases {
            let snapshot = platform.snapshot()
            var entry = ChannelPlatformSection()
            entry.writeEnabled = snapshot.writeEnabled
            entry.defaultReadLimit = snapshot.defaultReadLimit
            entry.spaceAllowlist = snapshot.spaceAllowlist
            entry.readAllowlist = snapshot.readAllowlist
            entry.writeAllowlist = snapshot.writeAllowlist
            entry.senderAllowlist = snapshot.senderAllowlist
            entry.inboundEnabled = snapshot.inbound.enabled
            // A dangling target id (deleted agent) exports as null.
            entry.inboundAgent =
                snapshot.inbound.targetAgentId
                .flatMap { id in agents.first { $0.id == id && !$0.isBuiltIn }?.name }
                .map { .value($0) } ?? .null
            entry.requireMention = snapshot.inbound.requireMention
            entry.continueThreads = snapshot.inbound.continueThreads
            entry.autoReplyEnabled = snapshot.inbound.autoReplyEnabled
            platform.setSection(entry, in: &section)
        }
        return section
    }

    // MARK: - MCP

    /// User-added servers (HTTP and stdio) — entries imported by a plugin
    /// belong to that plugin's lifecycle.
    static func manageableMCPProviders() -> [MCPProvider] {
        MCPProviderManager.shared.configuration.providers
            .filter { $0.pluginId == nil }
    }

    private static func exportMCPServers() -> [MCPServerEntry] {
        manageableMCPProviders().map { provider in
            var entry = MCPServerEntry(name: provider.name)
            entry.transport = provider.transport.rawValue
            entry.enabled = provider.enabled
            switch provider.transport {
            case .http:
                entry.url = provider.url
                entry.auth = ConfigMCPAuth.key(for: provider.authType)
            case .stdio:
                entry.command = provider.command
                entry.args = provider.args
                // Plain env only; keys marked secret live in the Keychain
                // and never reach the document.
                entry.env = provider.env.isEmpty ? nil : provider.env
                entry.workingDirectory = provider.workingDirectory
                entry.executionHost = provider.executionHost.rawValue
            }
            return entry
        }
    }

    // MARK: - Models / Plugins

    private static func exportModels() -> [String] {
        ModelManager.shared.availableModels
            .filter { $0.isDownloaded }
            .map { $0.id }
            .sorted()
    }

    private static func exportPlugins() -> [String] {
        PluginManager.shared.plugins
            .map { $0.plugin.id }
            .sorted()
    }

    // MARK: - Cloud providers

    private static func exportProviders() -> [ProviderEntry] {
        ConfigProviderPresets.manageableProviders().map { provider in
            var entry = ProviderEntry(name: provider.name)
            entry.provider = ConfigProviderPresets.exportId(for: provider)
            entry.enabled = provider.enabled
            entry.autoConnect = provider.autoConnect
            // Endpoint (create-only on apply; exported for visibility).
            entry.host = provider.host
            entry.providerProtocol = provider.providerProtocol.rawValue
            entry.port = provider.port.map { .value($0) } ?? .null
            entry.basePath = provider.basePath
            entry.timeoutSeconds = provider.timeout
            entry.disableTimeout = provider.disableTimeout
            entry.manualModelIds = provider.manualModelIds
            return entry
        }
    }

    // MARK: - Search providers

    private static func exportSearchProviders() -> SearchProvidersSection? {
        let ranked = SearchProviderManager.shared.rankedProviders
        guard !ranked.isEmpty else { return nil }
        var section = SearchProvidersSection()
        section.ranking = ranked.map { $0.definition.id }
        section.providers = ranked.map { entry in
            var row = SearchProviderEntry(id: entry.definition.id)
            row.enabled = entry.provider.enabled
            return row
        }
        return section
    }

    // MARK: - Schedules / Watchers

    private static func agentName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return AgentManager.shared.agents.first { $0.id == id }?.name
    }

    private static func exportSchedules() -> [ScheduleEntry] {
        ScheduleManager.shared.schedules.map { schedule in
            var entry = ScheduleEntry(name: schedule.name)
            entry.agent = agentName(for: schedule.agentId)
            entry.instructions = schedule.instructions
            let parts = ConfigScheduleFrequency.components(of: schedule.frequency)
            entry.frequency = parts.frequency
            entry.frequencyValue = parts.value
            entry.frequencyTimeOfDay = parts.timeOfDay
            entry.enabled = schedule.isEnabled
            return entry
        }
    }

    private static func exportWatchers() -> [WatcherEntry] {
        WatcherManager.shared.watchers.map { watcher in
            var entry = WatcherEntry(name: watcher.name)
            entry.agent = agentName(for: watcher.agentId)
            entry.instructions = watcher.instructions
            entry.path = watcher.watchPath
            entry.recursive = watcher.recursive
            entry.responsiveness = watcher.responsiveness.rawValue
            entry.enabled = watcher.isEnabled
            return entry
        }
    }
}

// MARK: - Small shared key mappings

enum ConfigMCPAuth {
    static func key(for auth: MCPProviderAuthType) -> String {
        switch auth {
        case .none: return "none"
        case .bearerToken: return "bearer"
        case .oauth: return "oauth"
        }
    }

    static func auth(forKey key: String) -> MCPProviderAuthType? {
        switch key.lowercased() {
        case "none", "": return MCPProviderAuthType.none
        case "bearer", "bearer_token", "token": return .bearerToken
        case "oauth": return .oauth
        default: return nil
        }
    }
}
