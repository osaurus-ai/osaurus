//
//  ConfigExporter.swift
//  osaurus
//
//  Snapshots current Osaurus state into an `OsaurusConfigDocument`.
//  Secrets never appear: the schema has no secret-bearing fields, and the
//  exporter only reads the plain configuration stores (never Keychain).
//
//  Deliberately unmanaged (left out of the document):
//   - server runtime settings (removed in scope reduction 2 — Settings UI
//     only; server tuning is in flux), and the Chat / General page controls
//     that `chat` / `app` do not list (sampling, dock icon, updates, reset)
//   - plugin-imported MCP entries (owned by the plugin lifecycle)
//   - provider endpoint CHANGES on existing providers (changing an endpoint
//     under a stored credential is the classic bait-and-switch; endpoints
//     export for visibility and are create-only)
//   - skill content (installation, not configuration; `osaurus import`
//     installs it from a bundle). An agent's skill allow-list does export,
//     as `agents[].skills`, when the agent has one.
//   - custom search definitions (nested endpoint templates with
//     interleaved secrets)
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
        doc.harnessRuntimes = exportHarnessRuntimes()
        doc.defaultAgent = exportDefaultAgent()
        doc.configurator = exportConfigurator()
        doc.activeAgent = exportActiveAgent()
        doc.modelDefaults = exportModelDefaults()
        doc.chat = exportChat()
        doc.app = exportApp()
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
        doc.automations = ConfigEvents.export()
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
        section.runtime = ConfigHarness.runtimeKey(for: config.runtime)
        section.claudeCode = config.claudeCode.map { ConfigHarness.export($0, includeConfigWrites: true) }
        return section
    }

    private static func exportHarnessRuntimes() -> [HarnessRuntimeEntry] {
        HarnessRuntimeStore.shared.all().map { runtime in
            var entry = HarnessRuntimeEntry(name: runtime.displayName)
            entry.kind = ConfigHarness.key(for: runtime.kind)
            entry.executable = runtime.executable
            entry.arguments = runtime.arguments
            entry.environment = runtime.environment
            return entry
        }
    }

    /// `new_chat_agent`: the agent NEW chats open with — the persisted
    /// choice, never the foreground window's agent.
    private static func exportActiveAgent() -> String {
        let manager = AgentManager.shared
        if manager.newChatAgentId == Agent.defaultId { return "default" }
        return manager.agents.first { $0.id == manager.newChatAgentId }?.name ?? "default"
    }

    private static func exportConfigurator() -> ConfiguratorSection {
        let config = ConfiguratorConfigurationStore.load()
        var section = ConfiguratorSection()
        section.model = config.resolvedModel.map { .value($0) } ?? .null
        section.temperature = config.temperature.map { .value(Double($0)) } ?? .null
        section.systemPrompt = config.systemPrompt
        return section
    }

    private static func exportModelDefaults() -> ModelDefaultsSection {
        let chat = ChatConfigurationStore.load()
        var section = ModelDefaultsSection()
        section.coreModel = chat.coreModelIdentifier.map { .value($0) } ?? .null
        section.compactionModel = chat.compactionModelIdentifier.map { .value($0) } ?? .null
        return section
    }

    /// Reads each switch the way its runtime consumer does, so an unset
    /// default exports as its effective value.
    private static func exportChat() -> ChatSection {
        let defaults = UserDefaults.standard
        let chat = ChatConfigurationStore.load()
        var section = ChatSection()
        section.smoothStreaming = defaults.object(forKey: ChatSection.smoothStreamingKey) as? Bool ?? true
        section.groupActivity = ContentBlock.ActivityRollupSetting.isEnabled
        section.expandThinking = defaults.bool(forKey: ChatSection.expandThinkingKey)
        section.spellCheck = ComposerSpellCheckSetting.isEnabled
        section.autoTitles = chat.autoGenerateChatTitles
        section.followUpSuggestions = chat.generateFollowUpSuggestions
        section.clipboardMonitoring = chat.enableClipboardMonitoring
        section.keepMacAwake = AgentRunPowerManager.isKeepAwakeEnabled()
        return section
    }

    private static func exportApp() -> AppSection {
        var section = AppSection()
        section.hotkey = currentHotkeyText().map { .value($0) } ?? .null
        section.startAtLogin = (ServerConfigurationStore.load() ?? .default).startAtLogin
        section.showNotifications = ToastConfigurationStore.load().enabled
        return section
    }

    /// The stored global hotkey in `app.hotkey` text form; nil when off.
    static func currentHotkeyText() -> String? {
        ChatConfigurationStore.load().hotkey.map(HotkeyText.text(for:))
    }

    // MARK: - Agents

    private static func exportAgents() -> [AgentEntry] {
        let relay = RelayConfigurationStore.load()
        let agents = AgentManager.shared.agents
        let toolGroups = ToolRegistry.shared.portableToolGroups()
        return agents
            .filter { !$0.isBuiltIn }
            .map { agent in
                exportAgent(agent, agents: agents, relay: relay, toolGroups: toolGroups)
            }
    }

    /// One custom agent as a document entry. Shared by the `agents` section
    /// export and by agent templates (`AgentTemplate.make(from:)`).
    static func exportAgent(_ agent: Agent) -> AgentEntry {
        exportAgent(
            agent,
            agents: AgentManager.shared.agents,
            relay: RelayConfigurationStore.load(),
            toolGroups: ToolRegistry.shared.portableToolGroups())
    }

    private static func exportAgent(
        _ agent: Agent, agents: [Agent], relay: RelayConfiguration,
        toolGroups: [PortableToolGroup: [String]]
    ) -> AgentEntry {
        var entry = AgentEntry(name: agent.name)
        entry.description = agent.description
        entry.systemPrompt = agent.systemPrompt
        entry.avatar = agent.avatar.flatMap(AgentMascot.init(storedID:))?.rawValue
        entry.model = agent.defaultModel.map { .value($0) } ?? .null
        entry.temperature = agent.temperature.map { .value(Double($0)) } ?? .null
        entry.maxTokens = agent.maxTokens.map { .value($0) } ?? .null
        entry.generationSettings = agent.generationSettings.map { .value($0) } ?? .null
        entry.showResponseMetrics = agent.settings.showResponseMetrics
        entry.followUpSuggestions = agent.settings.followUp.enabled
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
        caps.appleApps = AppleApp.sorted(agent.settings.enabledAppleApps).map(\.rawValue)
        caps.imageEnabled = agent.settings.imageEnabled
        caps.applescriptEnabled = agent.settings.appleScriptEnabled
        caps.speakEnabled = agent.settings.speakEnabled
        caps.renderChartEnabled = agent.settings.renderChartEnabled
        caps.calculatorEnabled = agent.settings.calculatorEnabled
        caps.redactionToolsEnabled = agent.settings.redactionToolsEnabled
        caps.taskChecklistEnabled = agent.settings.taskChecklistEnabled
        caps.clarifyEnabled = agent.settings.clarifyEnabled
        caps.artifactsEnabled = agent.settings.artifactsEnabled
        caps.relayEnabled = relay.isEnabled(for: agent.id)
        entry.capabilities = caps
        exportToolSelection(of: agent, into: &entry, groups: toolGroups)
        if let skillNames = agent.skillNames { entry.skills = .value(skillNames) }
        entry.pluginInstructions =
            (agent.pluginInstructions?.isEmpty ?? true) ? nil : agent.pluginInstructions
        entry.sandbox = exportSandbox(of: agent)
        entry.subagents = exportSubagents(of: agent, agents: agents)
        entry.workingFolder = agent.workingFolderPath.map { .value($0) } ?? .null
        entry.workingFolderReadOnly = agent.settings.workingFolderReadOnly ? true : nil
        entry.sourceTemplate = agent.sourceTemplateName
        let workflows = agent.settings.enabledWorkflowIDs.compactMap { InstalledWorkflowStore.shared.workflow(id: $0)?.name }
        entry.workflows = workflows.isEmpty ? nil : workflows
        entry.runtime = ConfigHarness.runtimeKey(for: agent.runtime)
        entry.claudeCode = agent.claudeCode.map { ConfigHarness.export($0, includeConfigWrites: false) }
        entry.sharedToolApproval = agent.sharedToolApproval
        return entry
    }

    /// Manual tool selection splits into tool names plus MCP / plugin group
    /// enablement. Fully selected groups travel by name so the document
    /// survives a move to a machine where the same server exposes different
    /// tool names; partly selected groups travel as their exact tool names.
    /// Auto mode only records the mode.
    private static func exportToolSelection(
        of agent: Agent, into entry: inout AgentEntry,
        groups: [PortableToolGroup: [String]]
    ) {
        var tools = AgentToolsEntry()
        let mode = agent.toolSelectionMode ?? .auto
        tools.mode = mode.rawValue
        guard mode == .manual else {
            entry.tools = tools
            return
        }
        let split = AgentToolSelectionResolver.export(
            manualToolNames: agent.manualToolNames ?? [], groups: groups)
        tools.enabled = split.toolNames
        entry.tools = tools
        if !split.enabledMCPServers.isEmpty || !split.disabledMCPServers.isEmpty {
            var mcp = AgentToolGroupsEntry()
            mcp.enabled = split.enabledMCPServers
            mcp.disabled = split.disabledMCPServers.isEmpty ? nil : split.disabledMCPServers
            entry.mcpServers = mcp
        }
        if !split.enabledPlugins.isEmpty || !split.disabledPlugins.isEmpty {
            var plugins = AgentToolGroupsEntry()
            plugins.enabled = split.enabledPlugins
            plugins.disabled = split.disabledPlugins.isEmpty ? nil : split.disabledPlugins
            entry.plugins = plugins
        }
    }

    private static func exportSandbox(of agent: Agent) -> AgentSandboxEntry? {
        // Unconfigured agents resolve to the host default; export what the
        // agent EFFECTIVELY runs with so a template pins the behaviour.
        guard let exec = AgentManager.shared.effectiveAutonomousExec(for: agent.id) else {
            var off = AgentSandboxEntry()
            off.enabled = false
            return off
        }
        var section = AgentSandboxEntry()
        section.enabled = exec.enabled
        section.networkEnabled = exec.sandboxNetworkEnabled
        section.allowedDomains = exec.sandboxAllowedDomains ?? []
        section.maxCommandsPerTurn = exec.maxCommandsPerTurn
        section.backgroundProcessEnabled = exec.backgroundProcessEnabled
        section.pluginCreate = exec.pluginCreate
        return section
    }

    private static func exportSubagents(of agent: Agent, agents: [Agent]) -> AgentSubagentsEntry {
        var section = AgentSubagentsEntry()
        section.enabled = agent.settings.spawnDelegationEnabled
        // Ids without a live agent are dropped, matching the delegation section.
        section.agents = agent.settings.spawnableAgentIDs.compactMap { id in
            agents.first { $0.id == id }?.name
        }
        return section
    }

    // MARK: - App behavior (Wave 3b)

    private static func exportDelegation() -> DelegationSection {
        let config = SubagentConfigurationStore.snapshot()
        let agents = AgentManager.shared.agents
        var section = DelegationSection()
        section.localTextEnabled = config.localTextDelegationEnabled
        section.applescriptExecutionMode =
            ConfigAppBehaviorEnums.applescriptModeKey(for: config.defaultAppleScriptExecutionMode)
        // The pool stores agent UUIDs; the document uses names. Ids without a
        // live agent are dropped (matching the store's own pruning intent).
        section.spawnableAgents = config.spawnableAgentIDs.compactMap { id in
            agents.first { $0.id == id }?.name
        }
        section.spawnableWorkspaceAgents = config.spawnableWorkspaceAgents.map(\.key)
        if !config.workspaceAutoJoinDisabledIds.isEmpty {
            section.workspaceAutoJoin = Dictionary(
                uniqueKeysWithValues: config.workspaceAutoJoinDisabledIds.map { ($0, false) }
            )
        }
        var defaults: [String: String] = [:]
        for kindId in ConfigAppBehaviorEnums.permissionKindIds {
            defaults[kindId] = config.permissionDefaults.policy(for: kindId).rawValue
        }
        section.permissionDefaults = defaults
        let budgets = config.budgets.normalized
        section.budgetMaxTokens = budgets.maxDelegateTokens
        section.budgetMaxTurns = budgets.maxDelegateTurns
        section.budgetMaxSeconds = budgets.maxElapsedSeconds
        section.budgetMaxParallelSpawns = budgets.maxParallelSpawns
        section.budgetMaxRemoteParallelSpawns = budgets.maxRemoteParallelSpawns
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
        for platform in ConfigChannelPlatform.allCases {
            var entry = exportChannelAccount(platform, connectionId: platform.primaryConnectionId)
            let extras = ChannelAccounts.accounts(kind: platform.kind).filter {
                !$0.isPrimary && $0.connectionId != platform.primaryConnectionId
            }
            if !extras.isEmpty {
                entry.accounts = extras.map { account in
                    var extra = exportChannelAccount(platform, connectionId: account.connectionId)
                    extra.id = account.connectionId
                    return extra
                }
            }
            platform.setSection(entry, in: &section)
        }
        let connections = AgentChannelConfigurationStore.load().connections.compactMap {
            connection -> ChannelConnectionEntry? in
            let rules = ConfigChannelRouting.exportRules(kind: connection.kind, connectionId: connection.id)
            guard !rules.isEmpty else { return nil }
            var entry = ChannelConnectionEntry(connection: connection.name.isEmpty ? connection.id : connection.name)
            entry.routing = rules
            return entry
        }
        section.connections = connections.isEmpty ? nil : connections
        return section
    }

    private static func exportChannelAccount(
        _ platform: ConfigChannelPlatform, connectionId: String
    ) -> ChannelPlatformSection {
        let snapshot = platform.snapshot(connectionId: connectionId)
        var entry = ChannelPlatformSection()
        entry.writeEnabled = snapshot.writeEnabled
        entry.defaultReadLimit = snapshot.defaultReadLimit
        entry.spaceAllowlist = snapshot.spaceAllowlist
        entry.readAllowlist = snapshot.readAllowlist
        entry.writeAllowlist = platform.hasWriteAllowlist ? snapshot.writeAllowlist : nil
        entry.senderAllowlist = snapshot.senderAllowlist
        let rules = ConfigChannelRouting.exportRules(kind: platform.kind, connectionId: connectionId)
        entry.routing = rules.isEmpty ? nil : rules
        let posting = platform.supportsPosting ? ConfigChannelPosting.export(platform, connectionId: connectionId) : []
        entry.posting = posting.isEmpty ? nil : posting
        return entry
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
        ModelManager.shared.installedModels()
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
}

// MARK: - Small shared key mappings

/// The `agent` value of an event entry: a custom agent NAME for
/// an agent hosted here, or a workspace ref key (`<workspaceId>:<0x-address>`)
/// for a teammate's shared agent. Names never contain a `0x` address suffix
/// after a colon, so the two forms cannot collide.
enum ConfigAgentTargetReference {
    @MainActor
    static func export(_ target: AgentDispatchTarget?) -> String? {
        switch target {
        case .none:
            return nil
        case .local(let id):
            return AgentManager.shared.agents.first { $0.id == id }?.name
        case .workspace(let ref):
            return ref.key
        }
    }

    /// The workspace ref a document value names, or nil when it is a
    /// (local) agent name.
    static func workspaceRef(_ value: String) -> WorkspaceAgentRef? {
        WorkspaceAgentRef(key: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Human label for the target a stored row currently runs on.
    @MainActor
    static func currentLabel(_ target: AgentDispatchTarget?) -> String {
        switch target {
        case .none:
            return "(unknown)"
        case .local(let id):
            return AgentManager.shared.agents.first { $0.id == id }?.name ?? "(unknown)"
        case .workspace(let ref):
            return ref.key
        }
    }
}

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
